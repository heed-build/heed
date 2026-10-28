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
        questions = board.questions.map {
            Question(id: $0.id, text: $0.row.text, options: $0.row.options, answer: $0.answer?.text)
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
                lines.append("     " + (question.answer.map { "answer: \($0)" } ?? "not answered yet"))
            }
        }
        if !feedback.isEmpty {
            lines += ["", "The owner asks you to re-plan"] + feedback.map { "  - \($0)" }
        }
        if let waiting { lines += ["", "Waiting for the owner: \(waiting)"] }
        if let rejected { lines += ["", "The owner said no to: \(rejected)"] }
        return lines.joined(separator: "\n")
    }
}

/// `heed goal plan …` and `heed goal ask`: the goal's active swarm, through `GoalOps`. The lead proposes and asks;
/// approving is the owner's, from a terminal, never from a pane or a background run.
public enum SwarmControl {
    static func run(
        _ command: GoalCommand, goal: HeedGoal, caller: GoalCaller?, ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        guard let swarm = try await ops.activeSwarm(of: goal.id) else {
            return .refused(GoalOpError.noSwarm(goal.id).description, goal: goal.id)
        }
        let actor: SwarmSteer.Actor = caller?.session == swarm.lead && caller != nil && caller?
            .worker == nil ? .lead : .agent
        switch command.verb {
        case .planShow:
            let view = try await SwarmPlanView(ops.board(of: swarm.id))
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
                swarm: swarm.id, input: stated, actor: actor, ref: caller?.session, now: now
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
            let asked = try await ops.ask(
                swarm: swarm.id, question: command.text ?? "", options: command.options ?? [], actor: actor,
                ref: caller?.session, now: now
            )
            return GoalReply(
                "asked", message: "asked (\(asked.id ?? 0)): it shows in heed's plan pane; heed goal plan show has the "
                    + "answer once there is one", goal: goal.id
            )
        default:
            preconditionFailure("not a swarm command")
        }
    }
}
