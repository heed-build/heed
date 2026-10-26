import Foundation

/// Why something is in Attention. One thread can have several (a review request that also mentions you and whose CI
/// failed is one item with three).
public enum AttentionReason: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// You were @-mentioned.
    case mentioned
    /// A team you are on was @-mentioned.
    case teamMention
    case reviewRequested
    case assigned
    /// A thread you opened (GitHub's `author` reason).
    case author
    case comment
    case stateChange
    /// A check run failed: a CI notification, or your PR's checks.
    case ciFailed
    case changesRequested
    /// Your PR has review threads nobody resolved.
    case unresolvedThreads
    /// Your PR meets every merge requirement and get it merged is off for it: merge it now, or set merging up.
    case readyToMerge
    case agentBlocked
    case agentAsking
    case agentLimited
    /// A goal's GOAL.md has scope edits waiting for you (one item per goal, however many).
    case goalProposals
    /// heed is unsure which goal a new session or chat belongs to and asks, one key (y n m i).
    case goalAttach
    /// heed marked a goal done: every criterion has evidence and every required lens is at its bar (undo is a key).
    case goalDone
    /// A goal's reviewers are due but its day's reviewer budget is spent: run them anyway, or wait for tomorrow.
    case goalBudget
    /// A goal's reviewers have nowhere to run: the work is in a repo with no clone on this Mac.
    case goalReviewBlocked
    /// An agent asked to spawn work on a goal's items past the goal's cap (`heed goal item spawn`): y starts it.
    case goalSpawn
    /// A goal needs an expert nobody has looked as yet, and heed did not spawn one on its own: P shows who.
    case goalPersonaGap
    /// A colleague closed or reopened a goal's sub-issue on GitHub against what heed has: does the item follow?
    case goalMirror
    /// One of your open PRs (or one a session tracks), whether or not anything about it wants you: My PRs lists it.
    case yourPR
    /// An open issue in a repo whose issues you watch (`[repos.x] issues = "all"`): the Issues filter lists it.
    case watching
    case subscribed
    case other

    /// Reasons that alone do not put an item in the feed: they keep it listed under My PRs or Issues.
    public var passive: Bool { self == .yourPR || self == .watching }

    /// A few words: `tagged you`, `review requested`, `agent blocked`, ...
    public var text: String {
        switch self {
        case .mentioned: "tagged you"
        case .teamMention: "team mention"
        case .reviewRequested: "review requested"
        case .assigned: "assigned"
        case .author: "your thread"
        case .comment: "comments"
        case .stateChange: "state changed"
        case .ciFailed: "CI failed"
        case .changesRequested: "changes requested"
        case .unresolvedThreads: "unresolved threads"
        case .readyToMerge: "ready to merge"
        case .agentBlocked: "agent blocked"
        case .agentAsking: "agent asking"
        case .agentLimited: "rate limited"
        case .goalProposals: "goal proposals"
        case .goalAttach: "which goal?"
        case .goalDone: "goal done"
        case .goalBudget: "reviewers wait"
        case .goalReviewBlocked: "reviewers blocked"
        case .goalSpawn: "spawns wait"
        case .goalPersonaGap: "persona gap"
        case .goalMirror: "from GitHub"
        case .yourPR: "your PR"
        case .watching: "watching"
        case .subscribed: "subscribed"
        case .other: "activity"
        }
    }

    /// GitHub's notification reason, as heed names it.
    public init(notification reason: String) {
        self = switch reason {
        case "mention": .mentioned
        case "team_mention": .teamMention
        case "review_requested": .reviewRequested
        case "assign": .assigned
        case "author": .author
        case "comment": .comment
        case "state_change": .stateChange
        case "ci_activity": .ciFailed
        case "subscribed", "manual": .subscribed
        default: .other
        }
    }

    public static func < (lhs: AttentionReason, rhs: AttentionReason) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One thing in Attention: a GitHub thread (issue, PR, CI run, release, discussion) or an agent, with every reason it
