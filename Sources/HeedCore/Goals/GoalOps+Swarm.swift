import Foundation

/// What a lead's proposal did.
public struct SwarmProposal: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        /// A new plan version.
        case applied
        /// A structural change after approval: it waits for you.
        case pending
        /// The plan already says so.
        case unchanged
    }

    public var outcome: Outcome
    public var size: SwarmPlan.Size
    public var version: Int?
    public var steer: SwarmSteer?
    /// GOAL.md changes the plan needs, proposed to the goal (they wait for you).
    public var scope: [GoalEdit]
}

/// Swarm runs through `GoalOps`, like every other change to goals: starting one, the lead's proposals and questions,
/// your edits, approvals, restores and answers. Every act is a steering row; every plan change is a new version, and
/// `PLAN.md` next to `GOAL.md` follows the current one. Nothing here starts an agent: the app does that.
public extension GoalOps {
    // MARK: Reading

    /// A run with its plan versions and steering log.
    func board(of swarm: String) throws -> SwarmBoard {
        let run = try existing(swarm)
        return try SwarmBoard(swarm: run, versions: store.plans(of: swarm), steering: store.steering(of: swarm))
    }

    /// The goal's swarm that is still going.
    func activeSwarm(of goal: String) throws -> GoalSwarm? {
        try store.swarms().filter { $0.goal == goal && $0.status.active }.max { $0.number < $1.number }
    }

    // MARK: Runs

