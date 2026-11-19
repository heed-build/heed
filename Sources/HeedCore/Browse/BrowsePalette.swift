import Foundation

/// The quick jump (⌘K): type to find an org or account, or a repo, and go there. Orgs show how many repos they have
/// and, when that is too many to browse at once, say so and offer a view of their own first. Repos show whether they
/// are cloned here. No IO: the app fills the lists and the counts, and acts on what `handle` returns.
public struct BrowsePalette: Sendable {
    public struct Org: Hashable, Sendable {
        public var name: String
        public var repoCount: Int?
        public var openCount: Int?
        /// Your own account rather than an org.
        public var personal: Bool

        public init(name: String, repoCount: Int? = nil, openCount: Int? = nil, personal: Bool = false) {
            self.name = name
            self.repoCount = repoCount
            self.openCount = openCount
            self.personal = personal
        }
    }

    public struct RepoRow: Hashable, Sendable {
        public var listing: RepoListing
        public var place: RepoPlace
        public var openCount: Int?
    }

    public enum Row: Hashable, Sendable {
        case org(Org)
        case repo(RepoRow)
    }

    public enum Action: Equatable, Sendable {
        case none, changed, cancel
        /// Go to this scope.
        case choose(BrowseScope)
        /// Start an org view for a big org: the scope is the whole org until the user narrows it.
        case createOrgView(String)
    }

    public var input = EditableText()
    public var orgs: [Org]
    public var listings: [RepoListing]
    public var records: [RepoRecord]
    public var openCounts: [String: Int]
    public var threshold: Int
    public private(set) var cursor = 0

    /// The most repos listed for what was typed.
    public static let repoLimit = 6

    public init(
        orgs: [Org], listings: [RepoListing], records: [RepoRecord] = [], openCounts: [String: Int] = [:],
        threshold: Int = BrowseGuidance.defaultThreshold
    ) {
        self.orgs = orgs
        self.listings = listings
        self.records = records
        self.openCounts = openCounts
        self.threshold = threshold
    }

    public var query: String { input.text.trimmingCharacters(in: .whitespaces) }

    /// The orgs matching what was typed (all of them when nothing was), then up to six repos matching it, once
    /// something is typed.
    public var rows: [Row] {
        let words = query.lowercased()
        let matchedOrgs = orgs.filter { words.isEmpty || $0.name.lowercased().contains(words) }
        var rows = matchedOrgs.map { Row.org($0) }
        if !words.isEmpty {
            let repos = listings.filter { $0.repo.slug.lowercased().contains(words) }.prefix(Self.repoLimit)
            rows += repos.map { listing in
                Row.repo(RepoRow(
                    listing: listing, place: RepoPlace.of(listing.repo, in: records),
                    openCount: openCounts[listing.repo.slug.lowercased()]
                ))
            }
        }
        return rows
    }

    /// What the highlighted org's repo count says to do: nil for a repo row.
    public var guidance: BrowseGuidance? {
        guard case let .org(org)? = rows[safe: cursor] else { return nil }
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
            case let .org(org):
                if case .createOrgView = guidance { return .createOrgView(org.name) }
                return .choose(.org(org.name))
            case let .repo(repo): return .choose(.repo(repo.listing.repo))
            }
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
