import Foundation

/// What heed does with a repo once it is added or cloned (`[worktrees] after_add`, and the Add or clone dialog's
/// "then"): open Repo setup (get it merged and get it green), open Start work on it, or nothing more.
public enum AfterAdd: String, CaseIterable, Sendable, Codable {
    case setup
    case startWork = "start_work"
    case add

    /// As the dialog's picker says it.
    public var label: String {
        switch self {
        case .setup: "set it up"
        case .startWork: "start work"
        case .add: "just add it"
        }
    }

    /// As Settings says it.
    public var title: String {
        switch self {
        case .setup: "Repo setup"
        case .startWork: "Start work"
        case .add: "Just add"
        }
    }

    /// The default, and what a value config.toml does not know reads as.
    public static let `default` = AfterAdd.setup
}

/// A repo as `gh repo list` reports it: the list the Add or clone dialog offers, newest push first.
public struct RepoListing: Hashable, Sendable, Codable {
    public var repo: Repo
    public var description: String
    public var pushedAt: Date?
    public var isPrivate: Bool
    public var isArchived: Bool

    public init(
        repo: Repo, description: String = "", pushedAt: Date? = nil, isPrivate: Bool = false, isArchived: Bool = false
    ) {
        self.repo = repo
        self.description = description
        self.pushedAt = pushedAt
        self.isPrivate = isPrivate
        self.isArchived = isArchived
    }

    /// When it was last pushed: `12 m ago`, `2 h ago` within a day, then `yesterday`, `Fri`, `3 weeks`.
    public func pushedText(now: Date) -> String {
        guard let pushedAt else { return "" }
        if now.timeIntervalSince(pushedAt) < 24 * 3600 { return RepoSummary.age(pushedAt, now: now) + " ago" }
        return RepoSummary.when(pushedAt, now: now)
    }

    /// `gh repo list [owner]`, read only: the fields the dialog shows. With no owner, the signed-in account's own.
    public static func listArguments(owner: String?, limit: Int = 200) -> [String] {
        ["repo", "list"] + (owner.map { [$0] } ?? []) + [
            "--limit", "\(limit)", "--json", "nameWithOwner,description,pushedAt,isPrivate,isArchived",
        ]
    }

    /// `gh repo list --json`'s output read back, newest push first; nil when it is not that.
    public static func parse(_ data: Data) -> [RepoListing]? {
        struct Raw: Decodable {
            let nameWithOwner: String
            let description: String?
            let pushedAt: String?
            let isPrivate: Bool?
            let isArchived: Bool?
        }
        guard let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return nil }
        let iso = ISO8601DateFormatter()
        return newestFirst(raws.compactMap { raw in
            let parts = raw.nameWithOwner.split(separator: "/").map(String.init)
            guard parts.count == 2 else { return nil }
            return RepoListing(
                repo: Repo(org: parts[0], name: parts[1]), description: raw.description ?? "",
                pushedAt: raw.pushedAt.flatMap { iso.date(from: $0) }, isPrivate: raw.isPrivate ?? false,
                isArchived: raw.isArchived ?? false
            )
        })
    }

    /// Newest push first, then by slug; one entry per repo.
    public static func newestFirst(_ listings: [RepoListing]) -> [RepoListing] {
        var seen: Set<String> = []
        return listings.sorted {
            let left = $0.pushedAt ?? .distantPast
            let right = $1.pushedAt ?? .distantPast
            return left == right ? $0.repo.slug.lowercased() < $1.repo.slug.lowercased() : left > right
        }
        .filter { seen.insert($0.repo.slug.lowercased()).inserted }
    }
}

/// Where a repo already is, as the dialog says it: checked out on this Mac, on a host only, or nowhere yet.
public enum RepoPlace: Hashable, Sendable {
    /// On this Mac, at its main checkout's path.
    case here(String)
    /// Only on these hosts.
    case hosts([String])
    case notCloned

