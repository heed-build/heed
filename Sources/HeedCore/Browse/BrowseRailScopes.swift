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
        /// An org row with checked-out repos has a chevron, and whether its repos are shown.
        public var expandable = false
        public var expanded = false
        public var id: String { scope.id }
        /// What the row says: "Only my 3 repos" for an org's own repos, the scope's name for any other.
        public var title: String {
            if case .ownRepos = scope { "Only " + BrowseScope.myRepos(checkedOut ?? 0) } else { scope.title }
        }
    }

    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        /// Orgs left out by the cap: the rail says "+ N more: ⌘K".
        public var more: Int
    }

    /// The key an org is expanded under.
    public static func key(_ org: String) -> String { org.lowercased() }

    /// `pinned` always shows, in its order. The checked-out orgs not pinned follow, most repos first, until `cap` orgs
    /// are shown. An org shows what is under it only when it is in `expanded` (keys from `key(_:)`): first "Only my N
    /// repos", then its checked-out repos (and the repos you pinned). The others stay one row each, so a long rail
    /// never grows. `current` is not shown open by itself: `BrowseRailExpansion` opens it once, and a collapse sticks.
    public static func rows(
        pinned: [BrowseScope], checkouts: BrowseCheckouts, expanded: Set<String> = [], cap: Int = defaultCap
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
        for case let .ownRepos(name) in pinned {
            add(name)
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
            let open = expanded.contains(key(name))
            let any = !(org?.repos.isEmpty ?? true)
            rows.append(Row(
                scope: .org(name), indent: false, checkedOut: org?.repos.count, expandable: any, expanded: open && any
            ))
            placed.insert(BrowseScope.org(name).id)
            // Never a row of its own at the end: it only ever sits first under its org.
            placed.insert(BrowseScope.ownRepos(name).id)
            // A pinned repo shows under its org when that is open, and nowhere else.
            for case let .repo(repo) in pinned where repo.org.lowercased() == name.lowercased() {
                placed.insert(BrowseScope.repo(repo).id)
            }
            guard open, let org, any else { continue }
            rows.append(Row(scope: .ownRepos(name), indent: true, checkedOut: org.repos.count))
            var repos = pinned.compactMap { scope -> Repo? in
                if case let .repo(repo) = scope, repo.org.lowercased() == name.lowercased() { repo } else { nil }
            }
            for repo in org.repos
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

    /// The rows without the repos that have nothing open (`count` says 0): a long org lists many that never have an
    /// item, and they only push the ones that do out of sight. The scope you are in stays, and so does a repo whose
    /// count is not known yet (never searched). `hidden` is how many were left out, for the "show" row.
    public static func hidingEmpty(
        _ rows: [Row], count: (BrowseScope) -> Int?, keeping current: BrowseScope? = nil
    ) -> (rows: [Row], hidden: Int) {
        var hidden = 0
        let kept = rows.filter { row in
            guard row.indent, case .repo = row.scope, count(row.scope) == 0, row.scope != current else { return true }
            hidden += 1
            return false
        }
        return (kept, hidden)
    }
}

/// Which orgs of the rail are open, and which have been opened for you once. Clicking the org that is not the scope
/// opens it and picks it; clicking the one that is the scope toggles it; the chevron only toggles. The org you pick
/// opens the first time it is picked, and a collapse after that sticks: it is not opened again.
public struct BrowseRailExpansion: Equatable, Sendable {
    /// `BrowseRailScopes.key` of each open org.
    public private(set) var open: Set<String>
    /// The orgs that were opened by being picked, once.
    public private(set) var seen: Set<String>

    public init(open: Set<String> = [], seen: Set<String> = []) {
        self.open = open
        self.seen = seen
    }

    public func isOpen(_ org: String) -> Bool { open.contains(BrowseRailScopes.key(org)) }

    /// The chevron, and the key: open it or close it, scope unchanged.
    public mutating func toggle(_ org: String) {
        let key = BrowseRailScopes.key(org)
        seen.insert(key)
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    /// A scope of `org` became the current one, by any way: opened once, when it was never opened for you.
    public mutating func picked(_ org: String) {
        let key = BrowseRailScopes.key(org)
        if seen.insert(key).inserted { open.insert(key) }
    }

    /// A click on the org's row: it is picked as the scope, and `wasScope` (the org row was already the scope) says
    /// whether the click closes it or opens it.
    public mutating func clicked(_ org: String, wasScope: Bool) {
        if wasScope { toggle(org) } else {
            let key = BrowseRailScopes.key(org)
            seen.insert(key)
            open.insert(key)
        }
    }
}
