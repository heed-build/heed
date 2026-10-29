import Foundation

/// A swarm's plan as `heed goal plan show` gives it: the run's state, the tasks by phase with their numbers, the
/// questions and their answers, and the owner's feedback the lead has not acted on yet.
public struct SwarmPlanView: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var number: String
        public var id: String
        public var title: String
        public var phase: String
        public var owner: String?
        public var estimate: String?
        public var after: [String]
        public var doneWhen: [String]
    }

    public struct Question: Codable, Equatable, Sendable {
        public var id: Int64
        public var text: String
        public var options: [String]
        public var answer: String?
        /// Who answered (`you`, `the controller`, `the lead`, `task 2.1`), or who it waits for.
        public var by: String?
        public var waitsFor: String?
    }

    public var swarm: String
    public var status: String
    public var version: Int
    public var approved: Int?
    public var autonomy: String
    public var team: [String]
    public var limits: String
    public var tasks: [Task]
    public var questions: [Question]
    /// Re-plan feedback since the lead's last proposal.
    public var feedback: [String]
    /// A change of the lead's waiting for the owner; and what the owner said no to last.
    public var waiting: String?
    public var rejected: String?
    /// What waits for the agent reading it (messages, questions handed to it, answers to its questions): read now.
    public var inbox: [String]?

    public init(_ board: SwarmBoard) {
        let swarm = board.swarm
        let tasks = board.tasks
        let numbers = SwarmPlan.numbers(tasks)
        self.swarm = swarm.id
        status = swarm.isApproved && swarm.status == .planning ? "approved" : swarm.status.rawValue
        version = swarm.plan
        approved = swarm.approved
        autonomy = swarm.settings.autonomy.rawValue
        team = swarm.settings.workers.isEmpty ? [swarm.settings.lead.label] : swarm.settings.workers.map(\.label)
        limits = swarm.settings.limits.line
        self.tasks = tasks.map { task in
            Task(
                number: numbers[task.id] ?? "", id: task.id, title: task.title, phase: task.phase,
                owner: task.owner?.label, estimate: task.estimate.map(SwarmEstimate.text),
                after: task.after, doneWhen: task.doneWhen
            )
        }
        questions = board.questions.map { question in
            let view = SwarmAnswerView(question, rows: board.steering, numbers: numbers)
            return Question(
                id: question.id, text: question.row.text, options: question.row.options, answer: view.answer,
                by: view.by, waitsFor: view.waitsFor
            )
        }
        feedback = SwarmSteering.feedback(board.steering).map(\.text)
        waiting = board.pending?.text
        let lastReject = board.steering.last { $0.kind == .reject }
        let lastPlan = board.steering.last { SwarmSteering.plans($0) }
        rejected = lastReject.flatMap { reject in
            (reject.id ?? 0) > (lastPlan?.id ?? 0) ? reject.text + (reject.reason.map { ": \($0)" } ?? "") : nil
        }
    }

    public var text: String {
        var lines = ["\(swarm): \(status), plan v\(version)" + (approved.map { ", approved v\($0)" } ?? "")
            + " · team \(team.joined(separator: ", ")) · limits \(limits)"]
        if tasks.isEmpty {
            lines.append("No plan yet: heed goal plan propose --file plan.json (heed goal --help says the shape).")
        }
        var phase = ""
        for task in tasks {
            if task.phase != phase {
                phase = task.phase
                lines += ["", "\(task.number.split(separator: ".").first ?? "") · \(phase)"]
            }
            var head = "  \(task.number) \(task.title)  [\(task.id)]"
            let details = [
                task.owner,
                task.estimate,
                task.after.isEmpty ? nil : "after " + task.after.joined(separator: ", "),
            ]
            .compactMap(\.self)
            if !details.isEmpty { head += "  " + details.joined(separator: " · ") }
            lines.append(head)
            lines += task.doneWhen.map { "      done when: \($0)" }
        }
        if !questions.isEmpty {
            lines += ["", "Questions"]
            for question in questions {
                lines.append("  \(question.id). \(question.text)"
                    + (question.options.isEmpty ? "" : " (" + question.options.joined(separator: " / ") + ")"))
                lines.append("     " + (question.answer.map { "answer: \($0)" + (question.by.map { " (\($0))" } ?? "") }
                        ?? "not answered yet" + (question.waitsFor.map { ", with \($0)" } ?? "")))
            }
        }
        if !feedback.isEmpty {
            lines += ["", "The owner asks you to re-plan"] + feedback.map { "  - \($0)" }
        }
        if let waiting { lines += ["", "Waiting for the owner: \(waiting)"] }
        if let rejected { lines += ["", "The owner said no to: \(rejected)"] }
        if let inbox, !inbox.isEmpty { lines += ["", "For you"] + inbox.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }
}