    /// Where `repo` is among the repos heed knows (GitHub's names are case-insensitive).
    public static func of(_ repo: Repo, in records: [RepoRecord]) -> RepoPlace {
        let same = records.filter { $0.repo.slug.lowercased() == repo.slug.lowercased() }
        if let local = same.first(where: \.location.isLocal) { return .here(local.path) }
        let hosts = same.compactMap(\.location.hostName)
        return hosts.isEmpty ? .notCloned : .hosts(Array(Set(hosts)).sorted())
    }

    /// What the dialog's Here column says: `✓ ~/Projects/x`, `✓ @devbox only · clone here`, `clone`, `archived`.
    public func text(archived: Bool) -> String {
        switch self {
        case let .here(path): "✓ " + Paths.tilde(path)
        case let .hosts(hosts): "✓ " + hosts.map { "@\($0)" }.joined(separator: " ") + " only · clone here"
        case .notCloned: archived ? "archived" : "clone"
        }
    }

    /// Whether adding it means cloning it to this Mac.
    public var clones: Bool {
        if case .here = self { return false }
        return true
    }
}

/// The Add or clone dialog (`a` in Repos, `:repo.add`): one field for owner/name, a GitHub URL or a path; tabs with
/// your GitHub repos and each org's (`gh repo list`, newest push first) and a folder on this Mac; space picks several;
/// ⌘↩ clones what is not here into the chosen root, adds the rest, then does the chosen "then". No IO: the app fills
/// the lists, the lookups and the folder completions, and acts on what `handle` returns.
public struct AddRepoForm: Sendable {
    public enum Tab: Hashable, Sendable {
        /// Yours and every org's, together.
        case mine
        case org(String)
        case folder

        public var title: String {
            switch self {
            case .mine: "Your GitHub"
            case let .org(name): name
            case .folder: "A folder on this Mac"
            }
        }
    }

    /// A list as far as `gh repo list` answered.
    public enum ListState: Hashable, Sendable {
        case loading
        case loaded([RepoListing])
        case failed(String)
    }

    /// One row of a list tab.
    public struct Row: Hashable, Sendable {
        public var listing: RepoListing
        public var place: RepoPlace
        /// Typed into the field, not on any list: GitHub was asked for it (`gh repo view`).
        public var typed: Bool
    }

    /// What ⌘↩ does to one repo.
    public enum Target: Hashable, Sendable {
        /// Not on this Mac: `gh repo clone` into the root.
        case clone(Repo)
        /// Already here: nothing to fetch, only the "then".
        case known(Repo)
        /// A checkout at a path on this Mac: added in place.
        case path(String)
    }

    /// What a keystroke asks of the app.
    public enum Action: Equatable, Sendable {
        case none
        /// The field changed: look the entry up, complete the folder, as the tab needs.
        case changed
        case cancel
        case submit
    }

    public var input = EditableText()
    public var query: String { input.text }
    public private(set) var tabs: [Tab]
    public private(set) var tab = 0
    /// Lists by owner: "" for yours, else the org's login.
    public var lists: [String: ListState] = [:]
    public private(set) var cursor = 0
    /// Picked slugs, in the order picked.
    public private(set) var picked: [String] = []
    public var roots: [String]
    public var root: String
    public var then: AfterAdd
    /// The repos heed knows, wherever they are: what says where a listed repo already is.
    public var records: [RepoRecord]
    /// `gh repo view` answers for typed slugs, by `RepoEntry.Parsed.key`.
    public var lookups: [String: RepoEntry.Lookup] = [:]
    /// The folder tab: folders completing the field, the one ⇥ completes to, and what is at the path.
    public var candidates: [String] = []
    public var candidate = 0
    public var folderRepo: Repo?
    public var folderNote: String?
    /// While it clones: what it is doing; after a failure: why.
    public var progress: String?
    public var problem: String?

    public init(
        orgs: [String], records: [RepoRecord], roots: [String], then: AfterAdd, lists: [String: ListState] = [:]
    ) {
        tabs = [.mine] + orgs.map(Tab.org) + [.folder]
        self.records = records
        self.roots = roots.isEmpty ? ["~/Projects"] : roots
        root = self.roots[0]
        self.then = then
        self.lists = lists
    }

