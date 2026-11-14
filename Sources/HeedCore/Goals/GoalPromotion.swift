import Foundation

/// A session growing into a goal: what heed has seen that says so. The rule is plain on purpose: two PRs or more, a
/// second repo, or the agent saying it found work it did not start. A chat, a session on a goal already, and one you
/// said "not now" for never grow.
public struct GoalGrowth: Hashable, Sendable {
    /// PRs the session opened (tracked).
    public var pulls: Int
    /// Of those, merged.
    public var merged: Int
    /// Repos it works in, its worktrees' and its PRs'.
    public var repos: Int
    /// What its agent said it found and did not start, a few words each.
    public var found: [String]

    public init(pulls: Int = 0, merged: Int = 0, repos: Int = 1, found: [String] = []) {
        self.pulls = pulls
        self.merged = merged
        self.repos = repos
        self.found = found
    }

    /// Any sign at all.
    public var grows: Bool { pulls >= 2 || repos >= 2 || !found.isEmpty }

    /// The line's signs: `3 PRs`, `2nd repo`, `found work it didn't start`.
    public var signs: [String] {
        var signs: [String] = []
        if pulls >= 2 { signs.append("\(pulls) PRs") }
        if repos >= 2 { signs.append(repos == 2 ? "2nd repo" : "\(repos) repos") }
        if !found.isEmpty { signs.append("found work it didn't start") }
        return signs
    }

    /// How a session stands: nil when it is not growing (or cannot: a chat, on a goal, set aside).
    public static func of(
        _ session: Session, pullState: (PullRef) -> PullRequest.State?, onGoal: Bool, setAside: Bool
    ) -> GoalGrowth? {
        guard !session.isChat, !onGoal, !setAside else { return nil }
        let growth = GoalGrowth(
            pulls: session.trackedPRs.count,
            merged: session.trackedPRs.count { pullState($0) == .merged },
            repos: Set(session.involvedRepos.map(\.slug)).count,
            found: found(in: session.lastMessage)
        )
        return growth.grows ? growth : nil
    }

    /// Phrases an agent uses for work it saw and left: a follow-up, out of scope, not started, a separate PR, still
    /// broken elsewhere.
    static let markers = [
        "follow-up", "follow up", "followup", "out of scope", "didn't start", "did not start", "not started",
        "haven't started", "have not started", "left for later", "separate pr", "another pr", "a later pr",
        "still break", "still needs", "still fail", "is a change in", "that's a change in", "would also need",
        "should also",
    ]

    /// The sentences of the agent's last message that name work it found and did not start, at most three: what a
    /// model call summarises (`FoundWork`).
    public static func foundSentences(in message: String?) -> [String] {
        guard let message, !message.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for character in message {
            current.append(character)
            if ".!?\n".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return Array(
            sentences
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*•"))) }
                .filter { sentence in markers.contains { sentence.lowercased().contains($0) } }
                .prefix(3)
        )
    }

    /// What was found, short, without a model: per sentence the clause that names it ("its old links still break",
    /// "a change in docs-website"), or what follows "Follow-up:"; at most 48 characters each.
    public static func found(in message: String?) -> [String] {
        foundSentences(in: message).map(clause)
    }

    static func clause(_ sentence: String) -> String {
        var text = sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        // "Out of scope: the theme" names the work after the colon.
        if let colon = text.firstIndex(of: ":") {
            let head = text[..<colon].lowercased()
            let tail = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if markers.contains(where: { head.contains($0) }), !tail.isEmpty { text = tail }
        }
        let clauses = text.split(whereSeparator: { ",;:".contains($0) }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var picked = clauses.first { clause in markers.contains { clause.lowercased().contains($0) } }
            ?? clauses.first ?? text
        for lead in ["so ", "but ", "and ", "then ", "that's ", "that is ", "this is ", "it's ", "which "]
            where picked.lowercased().hasPrefix(lead)
        {
            picked = String(picked.dropFirst(lead.count))
        }
        picked = picked.trimmingCharacters(in: .whitespaces)
        return picked.count > 48 ? String(picked.prefix(47)) + "…" : picked
    }
}

/// What a session found, as short noun phrases ("the website's vendored slug copy", "a sample-site proof"), from one
/// cheap model call when there is one; `GoalGrowth.found`'s clauses stand in until it answers, or when it cannot.
public enum FoundWork {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse

    static let system = """
    You turn what a coding agent said it found and did not start into short noun phrases, one per piece of work, of \
    at most six words each, lowercase unless a name, no period: "the website's vendored slug copy", "a sample-site \
    proof". Only work it names; at most three. Reply with only the JSON the schema asks for.
    """

    static let schema = """
    {"type":"object","properties":{"items":{"type":"array","items":{"type":"string"},"maxItems":3}},\
    "required":["items"],"additionalProperties":false}
    """

    /// The call: you pressed gP, so it goes first.
    public static func request(_ sentences: [String]) -> LLMRequest {
        LLMRequest(
            call: LLMCall(system: system, prompt: sentences.joined(separator: "\n"), schema: schema),
            priority: .interactive, caller: "goal.promote", operation: "name found work"
        )
    }

    /// The phrases from the call's JSON, one line each and at most 48 characters; nil when there are none.
    public static func read(_ json: Data?) -> [String]? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = object["items"] as? [String]
        else { return nil }
        let phrases = items.map { GoalDoc.oneLine($0).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }.prefix(3)
            .map { $0.count > 48 ? String($0.prefix(47)) + "…" : $0 }
        return phrases.isEmpty ? nil : Array(phrases)
    }

    /// The phrases for `sentences`, or nil (no sentences, the call failed, nothing usable).
    public static func summarise(_ sentences: [String], run: Run) async -> [String]? {
        guard !sentences.isEmpty, let response = try? await run(request(sentences)) else { return nil }
        return read(response.json)
    }
}

/// Make it a goal: the goal a growing session becomes. The session stays on it as its first part, its merged PRs
/// count as done parts, and what its agent found becomes planned parts. Nothing restarts.
public struct GoalPromotion: Hashable, Sendable {
    /// A merged PR, a done part.
    public struct Part: Hashable, Sendable {
        public var pull: PullRef
        public var title: String

