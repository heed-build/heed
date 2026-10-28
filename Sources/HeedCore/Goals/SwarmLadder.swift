import Foundation

/// Who a swarm row is from or for: you, the lead, a task's worker, everyone at work, or another session on the goal.
/// Stored in `SwarmSteer.from`, `to` and `targets` as `you`, `lead`, `all`, `task:<item id>`, `session:<id>`.
public enum SwarmAddress: Hashable, Sendable {
    case you, lead, all, controller, heed
    case task(String)
    case session(String)

    public init?(raw: String) {
        switch raw {
        case "you": self = .you
        case "lead": self = .lead
        case "all": self = .all
        case "controller": self = .controller
        case "heed": self = .heed
        default:
            if raw.hasPrefix("task:"), raw.count > 5 {
                self = .task(String(raw.dropFirst(5)))
            } else if raw.hasPrefix("session:"), raw.count > 8 {
                self = .session(String(raw.dropFirst(8)))
            } else {
                return nil
            }
        }
    }

    public var raw: String {
        switch self {
        case .you: "you"
        case .lead: "lead"
        case .all: "all"
        case .controller: "controller"
        case .heed: "heed"
        case let .task(id): "task:\(id)"
        case let .session(id): "session:\(id)"
        }
    }

    /// An agent heed can hand things to: the lead, or a task's worker.
    public var isAgent: Bool {
        switch self {
        case .lead, .task: true
        default: false
        }
    }

    /// `you`, `the lead`, `everyone`, `2.1`, `a session`: `numbers` from `SwarmPlan.numbers`.
    public func label(_ numbers: [String: String] = [:]) -> String {
        switch self {
        case .you: "you"
        case .lead: "the lead"
        case .all: "everyone"
        case .controller: "the controller"
        case .heed: "heed"
        case let .task(id): numbers[id].map { "task \($0)" } ?? SwarmPlan.short(id)
        case .session: "a session on the goal"
        }
    }

    /// A word typed after `heed swarm send` or `--to`: `lead`, `@all` (or `all`), `you`, a task's number (`2.1`), its
    /// slug or its id. Nil when it names nothing in `tasks`.
    public static func parse(_ word: String, tasks: [SwarmTask]) -> SwarmAddress? {
        let word = word.trimmingCharacters(in: .whitespaces)
        switch word.lowercased() {
        case "lead", "@lead": return .lead
        case "@all", "all", "everyone": return .all
        case "you", "@you", "owner", "me": return .you
        default: break
        }
        let bare = word.hasPrefix("@") ? String(word.dropFirst()) : word
        let numbers = SwarmPlan.numbers(tasks)
        if let task = tasks.first(where: { numbers[$0.id] == bare || $0.id == bare || $0.slug == bare }) {
            return .task(task.id)
        }
        return nil
    }
}

/// The escalation ladder a question climbs: a peer, then the controller, then you (`SwarmAuthority` says which steps
/// a question has). Its position is read from the rows: the question's first step, then each `escalate` row heed wrote
/// about it. Pure: the app asks `due` on a tick and does what it says.
public enum SwarmLadder {
    /// How long a step has before the question moves on. The controller's is how long its decider may take.
    public struct Timeouts: Equatable, Sendable {
        public var peer: TimeInterval
        public var lead: TimeInterval
        public var controller: TimeInterval

        public init(peer: TimeInterval = 600, lead: TimeInterval = 600, controller: TimeInterval = 180) {
            self.peer = peer
            self.lead = lead
            self.controller = controller
        }

        func of(_ step: SwarmAuthority.Answerer) -> TimeInterval? {
            switch step {
            case .peer: peer
            case .lead: lead
            case .controller: controller
            case .you: nil
            }
        }
    }

    /// Where a question is on its ladder.
    public struct Position: Equatable, Sendable {
        public var step: SwarmAuthority.Answerer
        /// Since when it is at that step.
        public var since: Date
        public var ladder: [SwarmAuthority.Answerer]
        /// The task asked at the peer step.
        public var peer: String?
    }

    /// What the app does about a question now.
    public enum Action: Equatable, Sendable {
        case none
        /// Move it to `step`, saying why.
        case escalate(SwarmAuthority.Answerer, String)
        /// Its step is the controller's: ask the deciders.
        case askController
    }

    /// The ladder a question row carries (rows from before S4: you alone).
    public static func ladder(of question: SwarmSteer) -> [SwarmAuthority.Answerer] {
        let steps = (question.ladder ?? []).compactMap(SwarmAuthority.Answerer.init(rawValue:))
        return steps.isEmpty ? [.you] : steps
    }