    public var currentTab: Tab { tabs[tab] }

    /// Orgs that arrived after the dialog opened get a tab each, before the folder tab; the tab you are on stays.
    public mutating func addOrgs(_ orgs: [String]) {
        let current = currentTab
        let known = Set(tabs.compactMap { if case let .org(name) = $0 { name.lowercased() } else { nil } })
        let new = orgs.filter { !known.contains($0.lowercased()) }.map(Tab.org)
        guard !new.isEmpty else { return }
        tabs.insert(contentsOf: new, at: tabs.count - 1)
        tab = tabs.firstIndex(of: current) ?? tab
    }

    /// How many repos a tab lists, for its label; nil while it loads (and for the folder tab).
    public func count(_ tab: Tab) -> Int? {
        switch tab {
        case .mine:
            let loaded = lists.values.compactMap { if case let .loaded(list) = $0 { list } else { nil } }
            guard !loaded.isEmpty else { return nil }
            return RepoListing.newestFirst(loaded.flatMap(\.self)).count
        case let .org(name):
            if case let .loaded(list)? = lists[name] { return list.count }
            return nil
        case .folder: return nil
        }
    }

    /// The tab's list before the field narrows it.
    func listings(_ tab: Tab) -> [RepoListing] {
        switch tab {
        case .mine:
            RepoListing.newestFirst(lists.values.flatMap { state -> [RepoListing] in
                if case let .loaded(list) = state { return list }
                return []
            })
        case let .org(name):
            if case let .loaded(list)? = lists[name] { list } else { [] }
        case .folder: []
        }
    }

    /// The state of the tab's list: loading, why it failed, or loaded.
    public var listState: ListState {
        switch currentTab {
        case .mine:
            if lists.values.contains(where: { if case .loaded = $0 { true } else { false } }) {
                return .loaded(listings(.mine))
            }
            if let failed = lists[""], case .failed = failed { return failed }
            return .loading
        case let .org(name): return lists[name] ?? .loading
        case .folder: return .loaded([])
        }
    }

    /// The field read as a repo: a slug (also from a URL) or a path.
    public var parsed: RepoEntry.Parsed? {
        guard case let .success(parsed)? = RepoEntry.parse(query) else { return nil }
        return parsed
    }

    /// The words the lists are narrowed by: the slug a URL names, else what is typed.
    var words: String {
        if case let .slug(repo)? = parsed { return repo.slug }
        return query
    }

    /// The current list tab's rows: the listings the field matches (on the slug or the description), newest push
    /// first; when none matches and the field is owner/name or a URL, that repo, as GitHub answered for it.
    public var rows: [Row] {
        let tab = currentTab
        guard tab != .folder else { return [] }
        let words = words
        let matching = listings(tab).filter { FilterQuery.matches(words, [$0.repo.slug, $0.description]) }
        var rows = matching.map { Row(listing: $0, place: RepoPlace.of($0.repo, in: records), typed: false) }
        if rows.isEmpty, case let .slug(typed)? = parsed {
            let repo = if case let .found(found)? = lookups[RepoEntry.Parsed.slug(typed).key] { found } else { typed }
            rows = [Row(listing: RepoListing(repo: repo), place: RepoPlace.of(repo, in: records), typed: true)]
        }
        // Picked rows another word hid stay picked; they are not shown.
        return rows
    }

    /// What the typed row says while GitHub is asked, or that it has no such repo.
    public var typedNote: String? {
        guard case let .slug(repo)? = parsed, rows.first?.typed == true else { return nil }
        switch lookups[RepoEntry.Parsed.slug(repo).key] {
        case .found?: return nil
        case .missing?: return "no repo \(repo.slug) on GitHub (or gh cannot see it)"
        case let .failed(why)?: return "could not check \(repo.slug) on GitHub: \(why)"
        case .checking?, nil: return "checking \(repo.slug) on GitHub…"
        }
    }