        public init(pull: PullRef, title: String) {
            self.pull = pull
            self.title = title
        }
    }

    public var session: String
    public var title: String
    /// GOAL.md's statement: the session's prompt, its first paragraph.
    public var statement: String
    public var done: [Part]
    public var found: [String]

    public init(session: String, title: String, statement: String, done: [Part] = [], found: [String] = []) {
        self.session = session
        self.title = title
        self.statement = statement
        self.done = done
        self.found = found
    }

    /// The draft for `session`: its title and prompt, its merged PRs (titled where known) and what was found.
    public static func draft(
        _ session: Session, growth: GoalGrowth?, pull: (PullRef) -> (state: PullRequest.State, title: String)?
    ) -> GoalPromotion {
        let done = session.trackedPRs.compactMap { ref -> Part? in
            guard let known = pull(ref), known.state == .merged else { return nil }
            return Part(pull: ref, title: known.title.isEmpty ? "#\(ref.number)" : known.title)
        }
        let statement = firstParagraph(session.prompt)
        return GoalPromotion(
            session: session.id, title: session.title, statement: statement.isEmpty ? session.title : statement,
            done: done, found: growth?.found ?? GoalGrowth.found(in: session.lastMessage)
        )
    }

    static func firstParagraph(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The popover's lines, in order: the statement, the merged PRs, what was found, and that nothing restarts.
    public var lines: [(glyph: Glyph, text: String)] {
        var lines: [(Glyph, String)] = [(.goal, statement)]
        if !done.isEmpty {
            let count = done.count == 1 ? "its merged PR counts as the first part" :
                "its \(done.count) merged PRs count as the first parts"
            lines.append((.done, count + ", done"))
        }
        if !found.isEmpty { lines.append((.found, "found: " + found.joined(separator: " · "))) }
        lines.append((.stays, "this session stays as part 1; nothing restarts"))
        return lines
    }

    public enum Glyph: Hashable, Sendable {
        case goal, done, found, stays
    }
}

public extension GoalOps {
    /// Makes the goal a session grew into: the goal, the session on it, a done item per merged PR (linked to it) and a
    /// planned item per thing found. Returns the goal.
    @discardableResult
    func promote(_ promotion: GoalPromotion, kind: GoalLink.Kind = .session, now: Date) throws -> HeedGoal {
        let goal = try create(title: promotion.title, statement: promotion.statement, now: now)
        try attach(GoalLink(goal: goal.id, kind: kind, target: promotion.session, at: now))
        for part in promotion.done {
            let item = try addItem(
                goal: goal.id, title: part.title, source: .session,
                links: [GoalItem.Link(.session, promotion.session), GoalItem.Link(.pr, part.pull.description)],
                reason: "merged before the goal was made", now: now
            )
            try done(item: item.id, now: now)
        }
        for found in promotion.found {
            let item = try addItem(
                goal: goal.id, title: found, source: .session, reason: "found by the session, not started", now: now
            )
            try move(item: item.id, to: .planned, now: now)
        }
        return goal
    }
}