    public static func position(_ question: SwarmSteer, rows: [SwarmSteer]) -> Position {
        let ladder = ladder(of: question)
        let peer: String? = if case let .task(id)? = question.to.flatMap(SwarmAddress.init(raw:)) { id } else { nil }
        if let id = question.id, let moved = rows.last(where: { $0.kind == .escalate && $0.about == id }),
           let step = moved.step.flatMap(SwarmAuthority.Answerer.init(rawValue:))
        {
            return Position(step: step, since: moved.at, ladder: ladder, peer: peer)
        }
        let first = question.step.flatMap(SwarmAuthority.Answerer.init(rawValue:)) ?? ladder.first ?? .you
        return Position(step: first, since: question.at, ladder: ladder, peer: peer)
    }

    /// The step after `step`: the next on the ladder, else you.
    public static func next(after step: SwarmAuthority.Answerer, in ladder: [SwarmAuthority.Answerer])
        -> SwarmAuthority.Answerer
    {
        guard let index = ladder.firstIndex(of: step), index + 1 < ladder.count else { return .you }
        return ladder[index + 1]
    }

    /// What is due for an open question at `now`: nothing (answered, with you, or its step's time not up), the
    /// controller asked, or the next step.
    public static func due(
        _ question: SwarmSteering.Question, rows: [SwarmSteer], now: Date, timeouts: Timeouts = Timeouts()
    ) -> Action {
        guard question.answer == nil else { return .none }
        let position = position(question.row, rows: rows)
        guard let timeout = timeouts.of(position.step) else { return .none }
        let waited = now.timeIntervalSince(position.since)
        if waited >= timeout {
            let next = next(after: position.step, in: position.ladder)
            let why = switch position.step {
            case .peer: "no answer from the peer in \(minutes(timeout))"
            case .lead: "no answer from the lead in \(minutes(timeout))"
            case .controller: "the controller did not answer in \(minutes(timeout))"
            case .you: ""
            }
            return .escalate(next, why)
        }
        return position.step == .controller ? .askController : .none
    }

    /// The task owning the nearest work, for a worker's question: the first task it waits for whose worker is at work,
    /// else the first at work that waits for it. Nil when neither is at work: there is nobody to ask.
    public static func peer(for task: String, tasks: [SwarmTask], live: Set<String>) -> String? {
        guard let mine = tasks.first(where: { $0.id == task }) else { return nil }
        if let before = mine.after.first(where: { live.contains($0) }) { return before }
        return tasks.first { $0.after.contains(task) && live.contains($0.id) }?.id
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "a minute" : "\(minutes) min"
    }
}

/// What heed hands to agents (`heed swarm send`, answers to their questions, questions for a peer or the lead) and
/// when. Only into a pane whose agent is idle and that you have not typed in lately (`Delivery`); a worker reads what
/// waits for it in `plan show` too, and a waiting `heed goal ask` reads its answer itself. Each hand-over is a
/// `deliver` row, so nothing is handed over twice.
public enum SwarmDelivery {
    /// Something waiting for an agent.
    public struct Item: Equatable, Sendable {
        /// The message, question, answer or overrule.
        public var row: SwarmSteer
        public var to: SwarmAddress
        /// The line typed into its pane.
        public var line: String
    }

    /// A fresh answer waits this long for the asker's own `heed goal ask` to read it before heed types it (an
    /// overrule does not: the asker read the answer it overrules long ago).
    public static let answerGrace: TimeInterval = 30

    /// `about|to` of every hand-over so far.
    static func handed(_ rows: [SwarmSteer]) -> Set<String> {
        Set(rows.filter { $0.kind == .deliver }.compactMap { row in row.about.map { "\($0)|\(row.ref ?? "")" } })
    }