    /// A new swarm run on the goal, planning: the app starts its lead next. One at a time per goal.
    @discardableResult
    func startSwarm(goal: String, settings: SwarmSettings, now: Date) throws -> GoalSwarm {
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        if try activeSwarm(of: goal) != nil { throw GoalOpError.swarmActive(goal) }
        let number = try (store.swarms().filter { $0.goal == goal }.map(\.number).max() ?? 0) + 1
        let swarm = GoalSwarm(
            id: "\(goal)/swarm-\(number)", goal: goal, number: number, settings: settings, startedAt: now
        )
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: swarm.id, goal: goal, at: now, actor: .you, kind: .start,
            text: "Started swarm \(number): lead \(settings.lead.label), limits \(settings.limits.line)",
            reason: settings.autonomy.title
        ))
        return swarm
    }

    /// The lead's session started: the run knows it, and the log says so.
    @discardableResult
    func setLead(swarm id: String, session: String, now: Date) throws -> GoalSwarm {
        var swarm = try active(id)
        swarm.lead = session
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .start,
            text: "Lead \(swarm.settings.lead.label) started, drafting the plan", ref: session
        ))
        return swarm
    }

    /// Stops the run: it stays readable with its plans and steering; the goal carries on. Workers at work end as
    /// stopped.
    @discardableResult
    func stopSwarm(_ id: String, reason: String? = nil, now: Date) throws -> GoalSwarm {
        // Its workers stop with it (the app closes their tabs; their worktrees and branches stay).
        for worker in try active(id).liveWorkers {
            try endWorker(swarm: id, worker: worker.id, outcome: .stopped, cost: nil, now: now)
        }
        var swarm = try active(id)
        swarm.status = .stopped
        swarm.held = nil
        swarm.endedAt = now
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .stop, text: "Stopped swarm \(swarm.number)",
            reason: reason
        ))
        return swarm
    }

    // MARK: The lead

    /// A plan from the lead (or an agent). Before you approve one, every proposal is the new draft. After, a small
    /// change applies (and stays approved), a structural one waits for you, unless the run goes to the end on its own.
    /// GOAL.md changes it carries become proposals to the goal; a plan never changes the goal by itself.
    @discardableResult
    func proposePlan(
        swarm id: String, input: SwarmPlanInput, actor: SwarmSteer.Actor = .lead, ref: String? = nil, now: Date
    ) throws -> SwarmProposal {
        var swarm = try active(id)
        let current = try store.plans(of: id).first { $0.number == swarm.plan }?.tasks ?? []
        let tasks = SwarmPlan.grouped(input.tasks)
        try check(tasks, goal: swarm.goal)
        var scope: [GoalEdit] = []
        for change in input.scope {
            let edit = try propose(GoalEdit(
                goal: swarm.goal, section: change.section, op: change.section == .goal ? .replace : .add,
                text: change.text, from: "swarm \(swarm.number) lead", reason: "the plan needs it", kind: .scope,
                at: now
            ), now: now)
            scope.append(edit)
            if edit.state == .proposed {
                _ = try store.add(SwarmSteer(
                    swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .propose,
                    text: "GOAL.md: \(edit.line)", reason: "a change to the goal waits for you in GOAL.md",
                    state: .pending, ref: edit.id.map { "edit:\($0)" }
                ))
            }
        }
        let size = swarm.plan == 0 ? (tasks.isEmpty ? .none : .structural) : SwarmPlan.classify(
            old: current,
            new: tasks
        )
        let note = input.note ?? (swarm.plan == 0 ? "draft from the lead" : "change from the lead")
        guard size != .none else {
            return SwarmProposal(outcome: .unchanged, size: size, scope: scope)
        }
        let waits = swarm.approved != nil && size == .structural && swarm.settings.autonomy != .toTheEnd
        if waits {
            let steer = try store.add(SwarmSteer(
                swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .propose, text: note,
                reason: "a structural change: it waits for you", state: .pending, ref: ref, tasks: tasks
            ))
            return SwarmProposal(outcome: .pending, size: size, steer: steer, scope: scope)
        }
        let version = try addPlan(&swarm, tasks: tasks, author: .lead, note: note, now: now)
        let steer = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .propose, text: "v\(version.number): \(note)",
            reason: swarm.approved == nil ? nil : "\(size.rawValue) change, applied", version: version.number, ref: ref
        ))
        return SwarmProposal(outcome: .applied, size: size, version: version.number, steer: steer, scope: scope)
    }

    /// A question for you from the lead (or a worker), with its choices: it shows in the plan pane until answered.
    @discardableResult
    func ask(
        swarm id: String, question: String, options: [String] = [], actor: SwarmSteer.Actor = .lead,
        ref: String? = nil, now: Date
    ) throws -> SwarmSteer {
        let swarm = try active(id)
        let text = GoalDoc.oneLine(question)
        guard !text.isEmpty else { throw GoalOpError.noTitle }
        if let open = try SwarmSteering.questions(store.steering(of: id))
            .first(where: { $0.answer == nil && GoalEdits.same($0.row.text, text) })
        {
            return open.row
        }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .question, text: text, state: .pending,
            ref: ref, options: options.map(GoalDoc.oneLine).filter { !$0.isEmpty }
        ))
    }

    // MARK: You

    /// Your answer to a question.
    @discardableResult
    func answer(swarm id: String, question: Int64, text: String, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        let answer = GoalDoc.oneLine(text)
        guard !answer.isEmpty else { throw GoalOpError.noTitle }
        guard let asked = try SwarmSteering.questions(store.steering(of: id)).first(where: { $0.id == question })
        else { throw GoalOpError.unknownQuestion(question) }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .answer, text: answer,
            reason: asked.answer == nil ? nil : "changed the answer", about: question
        ))
    }

    /// Re-plan: your feedback for the lead, which answers with a new proposal.
    @discardableResult
    func replan(swarm id: String, feedback: String, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        let text = GoalDoc.oneLine(feedback)
        guard !text.isEmpty else { throw GoalOpError.noTitle }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .replan, text: text, state: .pending,
            ref: swarm.lead
        ))
    }

    /// The plan as you changed it (an edit, an added, moved or dropped task): a new version by you, and a row saying
    /// what. Nil when nothing changed.
    @discardableResult
    func changePlan(
        swarm id: String, tasks: [SwarmTask], kind: SwarmSteer.Kind, text: String, now: Date
    ) throws -> SwarmPlanVersion? {
        var swarm = try active(id)
        let current = try store.plans(of: id).first { $0.number == swarm.plan }?.tasks ?? []
        let tasks = SwarmPlan.grouped(tasks)
        try check(tasks, goal: swarm.goal)
        guard SwarmPlan.classify(old: current, new: tasks) != .none else { return nil }
        let version = try addPlan(&swarm, tasks: tasks, author: .you, note: text, now: now)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: kind, text: text, version: version.number
        ))
        return version
    }

    /// Approve: the change waiting for you, if one does (as a new version), else the current plan. Its tasks become
    /// the goal's items (source `swarm`, with owner, after, estimate, done when and phase); nothing runs yet.
    @discardableResult
    func approvePlan(swarm id: String, now: Date) throws -> SwarmPlanVersion {
        var swarm = try active(id)
        let steering = try store.steering(of: id)
        var about: Int64?
        if let pending = SwarmSteering.pendingChange(steering), let tasks = pending.tasks {
            try check(tasks, goal: swarm.goal)
            _ = try addPlan(&swarm, tasks: tasks, author: .lead, note: pending.text, now: now)
            about = pending.id
        }
        guard swarm.plan > 0, let version = try store.plans(of: id).first(where: { $0.number == swarm.plan }) else {
            throw GoalOpError.noPlan(id)
        }
        let previous = try swarm.approved.flatMap { number in try store.plans(of: id).first { $0.number == number } }
        swarm.approved = version.number
        try store.save(swarm)
        try materialize(version, previous: previous, swarm: swarm, now: now)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .approve,
            text: "plan v\(version.number) (\(version.tasks.count) task\(version.tasks.count == 1 ? "" : "s"))",
            about: about, version: version.number
        ))
        try writePlan(swarm)
        return version
    }

    /// No to the change waiting for you; the lead hears why in `plan show`.
    @discardableResult
    func rejectChange(swarm id: String, reason: String?, now: Date) throws -> SwarmSteer? {
        let swarm = try active(id)
        guard let pending = try SwarmSteering.pendingChange(store.steering(of: id)) else { return nil }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .reject, text: pending.text,
            reason: reason.map(GoalDoc.oneLine).flatMap { $0.isEmpty ? nil : $0 }, about: pending.id
        ))
    }

    /// An old version current again, as a new version: nothing is lost by restoring.
    @discardableResult
    func restorePlan(swarm id: String, version number: Int, now: Date) throws -> SwarmPlanVersion? {
        var swarm = try active(id)
        guard let old = try store.plans(of: id).first(where: { $0.number == number }) else {
            throw GoalOpError.unknownPlanVersion(id, number)
        }
        guard number != swarm.plan else { return nil }
        let version = try addPlan(&swarm, tasks: old.tasks, author: .restore, note: "restored v\(number)", now: now)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .restore, text: "v\(number) as v\(version.number)",
            version: version.number
        ))
        return version
    }

    // MARK: Fixtures

    /// Lays down fixture runs: each with its plan versions and steering, in order.
    func adopt(swarms: [SwarmFixture]) throws {
        for fixture in swarms {
            try store.save(fixture.swarm)
            for version in fixture.versions.sorted(by: { $0.number < $1.number }) {
                try store.add(version)
            }
            for row in fixture.steering {
                _ = try store.add(row)
            }
        }
    }

    // MARK: Inside

    internal func existing(_ id: String) throws -> GoalSwarm {
        guard let swarm = try store.swarm(id) else { throw GoalOpError.unknownSwarm(id) }
        return swarm
    }

    internal func active(_ id: String) throws -> GoalSwarm {
        let swarm = try existing(id)
        guard swarm.status.active else { throw GoalOpError.swarmEnded(id) }
        return swarm
    }

    private func check(_ tasks: [SwarmTask], goal: String) throws {
        let known = try Set(store.items().filter { $0.goal == goal }.map(\.id))
        let problems = SwarmPlan.problems(tasks, known: known)
        if !problems.isEmpty { throw GoalOpError.badPlan(problems.map(\.description)) }
    }

    /// The next version, current; once a plan was approved, the plan in use stays approved through changes that
    /// applied (yours, the lead's small ones, restores).
    private func addPlan(
        _ swarm: inout GoalSwarm, tasks: [SwarmTask], author: SwarmPlanVersion.Author, note: String, now: Date
    ) throws -> SwarmPlanVersion {
        let number = try (store.plans(of: swarm.id).map(\.number).max() ?? 0) + 1
        let version = SwarmPlanVersion(
            swarm: swarm.id, goal: swarm.goal, number: number, at: now, author: author, note: note, tasks: tasks
        )
        try store.add(version)
        let wasApproved = swarm.approved
        swarm.plan = number
        if wasApproved != nil {
            swarm.approved = number
            try store.save(swarm)
            let previous = try store.plans(of: swarm.id).first { $0.number == wasApproved }
            try materialize(version, previous: previous, swarm: swarm, now: now)
        } else {
            try store.save(swarm)
        }
        try writePlan(swarm)
        return version
    }

    /// The approved plan's tasks as the goal's items: new ones made with their plan id, ones already there given the
    /// plan's fields; items the plan dropped since lose their phase (they stay on the goal).
    private func materialize(
        _ version: SwarmPlanVersion, previous: SwarmPlanVersion?, swarm: GoalSwarm, now: Date
    ) throws {
        for task in version.tasks {
            var item = try store.item(task.id) ?? GoalItem(
                id: task.id, goal: swarm.goal, title: task.title, source: .swarm,
                reason: "swarm \(swarm.number), plan v\(version.number)", createdAt: now
            )
            item.title = task.title
            item.phase = task.phase
            item.owner = task.owner
            item.estimate = task.estimate
            item.after = task.after
            item.doneWhen = task.doneWhen
            try store.save(item)
            try addEvidence(GoalEvidence(
                goal: swarm.goal, item: item.id, kind: .plan, state: .done, at: now, source: "swarm \(swarm.number)",
                text: "in the swarm's plan"
            ))
        }
        let kept = Set(version.tasks.map(\.id))
        for task in previous?.tasks ?? [] where !kept.contains(task.id) {
            guard var item = try store.item(task.id) else { continue }
            item.phase = nil
            item.reason = "dropped from swarm \(swarm.number)'s plan in v\(version.number)"
            try store.save(item)
        }
    }

    private func writePlan(_ swarm: GoalSwarm) throws {
        guard files.writes, let version = try store.plans(of: swarm.id).first(where: { $0.number == swarm.plan }),
              let goal = try store.goal(swarm.goal)
        else { return }
        try files.write(plan: SwarmPlan.render(version, swarm: swarm, goalTitle: goal.title), goal: swarm.goal)
    }
}

/// A swarm run as fixtures make it: the run, its plan versions and its steering rows (oldest first).
public struct SwarmFixture: Sendable {
    public var swarm: GoalSwarm
    public var versions: [SwarmPlanVersion]
    public var steering: [SwarmSteer]

    public init(swarm: GoalSwarm, versions: [SwarmPlanVersion], steering: [SwarmSteer]) {
        self.swarm = swarm
        self.versions = versions
        self.steering = steering
    }
}
