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
    /// The tier it ran at, when it was not the old cheap one (a look from before tiers has none).
    public var tier: LLMTier?

    public init(
        milestone: SessionMilestone, seats: [PanelSeat], verdicts: [PanelVerdict], at: Date, model: String? = nil,
        seconds: Double = 0, dollars: Double? = nil, diff: DiffStat? = nil, sent: Bool = false, tier: LLMTier? = nil
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
        self.tier = tier
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
        let words = Self.words(top.fix ?? top.quote, limit: 12)
        // A fix that names its persona already ("team style: …") is not named twice.
        return words.lowercased().hasPrefix(who + ":") ? words : "\(who): " + words
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

    /// What Send to the agent sends, in heed's voice. By default the concerns and objections, each with its full
    /// reasoning, what would change its mind and its fix; nil when everyone is happy (nothing to send). `seat` limits
    /// it to one persona, whatever it said; `everyone` adds the happy ones' headlines to all the rest.
    public func message(seat only: String? = nil, everyone: Bool = false) -> String? {
        let chosen = verdicts.filter { verdict in
            if let only { return verdict.seat == only }
            return everyone || verdict.kind != .happy
        }
        guard !chosen.isEmpty else { return nil }
        let blocks = chosen.map { verdict -> String in
            let who = seat(verdict.seat)?.name ?? verdict.seat
            let word = switch verdict.kind {
            case .not: "against"
            case .concern: "concern"
            case .happy: "happy"
            }
            var block = "- \(who) (\(word)): \(verdict.quote)"
            if let reasoning = verdict.reasoning, verdict.kind != .happy || only != nil || everyone {
                block += "\n" + Self.indented(reasoning)
            }
            if let change = verdict.change, verdict.kind != .happy {
                block += "\n  What would change their mind: \(change)"
            }
            if let fix = verdict.fix { block += "\n  Suggested: \(fix)." }
            return block
        }
        let lead = chosen.count == 1 && only != nil ? "one persona on the panel" : "the panel"
        return "From heed, \(lead) looked at your work (\(milestone.kind.title.lowercased())):\n"
            + blocks.joined(separator: "\n")
            + "\nConsider \(chosen.count == 1 ? "this" : "these") before you go on; say if you disagree."
    }

    /// The concerns and objections: what Send to the agent sends by default, and what a held PR sends first.
    public var message: String? { message() }

    private static func indented(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n")
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
    (carry on if one thing changes) or not (this is going the wrong way). For each persona give: "headline", one line \
    of at most fifteen words, first person, about this diff; "reasoning", two to five sentences in its voice, \
    concrete, naming the files and lines of the diff that made it decide; "change", what would change its mind, one \
    sentence (for happy: what would turn it into a concern); and "fix", unless happy, the one change in at most \
    eight words. Judge only what is in front of you. Reply with only JSON: \
    {"verdicts": [{"persona": "<id>", "verdict": "happy|concern|not", "headline": "...", "reasoning": "...", \
    "change": "...", "fix": "..." or null}]}.
    """

    /// What a look that may read the code adds (the `strong` tier runs in the session's worktree).
    public static let readsCode = """
     You may read and search the files in your working directory to check what the diff touches (callers, tests, \
     neighbouring code); never change a file. Name what you found there.
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

/// The session panel's model calls: the look, and a persona's chat reply. At `cheap` and `standard` they go through
/// heed's model calls (`LLMRunner`, tools off); at `strong` through a headless read-only run in the session's worktree
/// (`PlanTalker.read`, the goal wizard's planner's run), so the personas can read the code around the diff. When no
/// such run can be made (a remote session, no worktree, an agent that cannot run headless) the call is made at
/// `standard` and the look says so.
public struct SessionLookCalls: Sendable {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse
    /// The headless read-only run: instructions, input and the folders to read. nil: it cannot run here.
    public typealias Read = @Sendable (_ system: String, _ prompt: String, _ repos: [String]) async throws
        -> PlanTalker.Answer?
    private let run: Run
    private let read: Read?

    public init(run: @escaping Run, read: Read? = nil) {
        self.run = run
        self.read = read
    }

    public static let caller = "sessions.panel"

    /// One answer: from the read-only run when `tier` is strong and it can run, else from `run` at the tier (strong
    /// falling back to standard). `usedRead` says which.
    private func ask(
        system: String, prompt: String, operation: String, tier: LLMTier, repos: [String]
    ) async throws -> (text: String, model: String?, dollars: Double?, seconds: Double, tier: LLMTier) {
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> Double {
            let span = start.duration(to: clock.now).components
            return Double(span.seconds) + Double(span.attoseconds) / 1e18
        }
        if tier == .strong, !repos.isEmpty, let read,
           let answer = try await read(Self.system(system, readsCode: true), prompt, repos)
        {
            return (answer.text, answer.model, answer.dollars, seconds(), .strong)
        }
        let used: LLMTier = tier == .strong ? .standard : tier
        let response = try await run(LLMRequest(
            call: LLMCall(system: system, prompt: prompt), priority: .interactive, caller: Self.caller,
            operation: operation, tier: used
        ))
        return (
            response.text, response.model ?? response.agent, response.fromCache ? 0 : response.cost, response.duration,
            used
        )
    }

    private static func system(_ base: String, readsCode: Bool) -> String {
        readsCode ? base + SessionLookPrompt.readsCode : base
    }

    /// One call for every seat; verdicts read by the goal panel's parser.
    public func look(
        milestone: SessionMilestone, task: String, lastTurn: String?, diff: String, stat: DiffStat?,
        seats: [PanelSeat], now: Date, tier: LLMTier = .standard, repos: [String] = []
    ) async throws -> SessionLook {
        let prompt = SessionLookPrompt.prompt(
            milestone: milestone, task: task, lastTurn: lastTurn, diff: diff, stat: stat, seats: seats
        )
        let answer = try await ask(
            system: SessionLookPrompt.system, prompt: prompt, operation: "panel look", tier: tier, repos: repos
        )
        let verdicts = PanelVerdict.parse(answer.text, seats: seats)
        guard !verdicts.isEmpty
        else { throw LLMError.unparseable(agent: answer.model ?? "the panel", text: answer.text) }
        return SessionLook(
            milestone: milestone, seats: seats, verdicts: verdicts, at: now, model: answer.model,
            seconds: answer.seconds, dollars: answer.dollars, diff: stat, tier: answer.tier
        )
    }

    static let chatSystem = """
    You are one persona on a panel that looked at a coding agent's work in progress, talking with the developer who \
    runs the agent. Stay in character, answer their last message in at most three short sentences, concrete, and say \
    what would change your verdict. You never talk to the agent yourself.
    """

    /// A persona's reply in "Talk to one": its verdict, reasoning and what would change its mind are the context.
    public func reply(
        _ chat: PersonaChat, look: SessionLook, task: String, tier: LLMTier = .standard, repos: [String] = []
    ) async throws -> String {
        var context = "# The task\n" + SessionLookPrompt.bounded(task, limit: SessionLookPrompt.taskLimit)
        if let verdict = look.verdicts.first(where: { $0.seat == chat.seat.id }) {
            context += "\n\n# Your verdict\n\(verdict.kind.rawValue): \(verdict.quote)"
            if let reasoning = verdict.reasoning { context += "\nYour reasoning: \(reasoning)" }
            if let change = verdict.change { context += "\nWhat would change your mind: \(change)" }
            if let fix = verdict.fix { context += "\nFix: \(fix)" }
        }
        let answer = try await ask(
            system: Self.chatSystem + "\n\nYou are: \(chat.seat.name), \(chat.seat.role). \(chat.seat.brief)",
            prompt: context + "\n\n# The conversation\n" + chat.transcript, operation: "panel chat", tier: tier,
            repos: repos
        )
        return answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