    /// What waits for an agent, oldest first. `waiting`: questions whose asker's `heed goal ask` is waiting now (it
    /// reads the answer itself). `numbers`: the plan's task numbers, for the lines.
    public static func pending(
        _ rows: [SwarmSteer], waiting: Set<Int64> = [], numbers: [String: String] = [:], now: Date
    ) -> [Item] {
        let handed = handed(rows)
        let questions = SwarmSteering.questions(rows)
        let byID = Dictionary(
            rows.compactMap { row in row.id.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [Item] = []
        func add(_ row: SwarmSteer, to address: SwarmAddress, line: String) {
            guard address.isAgent, let id = row.id, !handed.contains("\(id)|\(address.raw)") else { return }
            items.append(Item(row: row, to: address, line: GoalDoc.oneLine(line)))
        }
        for row in rows {
            switch row.kind {
            case .message:
                let targets = (row.targets ?? [row.to].compactMap(\.self)).compactMap(SwarmAddress.init(raw:))
                for target in targets where target.raw != row.from {
                    add(row, to: target, line: messageLine(row, numbers: numbers))
                }
            case .answer, .overrule:
                guard let about = row.about, let question = byID[about], question.kind == .question,
                      let asker = question.from.flatMap(SwarmAddress.init(raw:)), asker.raw != row.from,
                      !waiting.contains(about), row.kind == .overrule || now.timeIntervalSince(row.at) >= answerGrace
                else { continue }
                // Only the answer that stands: an older one overruled since is not worth typing.
                guard questions.first(where: { $0.id == about })?.answer?.id == row.id else { continue }
                add(row, to: asker, line: answerLine(row, question: question, numbers: numbers))
            default: continue
            }
        }
        for question in questions where question.answer == nil {
            let position = SwarmLadder.position(question.row, rows: rows)
            let target: SwarmAddress? = switch position.step {
            case .lead: .lead
            case .peer: position.peer.map(SwarmAddress.task)
            case .controller, .you: nil
            }
            if let target, target.raw != question.row.from {
                add(question.row, to: target, line: questionLine(question.row, numbers: numbers))
            }
        }
        return items.sorted { ($0.row.id ?? 0) < ($1.row.id ?? 0) }
    }

    /// What waits for one agent.
    public static func pending(
        for address: SwarmAddress, _ rows: [SwarmSteer], waiting: Set<Int64> = [], numbers: [String: String] = [:],
        now: Date
    ) -> [Item] {
        pending(rows, waiting: waiting, numbers: numbers, now: now).filter { $0.to == address }
    }

    // MARK: The lines

    static func from(_ row: SwarmSteer, numbers: [String: String]) -> String {
        row.from.flatMap(SwarmAddress.init(raw:))?.label(numbers) ?? (row.actor == .you ? "you" : row.actor.rawValue)
    }

    static func messageLine(_ row: SwarmSteer, numbers: [String: String]) -> String {
        let sender = from(row, numbers: numbers)
        let reply = row.from.flatMap(SwarmAddress.init(raw:)).flatMap(replyWord) ?? "lead"
        return "heed: message from \(sender): \(row.text) (reply: heed swarm send \(reply) \"…\")"
    }

    static func answerLine(_ row: SwarmSteer, question: SwarmSteer, numbers: [String: String]) -> String {
        let by = from(row, numbers: numbers)
        if row.kind == .overrule {
            return "heed: the owner overrules the answer to your question \"\(question.text)\": \(row.text)"
        }
        return "heed: answer to your question \"\(question.text)\" (by \(by)): \(row.text)"
    }

    static func questionLine(_ question: SwarmSteer, numbers: [String: String]) -> String {
        let asker = from(question, numbers: numbers)
        let options = question.options.isEmpty ? "" : " Options: " + question.options.joined(separator: " / ") + "."
        return "heed: \(asker) asks you (question \(question.id ?? 0)): \(question.text)\(options) Answer with heed "
            + "swarm answer \(question.id ?? 0) \"…\"; unanswered, it goes on up the ladder."
    }

    /// What `heed swarm send` takes to reach `address`.
    static func replyWord(_ address: SwarmAddress) -> String? {
        switch address {
        case .lead: "lead"
        case .you: "you"
        case let .task(id): SwarmPlan.short(id)
        default: nil
        }
    }
}

/// The agent-to-agent log of one task (deck p10): what was said to it and by it, its questions and their answers, its
/// progress notes.
public enum SwarmMessages {
    public static func log(of task: String, _ rows: [SwarmSteer]) -> [SwarmSteer] {
        let address = SwarmAddress.task(task).raw
        let asked = Set(rows.filter { $0.kind == .question && $0.from == address }.compactMap(\.id))
        let askedOfIt = Set(rows.filter { $0.kind == .question && $0.to == address }.compactMap(\.id))
        return rows.filter { row in
            switch row.kind {
            case .message:
                row.from == address || row.to == address || (row.targets ?? []).contains(address)
            case .note, .question: row.from == address || row.to == address
            case .answer, .overrule, .escalate, .suggest:
                row.about.map { asked.contains($0) || askedOfIt.contains($0) } ?? false
            default: false
            }
        }
    }
}
