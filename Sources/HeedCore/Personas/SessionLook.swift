import Foundation

/// The panel's look at a session's work: who looked, at what milestone, each one's verdict (the goal panel's kinds,
/// read by the same parser), and what it cost. Personas never type into the session: what they say reaches the agent
/// only when you send it.
public struct SessionLook: Hashable, Sendable, Codable {
    public var milestone: SessionMilestone
    public var seats: [PanelSeat]
    public var verdicts: [PanelVerdict]
    public var at: Date
    /// The model that answered, the seconds it took and what it cost, when known.
    public var model: String?
    public var seconds: Double
    public var dollars: Double?
    /// The diff they read.
    public var diff: DiffStat?
    /// You sent it to the agent.
    public var sent: Bool

    public init(
        milestone: SessionMilestone, seats: [PanelSeat], verdicts: [PanelVerdict], at: Date, model: String? = nil,
        seconds: Double = 0, dollars: Double? = nil, diff: DiffStat? = nil, sent: Bool = false
    ) {
        self.milestone = milestone
        self.seats = seats
        self.verdicts = verdicts
        self.at = at
        self.model = model
        self.seconds = seconds
        self.dollars = dollars
        self.diff = diff
        self.sent = sent
    }

    public func count(_ kind: PanelVerdict.Kind) -> Int { verdicts.count { $0.kind == kind } }

    public func seat(_ id: String) -> PanelSeat? { seats.first { $0.id == id } }

    /// Someone has a concern, or argues against it.
    public var worried: Bool { verdicts.contains { $0.kind != .happy } }

    /// The verdict the line leads with: the first against it, else the first concern.
    public var top: PanelVerdict? {
        verdicts.first { $0.kind == .not } ?? verdicts.first { $0.kind == .concern }
    }

    /// The top concern in a few words, after its persona: `team style: test names describe the bug, not the…`.
    public var topLine: String? {
        guard let top else { return nil }
        let who = seat(top.seat).map { Self.short($0.name) } ?? top.seat
        return "\(who): " + Self.words(top.fix ?? top.quote, limit: 9)
    }

    /// "Your team's style" → "team style", "Docs-site maintainer" → "docs-site maintainer".
    static func short(_ name: String) -> String {
        var name = name.lowercased()
        for prefix in ["your ", "our ", "the "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name.replacingOccurrences(of: "team's style", with: "team style")
    }

    /// At most `limit` words, an ellipsis when cut.
    static func words(_ text: String, limit: Int) -> String {
        let words = text.split(separator: " ")
        let cut = words.prefix(limit).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        return words.count > limit ? cut + "…" : cut
    }

    /// What Send to the agent sends: the concerns and objections, each with its fix, in heed's voice. Nil when
    /// everyone is happy (nothing to send).
    public var message: String? {
        let worried = verdicts.filter { $0.kind != .happy }
        guard !worried.isEmpty else { return nil }
        let lines = worried.map { verdict -> String in
            let who = seat(verdict.seat)?.name ?? verdict.seat
            let fix = verdict.fix.map { " Suggested: \($0)." } ?? ""
            return "- \(who) (\(verdict.kind == .not ? "against" : "concern")): \(verdict.quote)\(fix)"
        }
        return "From heed, the panel looked at your work (\(milestone.kind.title.lowercased())):\n"
            + lines.joined(separator: "\n")
            + "\nConsider these before you go on; say if you disagree."
    }
}

/// What a session's panel is given to read: the task, the agent's plan and last turn, and the diff, each bounded, so
/// one cheap call reads it all.
public enum SessionLookPrompt {
    public static let diffLimit = 12000
    public static let turnLimit = 3000
    public static let taskLimit = 1500
    /// The least each file of a long diff keeps.
    static let fileFloor = 600

    public static let system = """
    You are a panel of reviewers looking at a coding agent's work in progress: its task, its plan or last message, \
    and its diff so far. Each persona below reads it in its own voice and gives a verdict: happy (carry on), concern \
    (carry on if one thing changes) or not (this is going the wrong way). Each says one short quote (at most fifteen \
    words, first person, concrete, about this diff) and, unless happy, one fix in at most eight words. Judge only \
    what is in front of you. Reply with only JSON: \
    {"verdicts": [{"persona": "<id>", "verdict": "happy|concern|not", "quote": "...", "fix": "..." or null}]}.
    """