    public func isPicked(_ repo: Repo) -> Bool {
        picked.contains { $0.lowercased() == repo.slug.lowercased() }
    }

    /// Whether a row can be cloned or added: GitHub knows it (a typed one), and it is not archived and gone.
    func usable(_ row: Row) -> Bool {
        guard row.typed else { return true }
        if case .found? = lookups[RepoEntry.Parsed.slug(row.listing.repo).key] { return true }
        return false
    }

    // MARK: Moving and picking

    public mutating func move(by delta: Int) {
        if currentTab == .folder {
            candidate = min(max(candidate + delta, 0), max(candidates.count - 1, 0))
            return
        }
        cursor = min(max(cursor + delta, 0), max(rows.count - 1, 0))
    }

    public mutating func moveCursor(to index: Int) {
        cursor = min(max(index, 0), max(rows.count - 1, 0))
    }

    /// Space: picks the row under the cursor, or drops it.
    public mutating func togglePick() {
        let rows = rows
        guard rows.indices.contains(cursor), usable(rows[cursor]) else { return }
        toggle(rows[cursor].listing.repo)
    }

    public mutating func toggle(_ repo: Repo) {
        if let index = picked.firstIndex(where: { $0.lowercased() == repo.slug.lowercased() }) {
            picked.remove(at: index)
        } else {
            picked.append(repo.slug)
        }
    }

    public mutating func select(tab index: Int) {
        guard tabs.indices.contains(index) else { return }
        tab = index
        cursor = 0
    }

    public mutating func nextTab(_ delta: Int = 1) {
        select(tab: (tab + delta + tabs.count) % tabs.count)
    }

    /// The next root, round.
    public mutating func cycleRoot() {
        let index = roots.firstIndex(of: root) ?? 0
        root = roots[(index + 1) % roots.count]
    }

    public mutating func cycleThen() {
        let all = AfterAdd.allCases
        then = all[((all.firstIndex(of: then) ?? 0) + 1) % all.count]
    }

    /// Typing: the field, and a path typed into it opens the folder tab (a slug or words, the lists).
    public mutating func type(_ stroke: KeyStroke) -> Bool {
        let before = query
        guard input.handle(stroke) else { return false }
        if query != before { fieldChanged() }
        return true
    }

    public mutating func paste(_ text: String) {
        input.paste(text.trimmingCharacters(in: .whitespacesAndNewlines))
        fieldChanged()
    }

    /// Sets the field, as a click on a folder or a completion does.
    public mutating func setQuery(_ text: String) {
        input.set(text)
        fieldChanged()
    }

    mutating func fieldChanged() {
        cursor = 0
        candidate = 0
        problem = nil
        if case .path? = parsed {
            tab = tabs.firstIndex(of: .folder) ?? tab
        } else if currentTab == .folder, !query.isEmpty {
            tab = 0
        }
        if currentTab != .folder {
            candidates = []
            folderRepo = nil
            folderNote = nil
        }
    }

    /// ⇥ on the folder tab: the field completed to the highlighted folder, ready for the next one.
    public mutating func complete() -> Bool {
        guard currentTab == .folder, candidates.indices.contains(candidate) else { return false }
        input.set(Paths.abbreviate(candidates[candidate]) + "/")
        candidate = 0
        return true
    }

