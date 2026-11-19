import Foundation
import HeedCore
import Observation

/// Browse's state: the cached items, the saved queries and the scopes in the rail, the query you are on, and the
/// fetch that fills it. The list is a function of these: `rows` is the cache narrowed by the query (`BrowseFilter`),
/// so a cached answer draws at once and a fresh one replaces it as it arrives. GitHub is asked only on demand: when
/// you enter Browse, change scope or query, show older, or refresh. Never on the sync's poll.
@MainActor @Observable
final class BrowseModel {
    enum Load: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// What the last fetch said about its search.
    struct Meta: Equatable {
        var total: Int
        /// "All checkouts" took this many searches, of this many its orgs needed.
        var groups = 1
        var groupsTotal = 1
        var capped: Bool
        var hidden: Int
        var fetchedAt: Date
    }

    private(set) var store: BrowseStore?
    /// The agent runs on items (Fix, Implement, Chat, Review).
    let runs = BrowseRunsModel()
    var items: [BrowseItem] = []
    /// The items the query keeps, in the sort order: what the list draws.
    private(set) var rows: [BrowseItem] = []
    var queries: [SavedQuery] = []
    var scopes: [BrowseScope] = []
    var query = BrowseQuery(tokens: [.state(.open)])
    /// The saved query `query` is, until you change it.
    var activeQuery: String?
    private(set) var sort = BrowseSort.updated
    private(set) var search = ""
    private(set) var load = Load.idle
    private(set) var meta: Meta?
    /// What GitHub counted for a scope or a saved query, by id: the rail's numbers (the cache's own count until then).
    private(set) var scopeTotals: [String: Int] = [:]
    var queryTotals: [String: Int] = [:]
    /// Saved queries with something new since you looked: the blue dot.
    private(set) var newQueries: Set<String> = []
    /// How many repos an org has, as GitHub said.
    private(set) var repoCounts: [String: Int] = [:]
    /// heed's reads of items, by item id: local to this Mac, never written to GitHub.
    var reads: BrowseReads = [:]
    /// Reads being written (or queued), and why one failed, by item id.
    var readRuns: [String: SummaryRun] = [:]
    var readFailures: [String: SummaryFailure] = [:]
    var readProgress: SummaryProgress?
    var palette: BrowsePalette?
    /// The add-filter popover (`/`), and the org view builder ("Create <org> view").
    var builder: BrowseBuilder?
    var orgBuilder: BrowseOrgBuilder?
    /// A GitHub bulk action on the picked items, on its step (typing, confirm, report).
    var bulk: BrowseBulkForm?
    /// The Start work prompts a "session for each" has left to open, one as each form closes.
    var eachQueue: [String] = []
    /// The layout Browse is drawn in, set by its view from the width it has, so commands can follow it.
    var layout = BrowseLayout.wide
    /// Half and third widths: the reader is pushed over the list (↩), and esc goes back to the list.
    var reading = false
    /// Third width: the scope chip's jump sheet (queries and scopes).
    var jumpSheet = false
    /// When each saved query's count was last asked of GitHub, so the rail's refresh is slow.
    @ObservationIgnored var countedAt: [String: Date] = [:]
    @ObservationIgnored var countsTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// What Browse works inside: the orgs and repos checked out, as `repos` says now (never stored).
    private(set) var checkouts = BrowseCheckouts(records: [])
    private(set) var settings = BrowseSettings()
    private(set) var viewer: String?
    let fixture: Bool
    /// What happens once a fetch landed: the ahead reads of the view.
    @ObservationIgnored var landed: (() -> Void)?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(fixture: Bool) { self.fixture = fixture }

    var scope: BrowseScope? { query.scope }

    /// Why the query is not asked, or nil: its org is not checked out, or nothing is.
    var refusal: BrowseFetchError? { BrowseFetch.refusal(for: query, checkouts: checkouts) }