    /// The prompt for `seats`, at `milestone`.
    public static func prompt(
        milestone: SessionMilestone, task: String, lastTurn: String?, diff: String, stat: DiffStat?,
        seats: [PanelSeat]
    ) -> String {
        let personas = seats.map { "- \($0.id) (\($0.name), \($0.role)): \($0.brief)" }.joined(separator: "\n")
        var parts = [
            "# Why you are looking\n" + ([milestone.kind.title] + milestone.details).joined(separator: " · "),
            "# The task\n" + bounded(task, limit: taskLimit),
        ]
        if let lastTurn, !lastTurn.isEmpty {
            parts.append("# The agent's plan or last message\n" + bounded(lastTurn, limit: turnLimit))
        }
        parts.append(
            "# The diff" + (stat.map { " (\($0.text))" } ?? "") + "\n"
                + (diff.isEmpty ? "(no changes yet)" : bounded(diff: diff, limit: diffLimit))
        )
        parts.append("# The personas\n" + personas)
        return parts.joined(separator: "\n\n")
    }

    /// The text's start, at most `limit` characters, saying how much was left out.
    public static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)"
    }

    /// A unified diff within `limit`: every file keeps its header and an equal share of the room (at least
    /// `fileFloor`), so one big file does not crowd the others out; then the whole is cut at `limit`.
    public static func bounded(diff: String, limit: Int) -> String {
        guard diff.count > limit else { return diff }
        let files = splitFiles(diff)
        guard files.count > 1 else { return bounded(diff, limit: limit) }
        let share = max(limit / files.count, fileFloor)
        let kept = files.map { bounded($0, limit: share) }.joined(separator: "\n")
        return bounded(kept, limit: limit)
    }

    /// The diff, one piece per file (each starts at its `diff --git` line).
    static func splitFiles(_ diff: String) -> [String] {
        var files: [String] = []
        var current: [Substring] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git"), !current.isEmpty {
                files.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { files.append(current.joined(separator: "\n")) }
        return files
    }
}

/// The session panel's cheap model calls, through heed's model calls (`LLMRunner`, the cheap model, tools off): the
/// look, and a persona's chat reply.
public struct SessionLookCalls: Sendable {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse
    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    public static let caller = "sessions.panel"

    /// One call for every seat; verdicts read by the goal panel's parser.
    public func look(
        milestone: SessionMilestone, task: String, lastTurn: String?, diff: String, stat: DiffStat?,
        seats: [PanelSeat], now: Date
    ) async throws -> SessionLook {
        let prompt = SessionLookPrompt.prompt(
            milestone: milestone, task: task, lastTurn: lastTurn, diff: diff, stat: stat, seats: seats
        )
        let response = try await run(LLMRequest(
            call: LLMCall(system: SessionLookPrompt.system, prompt: prompt), priority: .interactive,
            caller: Self.caller, operation: "panel look"
        ))
        let verdicts = PanelVerdict.parse(response.text, seats: seats)
        guard !verdicts.isEmpty else { throw LLMError.unparseable(agent: response.agent, text: response.text) }
        return SessionLook(
            milestone: milestone, seats: seats, verdicts: verdicts, at: now, model: response.model ?? response.agent,
            seconds: response.duration, dollars: response.fromCache ? 0 : response.cost, diff: stat
        )
    }

    static let chatSystem = """
    You are one persona on a panel that looked at a coding agent's work in progress, talking with the developer who \
    runs the agent. Stay in character, answer their last message in at most three short sentences, concrete, and say \
    what would change your verdict. You never talk to the agent yourself.
    """

    /// A persona's reply in "Talk to one".
    public func reply(_ chat: PersonaChat, look: SessionLook, task: String) async throws -> String {
        let verdict = look.verdicts.first { $0.seat == chat.seat.id }
        let context = "# The task\n" + SessionLookPrompt.bounded(task, limit: SessionLookPrompt.taskLimit)
            +
            (verdict
                .map { "\n\n# Your verdict\n\($0.kind.rawValue): \($0.quote)" + ($0.fix.map { " Fix: \($0)" } ?? "") }
                ?? "")
        let response = try await run(LLMRequest(
            call: LLMCall(
                system: Self.chatSystem + "\n\nYou are: \(chat.seat.name), \(chat.seat.role). \(chat.seat.brief)",
                prompt: context + "\n\n# The conversation\n" + chat.transcript
            ),
            priority: .interactive, caller: Self.caller, operation: "panel chat"
        ))
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
