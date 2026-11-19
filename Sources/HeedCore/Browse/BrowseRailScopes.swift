import Foundation

/// The rail's Scopes section: the orgs you have checked out (most checked-out repos first), the scopes you pinned, and
/// under an org its repos. Display only: nothing is fetched until a row is picked.
public enum BrowseRailScopes {
    /// The orgs shown before "+ N more".
    public static let defaultCap = 6

    public struct Row: Equatable, Sendable, Identifiable {
        public var scope: BrowseScope
        /// A repo sits indented under its org.
        public var indent: Bool
        /// How many repos are checked out under an org.
        public var checkedOut: Int?
        public var id: String { scope.id }
    }

    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        /// Orgs left out by the cap: the rail says "+ N more: ⌘K".
        public var more: Int
    }

    /// `pinned` always shows, in its order. The checked-out orgs not pinned follow, most repos first, until `cap` orgs
    /// are shown. An org shows its checked-out repos (and the repos you pinned) when it is pinned or is `current`; the
    /// others stay one row each, so a long rail never grows.
    public static func rows(
        pinned: [BrowseScope], checkouts: BrowseCheckouts, current: BrowseScope? = nil, cap: Int = defaultCap
    ) -> Result {
        var orgs: [String] = []
        func add(_ name: String) {
            if !orgs.contains(where: { $0.lowercased() == name.lowercased() }) { orgs.append(name) }
        }
        for case let .org(name) in pinned {
            add(name)
        }
        for case let .repo(repo) in pinned {
            add(repo.org)
        }
        let pinnedCount = orgs.count
        let seeded = checkouts.orgNames.filter { name in !orgs.contains { $0.lowercased() == name.lowercased() } }
        let room = max(0, cap - pinnedCount)
        for name in seeded.prefix(room) {
            add(name)
        }
        let more = max(0, seeded.count - room)

        var rows: [Row] = []
        var placed = Set<String>()
        for name in orgs {
            let org = checkouts.org(name)
            rows.append(Row(scope: .org(name), indent: false, checkedOut: org?.repos.count))
            placed.insert(BrowseScope.org(name).id)
            let pinnedHere = pinned.contains { scope in
                switch scope {
                case let .org(other): other.lowercased() == name.lowercased()
                case let .repo(repo): repo.org.lowercased() == name.lowercased()
                default: false
                }
            }
            let isCurrent = current?.owner.lowercased() == name.lowercased()
            guard pinnedHere || isCurrent else { continue }
            var repos = pinned.compactMap { scope -> Repo? in
                if case let .repo(repo) = scope, repo.org.lowercased() == name.lowercased() { repo } else { nil }
            }
            for repo in org?.repos ?? []
                where !repos.contains(where: { $0.slug.lowercased() == repo.slug.lowercased() })
            {
                repos.append(repo)
            }
            for repo in repos {
                rows.append(Row(scope: .repo(repo), indent: true, checkedOut: nil))
                placed.insert(BrowseScope.repo(repo).id)
            }
        }
        // Projects and org views keep their place after the orgs.
        for scope in pinned where !placed.contains(scope.id) {
            rows.append(Row(scope: scope, indent: false, checkedOut: nil))
        }
        return Result(rows: rows, more: more)
    }
}