    /// One keystroke. Typing goes to the field; ⌃n ⌃p and ↓ ↑ move; space picks (it types on the folder tab, where
    /// paths may have spaces); ⇥ ⇧⇥ change tabs (⇥ completes a folder on the folder tab); ⌃r and ⌃t change the root
    /// and the "then"; ↩ and ⌘↩ go; ⎋ cancels.
    public mutating func handle(_ stroke: KeyStroke) -> Action {
        switch stroke {
        case .escape: return .cancel
        case KeyStroke("CR"), KeyStroke("CR", .command): return .submit
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            move(by: 1)
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            move(by: -1)
        case KeyStroke("Space") where currentTab != .folder:
            togglePick()
        case KeyStroke("Tab"):
            if complete() { return .changed }
            nextTab()
            return currentTab == .folder ? .changed : .none
        case KeyStroke("Tab", .shift):
            nextTab(-1)
            return currentTab == .folder ? .changed : .none
        case KeyStroke("r", .control): cycleRoot()
        case KeyStroke("t", .control): cycleThen()
        case KeyStroke("w", .control) where currentTab == .folder && input.cursor == query.count:
            input.set(PathCompletion.droppingLastComponent(query))
            fieldChanged()
            return .changed
        default:
            return type(stroke) ? .changed : .none
        }
        return .none
    }

    // MARK: What ⌘↩ does

    /// The picked repos, else the row under the cursor; on the folder tab, the checkout at the path.
    public var targets: [Target] {
        if currentTab == .folder {
            guard folderRepo != nil, case let .path(path)? = parsed else { return [] }
            return [.path(path)]
        }
        let chosen: [Repo]
        if picked.isEmpty {
            let rows = rows
            guard rows.indices.contains(cursor), usable(rows[cursor]) else { return [] }
            chosen = [rows[cursor].listing.repo]
        } else {
            chosen = picked.map(RepoEntry.repo)
        }
        return chosen.map { RepoPlace.of($0, in: records).clones ? .clone($0) : .known($0) }
    }

    /// The button: `Clone 2 repos`, `Clone acme/x`, `Add`; nil when there is nothing to do.
    public var submitTitle: String? {
        let targets = targets
        guard !targets.isEmpty else { return nil }
        let clones = targets.filter { if case .clone = $0 { true } else { false } }
        if clones.isEmpty { return targets.count == 1 ? "Add" : "Add \(targets.count) repos" }
        if targets.count == 1, case let .clone(repo) = clones[0] { return "Clone \(repo.slug)" }
        return "Clone \(targets.count) repo\(targets.count == 1 ? "" : "s")"
    }

    /// The orgs the dialog has a tab for: those of the repos heed knows and the ones gh lists, without your own
    /// account, most repos first, then by name.
    public static func orgs(records: [RepoRecord], listed: [String], viewer: String?) -> [String] {
        var counts: [String: Int] = [:]
        for record in records where record.repo.org != "local" {
            counts[record.repo.org, default: 0] += 1
        }
        for org in listed {
            counts[org, default: 0] += 0
        }
        if let viewer { counts[viewer] = nil }
        return counts.keys.sorted { counts[$0] ?? 0 == counts[$1] ?? 0 ? $0.lowercased() < $1.lowercased()
            : counts[$0] ?? 0 > counts[$1] ?? 0
        }
    }
}

/// What `gh repo list` answered, kept between launches so the dialog opens on the last lists while fresh ones load.
public struct RepoListCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var listings: [RepoListing]

        public init(at: Date, listings: [RepoListing]) {
            self.at = at
            self.listings = listings
        }
    }

    /// By owner: "" for yours.
    public var lists: [String: Entry] = [:]
    /// The orgs gh says you belong to, as last asked.
    public var orgs: [String] = []

    /// How long a list is fresh: younger lists are not asked for again.
    public static let freshFor: TimeInterval = 15 * 60

    public init(lists: [String: Entry] = [:], orgs: [String] = []) {
        self.lists = lists
        self.orgs = orgs
    }

    /// Whether `owner`'s list needs asking for again.
    public func isStale(_ owner: String, now: Date) -> Bool {
        guard let entry = lists[owner] else { return true }
        return now.timeIntervalSince(entry.at) > Self.freshFor
    }

    /// The lists as the dialog takes them.
    public var states: [String: AddRepoForm.ListState] {
        lists.mapValues { .loaded($0.listings) }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/repo-lists.json")
    }

    public static func load(from url: URL = defaultURL) -> RepoListCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(RepoListCache.self, from: data)
        else { return RepoListCache() }
        return cache
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