/// A question as `heed goal ask` gives it back: its words, its category, and its answer and who gave it, or whom it
/// waits for.
public struct SwarmAnswerView: Codable, Equatable, Sendable {
    public var question: Int64
    public var text: String
    public var options: [String]
    public var category: String?
    public var answer: String?
    /// `you`, `the controller`, `the lead`, `task 2.1`.
    public var by: String?
    public var reason: String?
    /// The answer it overruled, when it is an overrule.
    public var overrules: String?
    /// Unanswered: whom it waits for now (`the controller`, `you`).
    public var waitsFor: String?

    public init(_ question: SwarmSteering.Question, rows: [SwarmSteer], numbers: [String: String] = [:]) {
        self.question = question.id
        text = question.row.text
        options = question.row.options
        category = question.row.category
        guard let answer = question.answer else {
            let step = SwarmLadder.position(question.row, rows: rows)
            waitsFor = step.step == .peer ? step.peer.map { SwarmAddress.task($0).label(numbers) } ?? "a peer"
                : step.step.title
            return
        }
        self.answer = answer.text
        by = answer.actor == .controller ? "the controller" : answer.actor == .you ? "you"
            : answer.from.flatMap(SwarmAddress.init(raw:))?.label(numbers) ?? answer.actor.rawValue
        reason = answer.reason
        if answer.kind == .overrule, let ref = answer.ref, ref.hasPrefix("steer:"), let old = Int64(ref.dropFirst(6)) {
            overrules = rows.first { $0.id == old }?.text
        }
    }

    /// What the CLI prints: the answer alone on the first line (what an agent acts on), then who gave it.
    public var printed: String {
        guard let answer else { return "question \(question) waits for \(waitsFor ?? "an answer")" }
        let who = [by, reason].compactMap(\.self).joined(separator: ": ")
        return answer + (who.isEmpty ? "" : "\n(answered by \(who))")
    }
}

/// `heed goal plan …`, `heed goal ask` and `heed swarm …`: the goal's active swarm, through `GoalOps`. The lead
/// proposes and asks; workers ask, message and note; approving is the owner's, from a terminal, never from a pane or a
/// background run.
public enum SwarmControl {
    /// Who a caller is in the swarm: a worker's task, the lead, you (a terminal outside heed), or another session.
    static func address(_ caller: GoalCaller?, swarm: GoalSwarm, fromRun: Bool) -> SwarmAddress? {
        guard let caller else { return fromRun ? nil : .you }
        if let task = caller.worker { return .task(task) }
        if caller.session == swarm.lead { return .lead }
        return .session(caller.session)
    }