    /// The checkouts changed (a clone, a removal, repos loaded): the list and the counts follow.
    func setCheckouts(_ new: BrowseCheckouts) {
        guard new != checkouts else { return }
        checkouts = new
        schedulePrune()
        guard started else { return }
        refilter()
        countedAt = [:]
        fetch()
    }

    /// Drops what the cache holds outside the checkouts, quietly: once the checkouts have been steady for a while (so
    /// a repo list still loading never wipes anything), at utility priority, off the main actor, in batches. Never in
    /// the fake world, and never with nothing checked out (`BrowseStore.prune` does nothing for no orgs).
    func schedulePrune(after delay: Duration = .seconds(20)) {
        pruneTask?.cancel()
        guard !fixture, let store, !checkouts.isEmpty else { return }
        let orgs = checkouts.orgNames
        pruneTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if let removed = try? await store.prune(keepingOrgs: orgs), removed > 0 {
                NSLog("heed: Browse's cache dropped \(removed) items outside what is checked out")
            }
        }
    }

    /// The query a saved one runs as: inside the scope you are in, unless it names a place of its own (then the scope
    /// neither widens nor narrows it). With no scope either, it runs inside the checkouts.
    func effective(_ saved: SavedQuery) -> BrowseQuery {
        var next = saved.query
        if next.scope == nil, !next.hasOwnPlace { next.scope = scope }
        return next
    }

    /// The cached items the query can show: with no place of its own it is the checked-out orgs' items only.
    private func visible(_ query: BrowseQuery) -> [BrowseItem] {
        guard query.scope == nil, !query.hasOwnPlace else { return items }
        return items.filter { checkouts.contains(org: $0.repo.org) }
    }

    var activeSaved: SavedQuery? { queries.first { $0.id == activeQuery } }

    // MARK: Opening

    /// Opens `browse.sqlite` beside the domain file, then draws what it kept: queries, scopes, items, and where you
    /// were.
    func open(beside file: URL) async {
        store = await BrowseStore.open(at: file.deletingLastPathComponent().appendingPathComponent("browse.sqlite"))
        guard let store else { return }
        do {
            if try await !store.flag("starters") {
                // Agent-ready leads; the others follow.
                for starter in [SavedQuery.agentReady] + SavedQuery.starters {
                    try await store.save(starter)
                }
                try await store.setFlag("starters")
                try await store.setFlag("starter-agent-ready")
            } else if try await !store.flag("starter-agent-ready") {
                // Added with heed's read: once for those who had the first four, at the end.
                try await store.save(SavedQuery.agentReady)
                try await store.setFlag("starter-agent-ready")
            }
            queries = try await store.savedQueries()
            scopes = try await store.scopes()
            items = try await store.items()
            reads = try await store.reads()
            if let last = try await store.last() {
                query = last.query
                query.scope = last.scope
            }
            try await store.prune(now: Date())
        } catch {
            NSLog("heed: could not read Browse's cache: \(error)")
        }
        started = true
        refilter()
        schedulePrune()
    }

    /// The fake world's: no store, what the fixtures say.
    func adoptFixtures() {
        let data = Fixtures.Browse.self
        items = data.cached
        reads = data.reads
        queries = data.queries
        scopes = data.scopes
        scopeTotals = data.scopeTotals
        queryTotals = data.queryTotals
        newQueries = data.newQueries
        query = data.last.query
        checkouts = BrowseCheckouts(records: data.records)
        meta = Meta(total: data.total, capped: true, hidden: 0, fetchedAt: Clock.now)
        started = true
        refilter()
    }

    func configure(_ settings: BrowseSettings, viewer: String?) {
        let moved = settings.maxAgeDays != self.settings.maxAgeDays
        self.settings = settings
        self.viewer = viewer
        if moved { refilter() }
    }

    // MARK: What the list shows

    func refilter(now: Date = Clock.now) {
        rows = BrowseFetch.refusal(for: query, checkouts: checkouts) == nil ? narrowed(query, now: now) : []
    }

    /// The items `query` keeps, in the sort order, and the search words (`/` in the list) over them.
    private func narrowed(_ query: BrowseQuery, now: Date) -> [BrowseItem] {
        var kept = BrowseFilter(query: query, viewer: viewer, maxAgeDays: settings.maxAgeDays, reads: reads)
            .apply(to: visible(query), sort: sort, now: now)
        let words = search.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty {
            let parts = words.split(separator: " ").map(String.init)
            kept = kept.filter { item in
                parts.allSatisfy { part in
                    item.title.contains(part) || item.place.localizedCaseInsensitiveContains(part)
                        || item.labels.contains { $0.localizedCaseInsensitiveContains(part) }
                }
            }
        }
        return kept
    }

    /// The rows heed may read: the view without heed's own filters (they need a read to match, so a view narrowed by
    /// them would never show what is still unread).
    func readCandidates(now: Date = Clock.now) -> [BrowseItem] {
        var open = query
        open.tokens = query.githubTokens
        return narrowed(open, now: now)
    }

    /// Keeps heed's read of an item: in memory, on this Mac's disk, and in the list (a filter on it may now match).
    func keepRead(_ read: BrowseRead) {
        reads[read.itemID] = read
        readFailures[read.itemID] = nil
        refilter()
        let store = store
        Task { try? await store?.save(read) }
    }

    /// Items changed on GitHub by a bulk action: replaced in the cache and the list, and kept on disk.
    func apply(_ changed: [BrowseItem]) {
        guard !changed.isEmpty else { return }
        let byID = Dictionary(changed.map { ($0.id, $0) }) { _, last in last }
        items = items.map { byID[$0.id] ?? $0 }
        refilter()
        let store = store
        Task { try? await store?.record(changed, now: Date()) }
    }

    func setSearch(_ text: String) {
        search = text
        refilter()
    }

    func cycleSort() {
        let all = BrowseSort.allCases
        sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
        refilter()
    }

    /// The count the rail shows for a scope: GitHub's when a fetch said, else the cache's.
    /// nil (a dash) for an org that is not checked out: nothing of it is searched.
    func count(of scope: BrowseScope, now: Date = Clock.now) -> Int? {
        let asked = BrowseQuery(scope: scope, tokens: [.state(.open)])
        guard BrowseFetch.refusal(for: asked, checkouts: checkouts) == nil else { return nil }
        return scopeTotals[scope.id] ?? BrowseFilter.count(
            asked, in: items, viewer: viewer, maxAgeDays: settings.maxAgeDays, now: now, reads: reads
        )
    }

    /// nil (a dash) when the query would not be asked.
    func count(of saved: SavedQuery, now: Date = Clock.now) -> Int? {
        let asked = effective(saved)
        guard BrowseFetch.refusal(for: asked, checkouts: checkouts) == nil else { return nil }
        // heed's own filters count what heed has read: before it has read anything, that is not "0" but not known yet.
        if !saved.query.localTokens.isEmpty, reads.isEmpty, !fixture { return nil }
        // A query with heed's own filters has more than GitHub's total: the cache's count, narrowed by the reads.
        return (saved.query.localTokens.isEmpty || fixture ? queryTotals[saved.id] : nil) ?? BrowseFilter.count(
            asked, in: visible(asked), viewer: viewer, maxAgeDays: settings.maxAgeDays, now: now, reads: reads
        )
    }

    var newCount: Int { newQueries.count }

    /// `3 months` or `90 days`: the cap, as the header says it.
    var cap: String {
        let days = settings.maxAgeDays
        return days % 30 == 0 && days >= 60 ? "\(days / 30) months" : "\(days) days"
    }

    // MARK: Going somewhere

    /// Browses `scope`: opens its open items, keeps it in the rail, and asks GitHub.
    func go(to scope: BrowseScope?) {
        // A saved query you are on goes with you (Stale 30d+ in another org), unless it names a place of its own.
        var next = BrowseQuery(scope: scope, tokens: [.state(.open)])
        var keep = activeQuery
        if let saved = activeSaved, !saved.query.hasOwnPlace {
            next = saved.query
            next.scope = scope
        } else {
            keep = nil
        }
        next.showOlder = false
        query = next
        activeQuery = keep
        // Only a scope that is searched joins the rail: an org with no checkout shows the clone-first card instead.
        if let scope, !scopes.contains(scope), checkouts.allows(BrowsePlace(owner: scope.owner)) {
            scopes.append(scope)
            let store = store
            Task { try? await store?.pin(scope) }
        }
        changed()
    }

    func unpin(_ scope: BrowseScope) {
        scopes.removeAll { $0 == scope }
        let store = store
        Task { try? await store?.unpin(scope) }
    }

    /// Runs a saved query, within the scope you are in when it names none (see `effective`).
    func run(_ saved: SavedQuery) {
        query = effective(saved)
        activeQuery = saved.id
        newQueries.remove(saved.id)
        changed()
    }

    func nextScope(by step: Int) {
        guard !scopes.isEmpty else { return }
        let index = scope.flatMap { scopes.firstIndex(of: $0) }
        go(to: scopes[((index ?? (step > 0 ? -1 : 0)) + step + scopes.count) % scopes.count])
    }

    func nextQuery(by step: Int) {
        guard !queries.isEmpty else { return }
        let index = queries.firstIndex { $0.id == activeQuery }
        run(queries[((index ?? (step > 0 ? -1 : 0)) + step + queries.count) % queries.count])
    }

    /// "Show older" lifts the cap for this view; the same again puts it back.
    func toggleOlder() {
        query.showOlder.toggle()
        changed()
    }

    func changed() {
        refilter()
        remember()
        fetch()
    }

    private func remember() {
        guard let store else { return }
        var last = query
        last.scope = nil
        let record = BrowseLast(scope: query.scope, query: last)
        Task { try? await store.setLast(record) }
    }

    // MARK: Asking GitHub

    /// Asks GitHub for the query, off the main actor. What the cache held stays on screen until the answer lands; a
    /// failure leaves it and says why. Never in the fake world.
    func fetch() {
        fetchTask?.cancel()
        // Nothing is sent for a place that is not checked out (the list says so), and nothing for no place with no
        // checkouts: `BrowseFetch` refuses both again, so this is only to not show "asking GitHub".
        guard !fixture, started, refusal == nil else { return load = .idle }
        let asked = query
        let days = settings.maxAgeDays
        let checkouts = checkouts
        load = .loading
        fetchTask = Task { [weak self] in
            do {
                let result = try await BrowseFetch.search(asked, maxAgeDays: days, checkouts: checkouts)
                guard !Task.isCancelled, let self else { return }
                land(result, for: asked)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                load = .failed((error as? GitHub.Failure)?.description ?? error.localizedDescription)
            }
        }
    }

    private func land(_ result: BrowseFetch.Result, for asked: BrowseQuery) {
        guard asked == query else { return }
        var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        for item in result.items {
            byID[item.id] = item
        }
        items = Array(byID.values)
        meta = Meta(
            total: result.total, groups: result.groups, groupsTotal: result.groupsTotal, capped: result.capped,
            hidden: result.hidden, fetchedAt: result.fetchedAt
        )
        if let scope = asked.scope, asked.tokens == [.state(.open)] { scopeTotals[scope.id] = result.total }
        if let id = activeQuery, asked.localTokens.isEmpty {
            queryTotals[id] = result.total
            countedAt[id] = Date()
        }
        load = .idle
        refilter()
        landed?()
        let store = store
        let kept = result.items
        Task { try? await store?.record(kept, now: Date()) }
    }

    /// How many repos an org has, asked once for the guidance on big ones.
    func learnRepoCount(of owner: String) {
        guard !fixture, repoCounts[owner.lowercased()] == nil else { return }
        Task { [weak self] in
            guard let count = await BrowseFetch.repoCount(owner: owner) else { return }
            self?.repoCounts[owner.lowercased()] = count
            self?.palette?.setRepoCount(count, of: owner)
        }
    }
}
