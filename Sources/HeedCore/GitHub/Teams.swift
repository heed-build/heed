import Foundation

/// A GitHub team you are on. `parent` is the slug of the team it is nested in (same org), when it is.
public struct GitHubTeam: Hashable, Sendable, Codable {
    public var org: String
    public var slug: String
    public var parent: String?

    public init(org: String, slug: String, parent: String? = nil) {
        self.org = org
        self.slug = slug
        self.parent = parent
    }

    /// `org/slug`, lowercased: how a mention names it, and how rules and items refer to it.
    public var id: String { "\(org)/\(slug)".lowercased() }
}

/// The teams you are on, as `gh api user/teams` lists them (needs gh's `read:org` scope). Refreshed daily and on a
/// forced sync; without the scope there are none, and `note` says how to get them.
public struct ViewerTeams: Hashable, Sendable, Codable {
    public var teams: [GitHubTeam]
    public var fetchedAt: Date?
    /// Why teams cannot be attributed, when they cannot.
    public var note: String?

    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let missingScopeNote =
        "Team mentions are not attributed: gh needs the read:org scope (gh auth refresh -s read:org)"

    public init(teams: [GitHubTeam] = [], fetchedAt: Date? = nil, note: String? = nil) {
        self.teams = teams
        self.fetchedAt = fetchedAt
        self.note = note
    }

    /// Whether attribution can run: the teams were fetched, with the scope it needs.
    public var available: Bool { fetchedAt != nil && note == nil }

    public func isStale(now: Date) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
    }

    /// Your teams and the teams they are nested in: a mention of a parent team reaches its child teams' members.
    /// A parent you are listed on brings its own parent in turn.
    public var effective: [GitHubTeam] {
        var byID: [String: GitHubTeam] = [:]
        for team in teams {
            byID[team.id] = team
        }
        for team in teams {
            guard let slug = team.parent else { continue }
            let parent = GitHubTeam(org: team.org, slug: slug)
            byID[parent.id] = byID[parent.id] ?? parent
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The effective teams in `org` (case-insensitive).
    public func teams(in org: String) -> [GitHubTeam] {
        effective.filter { $0.org.lowercased() == org.lowercased() }
    }
}

/// Which of your teams one notification thread came through, and how heed found out.
public struct TeamAttribution: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// GitHub search for `team:org/slug` in the thread's repo returned the thread.
        case search
        /// The thread's body or comments mention the team (search found nothing).
        case text
        /// The PR's requested reviewers name the team.
        case reviewers
        /// Neither worked: `team:?` in a rule.
        case unknown
    }

    /// The notification reason this was worked out for; a new reason works it out again.
    public var reason: String
    public var teams: Set<String>
    /// Nil while it has not been worked out (a call failed; tried again next sync).
    public var source: Source?
    public var attempts: Int
    /// Last time the thread was in a sync's notifications; entries not seen for 30 days are dropped.
    public var seenAt: Date

    public init(reason: String, teams: Set<String>, source: Source?, attempts: Int = 0, seenAt: Date) {
        self.reason = reason
        self.teams = teams
        self.source = source
        self.attempts = attempts
        self.seenAt = seenAt
    }
}

/// Team attribution by notification thread id. A thread's reason is sticky (why you are subscribed, not what
/// happened last), so an attribution holds across updates and is only worked out again when the reason changes:
/// steady state is no extra call per sync.
public struct TeamMentionCache: Hashable, Sendable, Codable {
    public var entries: [String: TeamAttribution]

    /// Reasons that come through a team.
    public static let reasons: Set<String> = ["team_mention", "review_requested"]
    /// Failed tries before a thread is settled as unknown.
    public static let maxAttempts = 3
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public init(entries: [String: TeamAttribution] = [:]) {
        self.entries = entries
    }

    /// Whether `item` still needs working out.
    public func needs(_ item: InboxItem) -> Bool {
        guard Self.reasons.contains(item.reason) else { return false }
        guard let entry = entries[item.id], entry.reason == item.reason else { return true }
        return entry.source == nil
    }

    /// The teams `item` came through, as far as known for its current reason.
    public func teams(for item: InboxItem) -> Set<String> {
        guard let entry = entries[item.id], entry.reason == item.reason else { return [] }
        return entry.teams
    }

    public mutating func record(_ item: InboxItem, teams: Set<String>, source: TeamAttribution.Source, now: Date) {
        entries[item.id] = TeamAttribution(reason: item.reason, teams: teams, source: source, seenAt: now)
    }

    /// A call needed for `item` failed: tried again next sync, settled as unknown after `maxAttempts`.
    public mutating func failed(_ item: InboxItem, now: Date) {
        let previous = entries[item.id].flatMap { $0.reason == item.reason ? $0.attempts : nil } ?? 0
        let attempts = previous + 1
        entries[item.id] = TeamAttribution(
            reason: item.reason, teams: [], source: attempts >= Self.maxAttempts ? .unknown : nil,
            attempts: attempts, seenAt: now
        )
    }

    /// Marks the threads in `inbox` seen, and drops entries not seen for `retention`.
    public mutating func seen(_ inbox: [InboxItem], now: Date) {
        for item in inbox {
            entries[item.id]?.seenAt = now
        }
        entries = entries.filter { now.timeIntervalSince($0.value.seenAt) < Self.retention }
    }

    /// `inbox` with each item's teams filled in from the cache.
    public func applied(to inbox: [InboxItem]) -> [InboxItem] {
        inbox.map { item in
            var item = item
            item.teams = teams(for: item)
            return item
        }
    }
}

public enum TeamMentions {
    /// The `@org/team` mentions in `text`, lowercased `org/slug`. Code (fenced blocks and inline spans) is skipped, as
    /// GitHub does not notify for a mention there; so are e-mail-like and path-like matches (`a@b/c`, `/@x/y`).
    public static func parse(_ text: String) -> Set<String> {
        let prose = text
            .replacing(/```[\s\S]*?(```|$)/, with: " ")
            .replacing(/`[^`\n]*`/, with: " ")
        var found: Set<String> = []
        for match in prose.matches(of: /(?:^|[^\w\/@.-])@([A-Za-z0-9][A-Za-z0-9-]*)\/([A-Za-z0-9][A-Za-z0-9_-]*)/) {
            found.insert("\(match.output.1)/\(match.output.2)".lowercased())
        }
        return found
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: Swift.max(size, 1)).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
