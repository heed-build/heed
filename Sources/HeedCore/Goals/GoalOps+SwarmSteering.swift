import Foundation

/// Steering a running swarm through `GoalOps`: questions and who may answer them (`SwarmAuthority`), the ladder they
/// climb (`SwarmLadder`), answers by you, the lead, a peer or the controller, overrules, repeat rules, messages and
/// progress notes, and every hand-over to an agent. Each is a steering row, never a change to an old one.
public extension GoalOps {
    // MARK: Questions

    /// A question from the lead, a worker or another session on the goal, with its choices and what each would change.
    /// `SwarmAuthority` decides who may answer it and in which order; a question you answered before (the same words
    /// and options, or one of your rules) that is not always yours is answered at once by the controller, marked as a
    /// repeat. Asking again what is still open returns the open question.
    @discardableResult
    func ask(
        swarm id: String, question: String, options: [String] = [], effects: [String] = [],
        from: SwarmAddress? = nil, to target: SwarmAuthority.Target? = nil, actor: SwarmSteer.Actor = .lead,
        ref: String? = nil, now: Date
    ) throws -> SwarmSteer {
        let swarm = try active(id)
        let text = GoalDoc.oneLine(question)
        guard !text.isEmpty else { throw GoalOpError.noTitle }
        let rows = try store.steering(of: id)
        if let open = SwarmSteering.questions(rows)
            .first(where: { $0.answer == nil && GoalEdits.same($0.row.text, text) })
        {
            return open.row
        }
        var choices: [String] = []
        var said: [String] = []
        for (index, option) in options.enumerated() {
            let option = GoalDoc.oneLine(option)
            guard !option.isEmpty else { continue }
            choices.append(option)
            said.append(effects.indices.contains(index) ? GoalDoc.oneLine(effects[index]) : "")
        }
        let from = from ?? (actor == .lead ? .lead : nil)
        let asker: SwarmAuthority.Asker = switch from {
        case .lead?: .lead
        case let .task(task)?: .worker(task)
        default: .other
        }
        var peer: String?
        if case let .worker(task) = asker {
            let tasks = try approvedTasks(swarm)
            peer = SwarmLadder.peer(for: task, tasks: tasks, live: Set(swarm.liveWorkers.map(\.task)))
        }
        let verdict = SwarmAuthority.classify(text, options: choices, asker: asker, to: target, peer: peer)
        let to: String? = switch target {
        case .lead?: SwarmAddress.lead.raw
        case .you?: SwarmAddress.you.raw
        case let .task(task)?: SwarmAddress.task(task).raw
        case nil: verdict.peer.map { SwarmAddress.task($0).raw }
        }
        let asked = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .question, text: text, reason: verdict.reason,
            state: .pending, ref: ref, options: choices, from: from?.raw, to: to,
            effects: said.contains(where: { !$0.isEmpty }) ? said : nil, category: verdict.category.rawValue,
            ladder: verdict.ladder.map(\.rawValue), step: verdict.ladder.first?.rawValue
        ))
        guard SwarmAuthority.mayRepeat(verdict.category), let question = asked.id else { return asked }
        let history = try SwarmRepeat.answered(store.steering(goal: swarm.goal))
        if let earlier = SwarmRepeat.exact(text, options: choices, among: history),
           let answer = SwarmRepeat.answer(earlier, options: choices)
        {
            _ = try store.add(SwarmSteer(
                swarm: id, goal: swarm.goal, at: now, actor: .controller, kind: .answer, text: answer,
                reason: Self.repeatReason(earlier, similar: false), about: question, ref: "question:\(earlier.id)"
            ))
        }
        return asked
    }

    /// `a repeat of your answer to "…"`, `same as your rule for "…"`.
    static func repeatReason(_ earlier: SwarmRepeat.Answered, similar: Bool) -> String {
        let what = earlier.rule ? "your rule for" : "your answer to"
        return (similar ? "like \(what)" : "a repeat of \(what)") + " \"\(earlier.question)\""
    }

    /// An answer to a question. Yours always counts, and over someone else's answer it is an overrule (a row of its
    /// own, pointing at the answer it overrules); the lead's and a peer's count only at their step of its ladder (or
    /// when it was asked of them); the controller's is written by heed. Nobody answers their own question but you.
    @discardableResult
    func answer(
        swarm id: String, question: Int64, text: String, actor: SwarmSteer.Actor = .you, from: SwarmAddress? = nil,
        reason: String? = nil, ref: String? = nil, now: Date
    ) throws -> SwarmSteer {
        let swarm = try active(id)
        let answer = GoalDoc.oneLine(text)
        guard !answer.isEmpty else { throw GoalOpError.noTitle }
        let rows = try store.steering(of: id)
        guard let asked = SwarmSteering.questions(rows).first(where: { $0.id == question }) else {
            throw GoalOpError.unknownQuestion(question)
        }
        if actor != .you, actor != .controller {
            let position = SwarmLadder.position(asked.row, rows: rows)
            let mine = switch from {
            case .lead?: position.step == .lead || asked.row.to == SwarmAddress.lead.raw
            case let .task(task)?: (position.step == .peer && position.peer == task)
                || asked.row.to == SwarmAddress.task(task).raw
            default: false
            }
            guard mine, asked.answer == nil, from?.raw != asked.row.from else {
                let whose = asked.answer != nil ? "nobody: it is answered" : position.step.title
                throw GoalOpError.notYours(question, whose)
            }
        }
        if actor == .you, let previous = asked.answer, previous.actor != .you, let previousID = previous.id {
            let who = previous.from.flatMap(SwarmAddress.init(raw:))?.label() ?? previous.actor.rawValue
            return try store.add(SwarmSteer(
                swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .overrule, text: answer,
                reason: reason ?? "overrules \(who == "controller" ? "the controller" : who): \(previous.text)",
                state: .overruled, about: question, ref: "steer:\(previousID)", from: SwarmAddress.you.raw
            ))
        }
        let changed = actor == .you && asked.answer != nil
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .answer, text: answer,
            reason: reason ?? (changed ? "changed the answer" : nil), about: question, ref: ref, from: from?.raw
        ))
    }

    /// The ladder moves a question on: to `step`, and why. A question already there or answered stays.
    @discardableResult
    func escalate(
        swarm id: String, question: Int64, to step: SwarmAuthority.Answerer, why: String, now: Date
    ) throws -> SwarmSteer? {
        let swarm = try active(id)
        let rows = try store.steering(of: id)
        guard let asked = SwarmSteering.questions(rows).first(where: { $0.id == question }) else {
            throw GoalOpError.unknownQuestion(question)
        }
        guard asked.answer == nil, SwarmLadder.position(asked.row, rows: rows).step != step else { return nil }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .escalate, text: "to \(step.title)",
            reason: why.isEmpty ? nil : why, about: question, step: step.rawValue
        ))
    }

    /// The controller's suggestion for a question that is yours: shown with it in Needs you until you answer.
    @discardableResult
    func suggest(swarm id: String, question: Int64, option: String, reason: String, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .controller, kind: .suggest, text: option, reason: reason,
            state: .pending, about: question
        ))
    }

    /// "Same answer for similar questions": the question's words and options with your answer, which the controller
    /// gives questions like it from now on (in this goal's swarms; never one that is always yours).
    @discardableResult
    func rule(swarm id: String, question: Int64, answer: String, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        guard let asked = try SwarmSteering.questions(store.steering(of: id)).first(where: { $0.id == question })
        else { throw GoalOpError.unknownQuestion(question) }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .rule, text: asked.row.text,
            about: question, options: asked.row.options, answer: GoalDoc.oneLine(answer)
        ))
    }

    // MARK: Messages

    /// A message to an agent (`heed swarm send`): a task's worker, the lead, or everyone at work (the lead and each
    /// task with a worker now, but not the sender). heed hands it over when the agent is idle.
    @discardableResult
    func message(
        swarm id: String, from: SwarmAddress, to: SwarmAddress, text: String, actor: SwarmSteer.Actor, now: Date
    ) throws -> SwarmSteer {
        let swarm = try active(id)
        let line = GoalDoc.oneLine(text)
        guard !line.isEmpty else { throw GoalOpError.noTitle }
        var targets: [String]?
        if to == .all {
            let everyone = (swarm.lead == nil ? [] : [SwarmAddress.lead])
                + swarm.liveWorkers.map { SwarmAddress.task($0.task) }
            targets = everyone.filter { $0 != from }.map(\.raw)
        }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .message, text: line, from: from.raw,
            to: to.raw, targets: targets
        ))
    }

    /// An agent's progress note (`heed swarm note`).
    @discardableResult
    func note(swarm id: String, from: SwarmAddress, text: String, actor: SwarmSteer.Actor, now: Date) throws
        -> SwarmSteer
    {
        let swarm = try active(id)
        let line = GoalDoc.oneLine(text)
        guard !line.isEmpty else { throw GoalOpError.noTitle }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: .note, text: line, from: from.raw
        ))
    }

    /// heed handed `row` to `to`: typed into its pane, or read by it (`how`).
    @discardableResult
    func delivered(swarm id: String, row: Int64, to: SwarmAddress, how: String, now: Date) throws -> SwarmSteer {
        let swarm = try existing(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .deliver, text: how, about: row, ref: to.raw
        ))
    }

    /// You leave a PR heed could not move where it is: the Needs you item goes away; `swarm.land` still moves it.
    @discardableResult
    func leaveRetarget(swarm id: String, failure: Int64, now: Date) throws -> SwarmSteer {
        let swarm = try existing(id)
        guard let row = try store.steering(of: id).first(where: { $0.id == failure }) else {
            throw GoalOpError.unknownQuestion(failure)
        }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .retarget,
            text: "Left it: " + row.text.replacingOccurrences(of: "Could not move", with: "not moving"),
            about: failure, ref: row.ref
        ))
    }

    // MARK: Reading

    /// Every steering row of the goal's swarm runs (nil: of every goal), oldest first.
    func steering(goal: String?) throws -> [SwarmSteer] { try store.steering(goal: goal) }

    /// The approved plan's tasks (the current plan's before approval).
    internal func approvedTasks(_ swarm: GoalSwarm) throws -> [SwarmTask] {
        let number = swarm.approved ?? swarm.plan
        return try store.plans(of: swarm.id).first { $0.number == number }?.tasks ?? []
    }
}

public extension SwarmSteering {
    /// Retargets heed could not do and nothing settled since: a later retarget of the same task (heed's, or yours
    /// leaving it).
    static func retargetFailures(_ rows: [SwarmSteer]) -> [SwarmSteer] {
        rows.filter { row in
            guard row.kind == .retarget, row.actor == .heed, let id = row.id,
                  row.state == .pending || row.text.hasPrefix("Could not move")
            else { return false }
            return !rows.contains { later in
                guard later.kind == .retarget, let laterID = later.id, laterID > id else { return false }
                return later.ref == row.ref || later.about == id
            }
        }
    }
}