/// is there. Identified by its thread, so the notification, the issue search and the PR search about the same thread
/// make one item.
public struct AttentionItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case pr, issue, ci, release, discussion, agent, goal, other
    }

    /// A GitHub thread, rather than one of heed's own (an agent, a goal).
    public var onGitHub: Bool { kind != .agent && kind != .goal }

    /// `org/name#12` for an issue or PR (lowercased), `agent:<session>`, or `<kind>:<notification id>`.
    public var id: String
    public var kind: Kind
    public var repo: Repo?
    public var number: Int?
    public var title: String
    public var url: String?
    public var reasons: Set<AttentionReason>
    /// Your teams it came through (`org/slug`), from team attribution.
    public var teams: Set<String>
    public var updatedAt: Date
    /// The notification thread, for done (mark read) and mute (unsubscribe); nil when no notification is about it.
    public var notificationID: String?
    public var unread: Bool
    public var author: String?
    public var authorIsBot: Bool
    public var labels: [String]
    public var isDraft: Bool?
    /// Lines added plus removed, for a PR whose size is known.
    public var size: Int?
    /// The branch a CI failure is on (a CI run's, or your PR's head).
    public var branch: String?
    /// For an agent: its state; and the session (an agent's own, or one that tracks this PR or issue).
    public var agentState: AgentState?
    public var session: String?
    /// Who spoke last in the thread, when known: whose turn it is.
    public var lastCommenter: String?

    public init(
        id: String, kind: Kind, repo: Repo?, number: Int?, title: String, url: String?,
        reasons: Set<AttentionReason>, teams: Set<String> = [], updatedAt: Date, notificationID: String? = nil,
        unread: Bool = false, author: String? = nil, authorIsBot: Bool = false, labels: [String] = [],
        isDraft: Bool? = nil, size: Int? = nil, branch: String? = nil, agentState: AgentState? = nil,
        session: String? = nil, lastCommenter: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.reasons = reasons
        self.teams = teams
        self.updatedAt = updatedAt
        self.notificationID = notificationID
        self.unread = unread
        self.author = author
        self.authorIsBot = authorIsBot
        self.labels = labels
        self.isDraft = isDraft
        self.size = size
        self.branch = branch
        self.agentState = agentState
        self.session = session
        self.lastCommenter = lastCommenter
    }

    /// The id of an issue or PR thread: one per number in a repo (issues and PRs share numbers).
    public static func threadID(_ repo: Repo, _ number: Int) -> String { "\(repo.slug)#\(number)".lowercased() }

    /// Whether anything about it wants you; an item with only passive reasons is listed under My PRs or Issues only.
    public var wantsYou: Bool { reasons.contains { !$0.passive } }

    /// Its reasons, most telling first.
    public var orderedReasons: [AttentionReason] { reasons.sorted() }

    /// What the detail says when there is no summary: about an agent or one of heed's goal items, by its reason.
    public var placeholderSummary: String {
        switch kind {
        case .agent: "An agent waiting on you."
        case .goal where reasons.contains(.goalAttach): "heed is unsure which goal this belongs to."
        case .goal where reasons.contains(.goalDone):
            "heed marked the goal done: every criterion has evidence and every lens is at its bar. :goal.reopen undoes it."
        case .goal where reasons.contains(.goalBudget):
            "Reviewers were due but the goal's reviewer runs for today are spent: ↩ shows them, r runs them anyway."
        case .goal where reasons.contains(.goalSpawn):
            "An agent asked heed to start work on the goal's items, past the goal's spawn cap: y starts it, n drops it."
        case .goal where reasons.contains(.goalReviewBlocked):
            "The goal's reviewers have nowhere to run: its repo is not cloned on this Mac."
        case .goal where reasons.contains(.goalPersonaGap):
            "The goal needs an expert nobody has looked as yet: ↩ shows who and why, S, C or N puts one to work."
        case .goal where reasons.contains(.goalMirror):
            "A colleague changed one of the goal's sub-issues on GitHub: y follows it, n puts it back as heed has it."
        case .goal: "Changes to the goal's GOAL.md the work suggests: ↩ shows them."
        default: "No summary yet."
        }
    }

    /// `acme/docs#12`, `acme/docs`, or the agent's title.
    public var place: String {
        guard let repo else { return "" }
        return number.map { "\(repo.slug)#\($0)" } ?? repo.slug
    }
}

/// What heed knows about a thread beyond the notification, fetched once per update (`GitHub.threadDetails`): who
/// opened it, labels, draft, size, and the last few comments (the three-line digest, and whose turn it is).
public struct ThreadDetail: Hashable, Sendable, Codable {
    public struct Comment: Hashable, Sendable, Codable {
        public var author: String
        public var text: String
        public var at: Date

        public init(author: String, text: String, at: Date) {
            self.author = author
            self.text = text
            self.at = at
        }
    }

    public var url: String
    public var author: String?
    public var authorIsBot: Bool
    public var labels: [String]
    public var isDraft: Bool?
    public var size: Int?
    public var headBranch: String?
    /// The first part of the body.
    public var body: String
    /// The last comments and reviews, oldest first.
    public var comments: [Comment]
    /// The thread's `updatedAt` this was fetched for: newer activity fetches it again.
    public var updatedAt: Date

    public init(
        url: String, author: String? = nil, authorIsBot: Bool = false, labels: [String] = [], isDraft: Bool? = nil,
        size: Int? = nil, headBranch: String? = nil, body: String = "", comments: [Comment] = [], updatedAt: Date
    ) {
        self.url = url
        self.author = author
        self.authorIsBot = authorIsBot
        self.labels = labels
        self.isDraft = isDraft
        self.size = size
        self.headBranch = headBranch
        self.body = body
        self.comments = comments
        self.updatedAt = updatedAt
    }

    /// Who spoke last: the last comment's author, else whoever opened it.
    public var lastCommenter: String? { comments.last?.author ?? author }

    /// Three lines, newest last: `who: what`, one line each.
    public var digest: [String] {
        comments.suffix(3).map { comment in
            let line = comment.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "\(comment.author): \(line.count > 120 ? String(line.prefix(119)) + "…" : line)"
        }
    }
}

/// What you did to an item, kept locally: done until it changes again, snoozed until a time, muted for good.
public struct AttentionMark: Hashable, Sendable, Codable {
    public var doneAt: Date?
    public var snoozedUntil: Date?
    public var mutedAt: Date?

    public init(doneAt: Date? = nil, snoozedUntil: Date? = nil, mutedAt: Date? = nil) {
        self.doneAt = doneAt
        self.snoozedUntil = snoozedUntil
        self.mutedAt = mutedAt
    }

    /// Whether it keeps `item` out of the feed at `now`: muted; snoozed and not yet due; done and nothing since.
    public func hides(_ item: AttentionItem, now: Date) -> Bool {
        if mutedAt != nil { return true }
        if let snoozedUntil, snoozedUntil > now { return true }
        if let doneAt, item.updatedAt <= doneAt { return true }
        return false
    }
}
