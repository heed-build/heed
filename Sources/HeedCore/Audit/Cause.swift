import Foundation

/// Why heed did something: what started it (you and a key, an Autopilot rule, a helper button, a PR event, a
/// schedule), and the chain below it (the session or run that started, the agent's call in it). Made where heed starts
/// something, carried with the work (`Cause.current` inside heed, `HEED_CAUSE` in an agent's environment), and named
/// by every row Audit keeps.
public struct Cause: Codable, Hashable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        /// You: a key, a click, a command typed on the command line.
        case key
        /// An Autopilot rule decided (a merge when every rule held, a fix on red CI).
        case autopilot
        /// A helper's button or one of its own steps (push, close-out).
        case helper
        /// A PR event heed reacted to (a review arrived, checks went red).
        case pullEvent = "pr event"
        /// Something heed does on its own schedule (a sync, a standup).
        case schedule
        /// A session or run heed started, with the prompt it handed the agent.
        case session
        /// One of the agent's own tool calls, in that session or run.
        case agent

        /// In words, for the cause chain.
        public var label: String {
            switch self {
            case .key: "you"
            case .autopilot: "Autopilot"
            case .helper: "helper"
            case .pullEvent: "PR event"
            case .schedule: "schedule"
            case .session: "session"
            case .agent: "agent"
            }
        }
    }

    public var id: String
    public var at: Date
    public var trigger: Trigger
    /// What exactly: `gm · pr.merge`, `merge = "heed": every merge rule held`, `fix CI on #412`.
    public var detail: String
    /// The cause this one came from; nil for a trigger.
    public var parent: String?
    public var session: String?
    public var sessionTitle: String?
    public var agent: String?
    /// Whose text reached the prompt heed built for this session or run (`Prompt.authors`), or whose approvals and
    /// PR an Autopilot rule acted on.
    public var authors: [ExternalText.Author]

    public init(
        id: String = Cause.newID(), at: Date, trigger: Trigger, detail: String, parent: String? = nil,
        session: String? = nil, sessionTitle: String? = nil, agent: String? = nil,
        authors: [ExternalText.Author] = []
    ) {
        self.id = id
        self.at = at
        self.trigger = trigger
        self.detail = detail
        self.parent = parent
        self.session = session
        self.sessionTitle = sessionTitle
        self.agent = agent
        self.authors = authors
    }

    /// A cause that came from this one.
    public func child(
        _ trigger: Trigger, _ detail: String, at: Date, session: String? = nil, sessionTitle: String? = nil,
        agent: String? = nil, authors: [ExternalText.Author] = []
    ) -> Cause {
        Cause(
            at: at, trigger: trigger, detail: detail, parent: id, session: session ?? self.session,
            sessionTitle: sessionTitle ?? self.sessionTitle, agent: agent ?? self.agent, authors: authors
        )
    }

    /// The cause of the work in progress: set where heed starts something (`$current.withValue`), inherited by every
    /// task it starts, and read where an outward action is recorded.
    @TaskLocal public static var current: Cause?

    /// The variable an agent's panes carry, so its hooks can name the cause of what it does.
    public static let environment = "HEED_CAUSE"

    /// `c` and twelve hex digits.
    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        return "c" + String(format: "%012llx", UInt64.random(in: 0 ... 0xFFFF_FFFF_FFFF, using: &generator))
    }

    /// Whether `text` could be an id this type made: what `HEED_CAUSE` from a hook must look like to be read.
    public static func isID(_ text: String) -> Bool {
        text.count == 13 && text.first == "c" && text.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// The chain from the trigger down to `id`, trigger first. A parent heed no longer has ends it; a loop is cut.
    public static func chain(_ id: String?, in causes: [String: Cause]) -> [Cause] {
        var chain: [Cause] = []
        var seen: Set<String> = []
        var next = id
        while let current = next, !seen.contains(current), let cause = causes[current] {
            seen.insert(current)
            chain.insert(cause, at: 0)
            next = cause.parent
        }
        return chain
    }

    /// Every author along a chain, each once, the least trusted first.
    public static func authors(of chain: [Cause]) -> [ExternalText.Author] {
        var seen: Set<ExternalText.Author> = []
        var authors: [ExternalText.Author] = []
        for author in chain.flatMap(\.authors) where seen.insert(author).inserted {
            authors.append(author)
        }
        return authors.sorted { lhs, rhs in
            lhs.trust.rank != rhs.trust.rank ? lhs.trust.rank < rhs.trust.rank
                : (lhs.login ?? "") < (rhs.login ?? "")
        }
    }
}

public extension ExternalText.Trust {
    /// Least trusted first: stranger, bot, member, collaborator, owner.
    var rank: Int {
        switch self {
        case .stranger: 0
        case .bot: 1
        case .member: 2
        case .collaborator: 3
        case .owner: 4
        }
    }
}

public extension Prompt {
    /// Whose text is in it, each author once, in the order it appears: what Audit keeps of a prompt heed built.
    var authors: [ExternalText.Author] {
        var seen: Set<ExternalText.Author> = []
        return parts.compactMap { part in
            guard case let .external(text) = part, !text.isEmpty, seen.insert(text.author).inserted else { return nil }
            return text.author
        }
    }
}