    static func actor(_ address: SwarmAddress?) -> SwarmSteer.Actor {
        switch address {
        case .lead?: .lead
        case .you?: .you
        default: .agent
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        _ command: GoalCommand, goal: HeedGoal, caller: GoalCaller?, ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        if command.verb == .swarmSummary { return try await summary(
            command,
            goal: goal,
            caller: caller,
            ops: ops,
            now: now
        ) }
        guard let swarm = try await ops.activeSwarm(of: goal.id) else {
            return .refused(GoalOpError.noSwarm(goal.id).description, goal: goal.id)
        }
        let address = address(caller, swarm: swarm, fromRun: command.fromRun == true)
        let actor = actor(address)
        switch command.verb {
        case .planShow:
            let board = try await ops.board(of: swarm.id)
            var view = SwarmPlanView(board)
            if let address, address.isAgent {
                let numbers = SwarmPlan.numbers(board.tasks)
                let waiting = SwarmDelivery.pending(for: address, board.steering, numbers: numbers, now: .distantFuture)
                view.inbox = waiting.map(\.line)
                for item in waiting {
                    try await ops.delivered(
                        swarm: swarm.id, row: item.row.id ?? 0, to: address, how: "read in plan show", now: now
                    )
                }
            }
            return GoalReply("read", message: view.text, goal: goal.id, version: view.version, plan: view)
        case .planPropose:
            let board = try await ops.board(of: swarm.id)
            let items = try await ops.snapshot().items(of: goal.id)
            let input: SwarmPlanInput
            do {
                input = try SwarmPlanInput.parse(command.text ?? "", goal: goal.id, current: board.tasks, items: items)
            } catch let error as SwarmPlanInput.ParseError {
                return .refused(error.description, goal: goal.id)
            }
            var stated = input
            if let note = command.note.map(GoalDoc.oneLine), !note.isEmpty { stated.note = note }
            let done = try await ops.proposePlan(
                swarm: swarm.id, input: stated, actor: actor == .lead ? .lead : .agent, ref: caller?.session, now: now
            )
            let view = try await SwarmPlanView(ops.board(of: swarm.id))
            let scope = done.scope.count(where: { $0.state == .proposed })
            let also = scope == 0 ? "" : "; \(scope) GOAL.md change\(scope == 1 ? "" : "s") wait for the owner"
            return switch done.outcome {
            case .applied:
                GoalReply(
                    "applied",
                    message: "plan v\(done.version ?? 0) (\(view.tasks.count) tasks)" + (swarm.approved == nil
                        ? ": a draft, the owner reads and approves it in heed" :
                        ": a \(done.size.rawValue) change, applied")
                        + also, goal: goal.id, version: done.version, plan: view
                )
            case .pending:
                GoalReply(
                    "proposed", message: "a structural change: it waits for the owner in heed's plan pane" + also,
                    goal: goal.id, plan: view
                )
            case .unchanged:
                GoalReply("moot", message: "the plan already says so" + also, goal: goal.id, plan: view)
            }
        case .planApprove:
            guard caller == nil, command.fromRun != true else {
                return .refused(
                    "approving a plan is the owner's: in heed (A in the plan pane), or heed goal plan approve from a "
                        + "terminal outside heed", goal: goal.id
                )
            }
            let version = try await ops.approvePlan(swarm: swarm.id, now: now)
            return GoalReply(
                "applied", message: "approved plan v\(version.number): its tasks are on the goal's board",
                goal: goal.id, version: version.number
            )
        case .ask:
            return try await ask(
                command,
                goal: goal,
                swarm: swarm,
                address: address,
                actor: actor,
                caller: caller,
                ops: ops,
                now: now
            )
        case .swarmSend:
            let board = try await ops.board(of: swarm.id)
            let tasks = board.tasks
            guard let word = command.to, let to = SwarmAddress.parse(word, tasks: tasks) else {
                return .refused(GoalOpError.unknownAddress(command.to ?? "").description, goal: goal.id)
            }
            guard to != address else { return .refused("that is you: send it to someone else", goal: goal.id) }
            let sent = try await ops.message(
                swarm: swarm.id, from: address ?? .session(caller?.session ?? "run"), to: to, text: command.text ?? "",
                actor: actor, now: now
            )
            let numbers = SwarmPlan.numbers(tasks)
            let live = Set(swarm.liveWorkers.map(\.task))
            let note = switch to {
            case let .task(task) where !live.contains(task):
                ": no worker is on it now, the next one reads it in heed goal plan show"
            case .all: " (\(sent.targets?.count ?? 0) at work): heed types it into each pane once its agent is idle"
            case .you: ": it is in the steering log"
            default: ": heed types it into its pane once its agent is idle"
            }
            return GoalReply("sent", message: "sent to \(to.label(numbers))" + note, goal: goal.id)
        case .swarmNote:
            guard let address, address != .you else {
                return .refused("notes are an agent's, from its pane", goal: goal.id)
            }
            try await ops.note(swarm: swarm.id, from: address, text: command.text ?? "", actor: actor, now: now)
            return GoalReply("noted", message: "noted: the plan pane and your task's log show it", goal: goal.id)
        case .swarmAnswer:
            let question = command.question ?? 0
            let answered = try await ops.answer(
                swarm: swarm.id, question: question, text: command.text ?? "", actor: actor, from: address, now: now
            )
            let board = try await ops.board(of: swarm.id)
            let asker = board.questions.first { $0.id == question }?.row.from.flatMap(SwarmAddress.init(raw:))
            let to = asker?.label(SwarmPlan.numbers(board.tasks)) ?? "the asker"
            return GoalReply(
                "answered",
                message: (answered.kind == .overrule ? "overruled: " : "answered: ") +
                    "\(to) gets \"\(answered.text)\"",
                goal: goal.id, question: question
            )
        default:
            preconditionFailure("not a swarm command")
        }
    }

    /// `swarm summary`: the lead's end-of-build summary, on the goal's newest swarm run (done, or landing its last
    /// PRs). Only the lead writes it, or you from a terminal outside heed.
    static func summary(
        _ command: GoalCommand, goal: HeedGoal, caller: GoalCaller?, ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        let runs = try await ops.snapshot().swarms(of: goal.id)
        guard let swarm = runs.first(where: \.status.active) ?? runs.first else {
            return .refused(GoalOpError.noSwarm(goal.id).description, goal: goal.id)
        }
        let address = address(caller, swarm: swarm, fromRun: command.fromRun == true)
        guard address == .lead || address == .you else {
            return .refused("the summary is the lead's to write", goal: goal.id)
        }
        try await ops.writeSummary(
            swarm: swarm.id, outcome: command.text, decisions: command.decisions ?? [],
            followUps: command.followUps ?? [], now: now
        )
        return GoalReply(
            "applied", message: "summary written: it goes into History, the ledger and the goal's page"
                + ((command.decisions ?? []).isEmpty ? "" : "; its decisions into GOAL.md"),
            goal: goal.id
        )
    }

    // swiftlint:disable:next function_parameter_count
    /// `ask`: a new question (it may be answered at once, as a repeat), or `--id`: where one stands. Read while
    /// answered, the asker has its answer: heed does not type it into the pane too.
    static func ask(
        _ command: GoalCommand, goal: HeedGoal, swarm: GoalSwarm, address: SwarmAddress?, actor: SwarmSteer.Actor,
        caller: GoalCaller?, ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        var id = command.question
        if id == nil {
            let board = try await ops.board(of: swarm.id)
            var target: SwarmAuthority.Target?
            if let word = command.to {
                switch SwarmAddress.parse(word, tasks: board.tasks) {
                case .lead?: target = .lead
                case .you?: target = .you
                case let .task(task)?: target = .task(task)
                default: return .refused(GoalOpError.unknownAddress(word).description, goal: goal.id)
                }
            }
            let asked = try await ops.ask(
                swarm: swarm.id, question: command.text ?? "", options: command.options ?? [],
                effects: command.effects ?? [], from: address == .you ? nil : address, to: target,
                actor: actor == .you ? .agent : actor, ref: caller?.session, now: now
            )
            id = asked.id
        }
        let board = try await ops.board(of: swarm.id)
        guard let id, let question = board.questions.first(where: { $0.id == id }) else {
            return .refused(GoalOpError.unknownQuestion(id ?? 0).description, goal: goal.id)
        }
        let view = SwarmAnswerView(question, rows: board.steering, numbers: SwarmPlan.numbers(board.tasks))
        guard let answer = question.answer else {
            return GoalReply(
                "asked", message: "asked (\(id)): it waits for \(view.waitsFor ?? "an answer")", goal: goal.id,
                question: id, answer: view
            )
        }
        if let asker = question.row.from.flatMap(SwarmAddress.init(raw:)), asker == address, let answerID = answer.id,
           !board.steering.contains(where: { $0.kind == .deliver && $0.about == answerID && $0.ref == asker.raw })
        {
            try await ops.delivered(swarm: swarm.id, row: answerID, to: asker, how: "read by heed goal ask", now: now)
        }
        return GoalReply("answered", message: view.printed, goal: goal.id, question: id, answer: view)
    }
}
