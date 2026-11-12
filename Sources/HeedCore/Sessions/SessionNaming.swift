import Foundation

/// Who gave a session its title: the prompt's first words (until heed names it), heed, or you. Yours is never
/// replaced; heed's follows the work.
public enum TitleSource: String, Codable, Hashable, Sendable {
    case prompt, heed, you
}

/// Something that names a session from its question: Apple's on-device model in the app, a fake in tests.
public protocol SessionNamer: Sendable {
    func name(_ question: SessionNaming.Question) async throws -> SessionNaming.Answer?
}

/// Heed names sessions as the work goes, so the sidebar reads as what each one is doing rather than how its prompt
/// started: once after the agent's first turn, again when a PR opens, again when the ledger writes the work down. A
/// title you gave it stays (`session.rename`), and heed renames a session at most `perSession` times.
public enum SessionNaming {
    /// Why heed names a session now.
    public enum Moment: String, Hashable, Sendable {
        /// Its agent finished its first turn: there is more to go on than the prompt.
        case firstTurn
        /// It opened a PR: the PR's title says what the work became.
        case pullOpened
        /// You asked (`session.rename` with no title gives the title back to heed).
        case asked
    }

    /// Heed renames a session this often at most, so a title settles.
    public static let perSession = 6
    /// Model calls for names a day, across sessions (on-device names do not count).
    public static let dailyCalls = 40
    /// Longest title kept; longer ones are cut at a word.
    public static let maxLength = 60

    /// What a name is asked from: the session's prompt and what it did, its PRs, and the other sessions' titles so the
    /// name says what sets this one apart.
    public struct Question: Hashable, Sendable {
        public var prompt: String
        public var title: String
        public var repo: String?
        public var branch: String?
        public var lastMessage: String?
        public var pullTitles: [String]
        public var others: [String]

        public init(
            prompt: String, title: String, repo: String? = nil, branch: String? = nil, lastMessage: String? = nil,
            pullTitles: [String] = [], others: [String] = []
        ) {
            self.prompt = prompt
            self.title = title
            self.repo = repo
            self.branch = branch
            self.lastMessage = lastMessage
            self.pullTitles = pullTitles
            self.others = others
        }

        public static func of(_ session: Session, pullTitles: [String], others: [Session]) -> Question {
            Question(
                prompt: session.prompt, title: session.title, repo: session.repos.first?.slug,
                branch: session.branch.isEmpty ? nil : session.branch, lastMessage: session.lastMessage,
                pullTitles: pullTitles, others: others.filter { $0.id != session.id }.map(\.title)
            )
        }

        /// The question as a summary's inputs, for a model call.
        public var inputs: SummaryInputs {
            SummaryInputs(
                title: title, repo: repo, branch: branch,
                pullRequest: pullTitles.isEmpty ? nil : pullTitles.map { "PR: \($0)" }.joined(separator: "\n"),
                timeline: ["Prompt: \(prompt.prefix(1200))"], lastMessage: lastMessage.map { String($0.suffix(1500)) },
                known: others
            )
        }
    }

    public struct Answer: Hashable, Sendable {
        public var title: String
        public var kind: WorkKind?

        public init(title: String, kind: WorkKind? = nil) {
            self.title = title
            self.kind = kind
        }
    }

    /// The moments heed should name a session at, from one commit's change to the sessions.
    public static func moments(before: [Session], after: [Session]) -> [(id: String, moment: Moment)] {
        let earlier = Dictionary(before.map { ($0.id, $0) }) { first, _ in first }
        return after.compactMap { session in
            guard let previous = earlier[session.id], mayName(session) else { return nil }
            if previous.lastMessage == nil, session.lastMessage != nil { return (session.id, .firstTurn) }
            let opened = session.trackedPRs.contains { !previous.trackedPRs.contains($0) }
            if opened { return (session.id, .pullOpened) }
            return nil
        }
    }

    /// Whether heed may name it: not one you named, and not past its renames.
    public static func mayName(_ session: Session) -> Bool {
        session.titleBy != .you && session.namings < perSession
    }

    /// The answer read from a model's reply: a `title:` line, and a `kind:` line when it gave one. A reply that is just
    /// a line of text is the title.
    public static func parse(_ text: String) -> Answer? {
        var title: String?
        var kind: WorkKind?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("title:") {
                title = String(trimmed.dropFirst(6))
            } else if lower.hasPrefix("kind:") {
                kind = WorkKind(rawValue: trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        if title == nil, let only = text.split(whereSeparator: \.isNewline).first, !only.contains(":") {
            title = String(only)
        }
        return title.flatMap(clean).map { Answer(title: $0, kind: kind) }
    }

    /// A title as the sidebar shows it: one line, no quotes or trailing period, a capital first letter, at most
    /// `maxLength` characters cut at a word. Nil when nothing is left.
    public static func clean(_ raw: String) -> String? {
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`*#")))
        while title.hasSuffix(".") {
            title.removeLast()
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if title.count > maxLength {
            let cut = title.prefix(maxLength)
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        guard let first = title.first else { return nil }
        return first.uppercased() + title.dropFirst()
    }

    /// Puts heed's name on the session: recorded in its timeline, shown as new until you have seen it, and its kind
    /// when it had none. False when it changes nothing (the same title, or one you named meanwhile).
    @discardableResult
    public static func apply(_ answer: Answer, to session: inout Session, now: Date = Clock.now) -> Bool {
        guard session.titleBy != .you else { return false }
        if session.kind == nil, !session.isChat, let kind = answer.kind { session.kind = kind }
        guard answer.title != session.title else { return false }
        session.record("renamed: \(session.title) → \(answer.title)", at: now)
        session.title = answer.title
        session.titleBy = .heed
        session.titleSeen = false
        session.namings += 1
        return true
    }

    /// `session.rename <title>`: your title, which heed then leaves alone; an empty one gives the title back to heed.
    public static func rename(_ session: inout Session, to title: String, now: Date = Clock.now) {
        guard let title = clean(title) else {
            session.titleBy = .prompt
            session.namings = min(session.namings, perSession - 1)
            return
        }
        if title != session.title { session.record("renamed: \(session.title) → \(title)", at: now) }
        session.title = title
        session.titleBy = .you
        session.titleSeen = true
    }
}
