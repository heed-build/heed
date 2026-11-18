import Foundation

/// What a Browse view is about: an organisation (or your own account), one repo, or a Project board.
public enum BrowseScope: Hashable, Sendable, Codable, Identifiable {
    case org(String)
    case repo(Repo)
    case project(owner: String, number: Int, title: String)
    /// A saved slice of an org with very many repos (`BrowseOrgView`).
    case view(BrowseOrgView)

    public var id: String {
        switch self {
        case let .org(org): "org:\(org.lowercased())"
        case let .repo(repo): "repo:\(repo.slug.lowercased())"
        case let .project(owner, number, _): "project:\(owner.lowercased())/\(number)"
        case let .view(view): "view:\(view.owner.lowercased())/\(view.name.lowercased())"
        }
    }

    /// The name the rail and the chip show.
    public var title: String {
        switch self {
        case let .org(org): org
        case let .repo(repo): repo.name
        case let .project(_, _, title): title
        case let .view(view): view.name
        }
    }

    /// The organisation it belongs to: a repo sits indented under its org in the rail.
    public var owner: String {
        switch self {
        case let .org(org): org
        case let .repo(repo): repo.org
        case let .project(owner, _, _): owner
        case let .view(view): view.owner
        }
    }

    /// The qualifier GitHub's search takes for it.
    public var qualifier: String {
        switch self {
        case let .org(org): "org:\(org)"
        case let .repo(repo): "repo:\(repo.slug)"
        case let .project(owner, number, _): "project:\(owner)/\(number)"
        case let .view(view): view.qualifier
        }
    }

    /// Whether an item belongs to it, as far as the item says (a Project is matched by its title).
    public func contains(_ item: BrowseItem) -> Bool {
        switch self {
        case let .org(org): item.repo.org.caseInsensitiveCompare(org) == .orderedSame
        case let .repo(repo): item.repo.slug.caseInsensitiveCompare(repo.slug) == .orderedSame
        case let .project(_, _, title): item.projects.contains { $0.caseInsensitiveCompare(title) == .orderedSame }
        case let .view(view): view.contains(item.repo)
        }
    }
}

/// What an org with very many repos should be offered: browsing every repo is slow and mostly noise.
public enum BrowseGuidance: Equatable, Sendable {
    case browse
    /// Start from a saved scope (a language, archived or not) rather than the whole org.
    case createOrgView(repos: Int)

    public static let defaultThreshold = 200

    public static func advice(repoCount: Int, threshold: Int = defaultThreshold) -> BrowseGuidance {
        threshold > 0 && repoCount > threshold ? .createOrgView(repos: repoCount) : .browse
    }
}

/// The fixed set of marks a saved query can carry. The meaning is in the shape, so the set stays small.
public enum BrowseGlyph: String, CaseIterable, Hashable, Sendable, Codable {
    case bolt, bug, sprout, clock, flag, star, pull, person, tag, list

    /// The glyph the query's dominant filter suggests: bugs, newcomer-friendly work, staleness, milestones, ideas,
    /// pull requests, what is yours; a plain list otherwise.
    public static func pick(for query: BrowseQuery) -> BrowseGlyph {
        let labels = query.tokens.flatMap { token -> [String] in
            if case let .label(mode, names) = token, mode != .none { return names.map { $0.lowercased() } }
            return []
        }
        func has(_ words: [String]) -> Bool { labels.contains { label in words.contains { label.contains($0) } } }
        if has(["bug", "regression", "crash"]) { return .bug }
        if has(["good first", "beginner", "starter", "help wanted"]) { return .sprout }
        if has(["idea", "enhancement", "feature", "proposal"]) { return .star }
        for token in query.tokens {
            switch token {
            case .activity(.olderThan), .created(.olderThan): return .clock
            case .milestone: return .flag
            case .assignee, .author: return .person
            case .heedReady: return .bolt
            case .type(.pulls): return .pull
            case .label: return .tag
            default: continue
            }
        }
        return .list
    }

    public var tint: BrowseTint {
        switch self {
        case .bolt: .amber
        case .bug: .red
        case .sprout: .green
        case .clock: .blue
        case .flag: .red
        case .star: .purple
        case .pull: .green
        case .person: .teal
        case .tag: .gray
        case .list: .gray
        }
    }
}

public enum BrowseTint: String, CaseIterable, Hashable, Sendable, Codable {
    case amber, red, green, blue, purple, teal, gray
}

/// A query you keep in the rail.
public struct SavedQuery: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var glyph: BrowseGlyph
    public var tint: BrowseTint
    public var query: BrowseQuery

    public init(id: String, name: String, glyph: BrowseGlyph? = nil, tint: BrowseTint? = nil, query: BrowseQuery) {
        self.id = id
        self.name = name
        let picked = glyph ?? BrowseGlyph.pick(for: query)
        self.glyph = picked
        self.tint = tint ?? picked.tint
        self.query = query
    }
}

public extension SavedQuery {
    /// What the rail starts with, until you keep your own: each with the glyph its filter picks.
    /// Open items heed read as ready for an agent: filtered on this Mac, over what GitHub answered.
    static let agentReady = SavedQuery(
        id: "agent-ready", name: "Agent-ready", glyph: .bolt,
        query: BrowseQuery(tokens: [.state(.open), .heedReady(BrowseRead.readyLine)])
    )

    static let starters: [SavedQuery] = [
        SavedQuery(
            id: "assigned", name: "Assigned to me", query: BrowseQuery(tokens: [.state(.open), .assignee("@me")])
        ),
        SavedQuery(
            id: "bugs-untouched", name: "Bugs nobody touched",
            query: BrowseQuery(tokens: [.state(.open), .label(.any, ["bug"]), .raw("no:assignee")])
        ),
        SavedQuery(
            id: "good-first", name: "Good first issues",
            query: BrowseQuery(tokens: [.state(.open), .label(.any, ["good first issue"])])
        ),
        SavedQuery(
            id: "stale", name: "Stale 30d+",
            query: BrowseQuery(tokens: [.state(.open), .activity(.olderThan(30))])
        ),
    ]
}
