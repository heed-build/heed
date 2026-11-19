import Foundation

/// The quick jump (⌘K): type to find a saved query, an org or account, or a repo, and go there, or search GitHub for
/// what was typed. Orgs show how many repos they have
/// and, when that is too many to browse at once, say so and offer a view of their own first. Repos show whether they
/// are cloned here. No IO: the app fills the lists and the counts, and acts on what `handle` returns.
public struct BrowsePalette: Sendable {
    public struct Org: Hashable, Sendable {
        public var name: String
        public var repoCount: Int?
        public var openCount: Int?
        /// Your own account rather than an org.
        public var personal: Bool
        /// Whether a repo of it is checked out. An org that is not is dimmed, shown only when typed, and picking it
        /// says
        /// to clone first instead of searching it.
        public var checkedOut: Bool

        public init(
            name: String, repoCount: Int? = nil, openCount: Int? = nil, personal: Bool = false, checkedOut: Bool = true
        ) {
            self.name = name
            self.repoCount = repoCount
            self.openCount = openCount
            self.personal = personal
            self.checkedOut = checkedOut
        }
    }

    public struct RepoRow: Hashable, Sendable {
        public var listing: RepoListing
        public var place: RepoPlace
        public var openCount: Int?
    }

    public struct QueryRow: Hashable, Sendable {
        public var query: SavedQuery
        public var count: Int?

        public init(query: SavedQuery, count: Int? = nil) {
            self.query = query
            self.count = count
        }
    }

    public enum Row: Hashable, Sendable {
        case query(QueryRow)
        case org(Org)
        case repo(RepoRow)
        /// "Search GitHub for “…”": the text goes to the add-filter flow.
        case search(String)
    }

    public enum Action: Equatable, Sendable {
        case none, changed, cancel
        /// Go to this scope.
        case choose(BrowseScope)
        /// Start an org view for a big org: the scope is the whole org until the user narrows it.
        case createOrgView(String)
        /// Run this saved query.
        case run(SavedQuery)
        /// Hand the text to the words-to-tokens flow (a plain text search when the model is off).
        case searchGitHub(String)
    }

    public var input = EditableText()
    public var orgs: [Org]
    public var listings: [RepoListing]
    public var records: [RepoRecord]
    public var openCounts: [String: Int]
    public var threshold: Int
    /// The saved queries, newest used first (`byRecency`), and what each counts.
    public var queries: [QueryRow]
    public private(set) var cursor = 0

    /// The most repos listed for what was typed.
    public static let repoLimit = 6

    public init(
        orgs: [Org], listings: [RepoListing], records: [RepoRecord] = [], openCounts: [String: Int] = [:],
        threshold: Int = BrowseGuidance.defaultThreshold, queries: [QueryRow] = []
    ) {
        self.queries = queries
        self.orgs = orgs
        self.listings = listings
        self.records = records
        self.openCounts = openCounts
        self.threshold = threshold
    }

    public var query: String { input.text.trimmingCharacters(in: .whitespaces) }

    /// The saved queries first, newest used first, so the ones you reach for are under the cursor's first moves.
    public static func byRecency(_ queries: [SavedQuery], used: [String: Date]) -> [SavedQuery] {
        queries.enumerated().sorted { lhs, rhs in
            let (a, b) = (used[lhs.element.id], used[rhs.element.id])
            if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The saved queries matching what was typed (all of them when nothing was), then the orgs you have checked out,
    /// then up to six repos matching it, once something is typed, then the orgs you have not (dimmed); and when
    /// nothing matches, the row that searches GitHub.
    public var rows: [Row] {
        let words = query.lowercased()
        // Orgs with a checkout always; the others only once something typed matches them, after the repos.
        let matches = orgs.filter { org in words.isEmpty ? org.checkedOut : org.name.lowercased().contains(words) }
        var rows = queries.filter { words.isEmpty || $0.query.name.lowercased().contains(words) }.map { Row.query($0) }
        rows += matches.filter(\.checkedOut).map { Row.org($0) }
        if !words.isEmpty {
            let repos = listings.filter { $0.repo.slug.lowercased().contains(words) }.prefix(Self.repoLimit)
            rows += repos.map { listing in
                Row.repo(RepoRow(
                    listing: listing, place: RepoPlace.of(listing.repo, in: records),
                    openCount: openCounts[listing.repo.slug.lowercased()]
                ))
            }
        }
        rows += matches.filter { !$0.checkedOut }.map { Row.org($0) }
        if rows.isEmpty, !words.isEmpty { rows.append(.search(query)) }
        return rows
    }

    /// What the highlighted org's repo count says to do: nil for a repo row.
    public var guidance: BrowseGuidance? {
        guard case let .org(org)? = rows[safe: cursor], org.checkedOut else { return nil }
        return org.repoCount.map { BrowseGuidance.advice(repoCount: $0, threshold: threshold) }
    }

    /// Learns how many repos an org has, once GitHub says.
    public mutating func setRepoCount(_ count: Int, of owner: String) {
        for index in orgs.indices where orgs[index].name.lowercased() == owner.lowercased() {
            orgs[index].repoCount = count
        }
    }

    public mutating func handle(_ stroke: KeyStroke) -> Action {
        let count = rows.count
        switch stroke {
        case .escape: return .cancel
        case KeyStroke("CR"):
            guard let row = rows[safe: cursor] else { return .none }
            switch row {
            case let .query(row): return .run(row.query)
            case let .search(text): return .searchGitHub(text)
            case let .org(org):
                if !org.checkedOut { return .choose(.org(org.name)) }
                if case .createOrgView = guidance { return .createOrgView(org.name) }
                return .choose(.org(org.name))
            case let .repo(repo): return .choose(.repo(repo.listing.repo))
            }
        case KeyStroke("CR", .command):
            // Search GitHub for the words even when something matched them.
            return query.isEmpty ? .none : .searchGitHub(query)
        case KeyStroke("b", .control) where cursor < count:
            // Browse a big org whole, anyway.
            if case let .org(org)? = rows[safe: cursor] { return .choose(.org(org.name)) }
            return .none
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"), KeyStroke("Tab"):
            cursor = count == 0 ? 0 : (cursor + 1) % count
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"), KeyStroke("Tab", .shift):
            cursor = count == 0 ? 0 : (cursor + count - 1) % count
        default:
            let before = input.text
            guard input.handle(stroke) else { return .none }
            if input.text != before { cursor = 0 }
            return .changed
        }
        return .none
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
