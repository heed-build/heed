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
    private(set) var settings = BrowseSettings()
    private(set) var viewer: String?
    let fixture: Bool
    /// What an answer changes in the list that waits for you (new, gone and reordered rows), while an item is held.
    private(set) var pending: BrowseDiff?
    /// The rows the last automatic refresh brought: marked until the next answer lands.
    private(set) var fresh: Set<String> = []
    /// The refresh in flight asks quietly: no spinner, no "asking GitHub".
    private(set) var silent = false
    /// When each scope and query was last answered, and how many fetches failed in a row, the last one when.
    @ObservationIgnored private var answered: [BrowseQuery: Date] = [:]
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var failedAt: Date?
    /// The held answer: what GitHub listed, and the rows it no longer lists.
    @ObservationIgnored private var held: (fetched: [BrowseItem], gone: Set<String>)?
    /// What the list is held by (the cursor, the picks, the reader, a run, a sheet): set by the app model.
    @ObservationIgnored var holdState: (() -> BrowseRefreshPolicy.State)?
    /// Where the cursor and the picks are, so a held diff keeps them.
    @ObservationIgnored var cursorState: (() -> (id: String?, index: Int, picks: Set<String>))?
    /// The cursor and the picks after a held diff was applied.
    @ObservationIgnored var adopt: ((BrowseRefreshApply.Outcome) -> Void)?
    /// What happens once a fetch landed: the ahead reads of the view.
    @ObservationIgnored var landed: (() -> Void)?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(fixture: Bool) { self.fixture = fixture }

    var scope: BrowseScope? { query.scope }

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

    /// Draws the cache narrowed by the query. While an answer is held, the rows keep the places they have: a read
    /// arriving or a bulk action must not reorder the list under the cursor.
    func refilter(now: Date = Clock.now) {
        let next = narrowed(query, now: now)
        guard held != nil else { return rows = next }
        let place = Dictionary(rows.enumerated().map { ($1.id, $0) }) { first, _ in first }
        rows = next.enumerated().sorted {
            (place[$0.element.id] ?? Int.max, $0.offset) < (place[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
        recomputePending(now: now)
    }

    /// The items `query` keeps, in the sort order, and the search words (`/` in the list) over them.
    private func narrowed(_ query: BrowseQuery, now: Date, from pool: [BrowseItem]? = nil) -> [BrowseItem] {
        var kept = BrowseFilter(query: query, viewer: viewer, maxAgeDays: settings.maxAgeDays, reads: reads)
            .apply(to: pool ?? items, sort: sort, now: now)
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
        discardPending()
        refilter()
    }

    func cycleSort() {
        let all = BrowseSort.allCases
        sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
        discardPending()
        refilter()
    }

    /// The count the rail shows for a scope: GitHub's when a fetch said, else the cache's.
    func count(of scope: BrowseScope, now: Date = Clock.now) -> Int {
        scopeTotals[scope.id] ?? BrowseFilter.count(
            BrowseQuery(scope: scope, tokens: [.state(.open)]), in: items, viewer: viewer,
            maxAgeDays: settings.maxAgeDays, now: now, reads: reads
        )
    }

    func count(of saved: SavedQuery, now: Date = Clock.now) -> Int {
        // A query with heed's own filters has more than GitHub's total: the cache's count, narrowed by the reads.
        (saved.query.localTokens.isEmpty || fixture ? queryTotals[saved.id] : nil) ?? BrowseFilter.count(
            saved.query, in: items, viewer: viewer, maxAgeDays: settings.maxAgeDays, now: now, reads: reads
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
        var next = BrowseQuery(scope: scope, tokens: [.state(.open)])
        next.showOlder = false
        query = next
        activeQuery = nil
        if let scope, !scopes.contains(scope) {
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

    /// Runs a saved query, within the scope you are in when it names none.
    func run(_ saved: SavedQuery) {
        var next = saved.query
        if next.scope == nil { next.scope = scope }
        query = next
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
        discardPending()
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

    /// How an answer meets the list.
    enum Landing {
        /// You asked (a new scope or query, `r`): the list becomes the answer.
        case replace
        /// Coming back asked: rows you can see change in place, and new, gone and reordered rows wait when an item is
        /// held.
        case refresh
    }

    /// Asks GitHub for the query, off the main actor. What the cache held stays on screen until the answer lands; a
    /// failure leaves it and says why. Never in the fake world.
    func fetch(_ landing: Landing = .replace) {
        guard !fixture, started, query.scope != nil || !query.tokens.isEmpty else { return }
        fetchTask?.cancel()
        let asked = query
        let days = settings.maxAgeDays
        load = .loading
        silent = landing == .refresh
        fetchTask = Task { [weak self] in
            do {
                let result = try await BrowseFetch.search(asked, maxAgeDays: days)
                guard !Task.isCancelled, let self else { return }
                land(result, for: asked, landing)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                failures += 1
                failedAt = Date()
                silent = false
                load = .failed((error as? GitHub.Failure)?.description ?? error.localizedDescription)
            }
        }
    }

    /// What the refresh policy reads of this model: how old the last answer for this scope and query is, whether a
    /// fetch runs, how the last ones went.
    func refreshState(now: Date = Date()) -> BrowseRefreshPolicy.State {
        var state = BrowseRefreshPolicy.State()
        state.autoRefresh = settings.autoRefresh
        state.refreshAfter = settings.refreshAfter
        state.age = answered[query].map { now.timeIntervalSince($0) }
        state.inFlight = load == .loading
        state.failures = failures
        state.sinceFailure = failedAt.map { now.timeIntervalSince($0) }
        state.fixture = fixture || !started
        state.hasQuery = query.scope != nil || !query.tokens.isEmpty
        return state
    }

    private func land(_ result: BrowseFetch.Result, for asked: BrowseQuery, _ landing: Landing) {
        guard asked == query else { return }
        meta = Meta(total: result.total, capped: result.capped, hidden: result.hidden, fetchedAt: result.fetchedAt)
        answered[asked] = result.fetchedAt
        failures = 0
        failedAt = nil
        if let scope = asked.scope, asked.tokens == [.state(.open)] { scopeTotals[scope.id] = result.total }
        if let id = activeQuery, asked.localTokens.isEmpty {
            queryTotals[id] = result.total
            countedAt[id] = Date()
        }
        load = .idle
        silent = false
        fresh = []
        let gone = BrowseRefreshApply.gone(shown: rows, fetched: result.items, capped: result.capped)
        let store = store
        let kept = result.items
        Task { try? await store?.record(kept, now: Date()) }
        let holding = landing == .refresh && (holdState?().holds ?? false)
        if holding {
            hold(result.items, gone: gone)
        } else if landing == .refresh, let cursor = cursorState?() {
            // Nothing is held: the list becomes the answer, the cursor staying on its item.
            held = nil
            pending = nil
            let outcome = replace(with: result.items, gone: gone, cursor: cursor)
            adopt?(outcome)
        } else {
            held = nil
            pending = nil
            var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
            for item in result.items {
                byID[item.id] = item
            }
            items = byID.values.filter { !gone.contains($0.id) }
            forget(gone)
            refilter()
        }
        landed?()
    }

    /// An answer under a held item: the rows on screen take their new fields at once, where they are; the rest waits.
    private func hold(_ fetched: [BrowseItem], gone: Set<String>) {
        let shown = Set(rows.map(\.id))
        var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        for item in fetched where shown.contains(item.id) {
            byID[item.id] = item
        }
        items = Array(byID.values)
        held = (fetched, gone)
        let latest = Dictionary(fetched.map { ($0.id, $0) }) { _, last in last }
        rows = rows.map { latest[$0.id] ?? $0 }
        recomputePending()
    }

    /// The list a held answer would make, against what is on screen.
    private func recomputePending(now: Date = Clock.now) {
        guard let held else { return pending = nil }
        var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        for item in held.fetched {
            byID[item.id] = item
        }
        let target = narrowed(query, now: now, from: byID.values.filter { !held.gone.contains($0.id) })
        let latest = Dictionary(held.fetched.map { ($0.id, $0) }) { _, last in last }
        // Rows on screen take their fields now, so what is left is only what moves, comes or goes.
        rows = rows.map { latest[$0.id] ?? $0 }
        let diff = BrowseDiff.between(current: rows, fetched: target, order: sort)
        if diff.isStructural {
            pending = diff
        } else {
            pending = nil
            self.held = nil
        }
    }

    private func replace(
        with fetched: [BrowseItem], gone: Set<String>, cursor: (id: String?, index: Int, picks: Set<String>)
    ) -> BrowseRefreshApply.Outcome {
        var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        for item in fetched {
            byID[item.id] = item
        }
        items = byID.values.filter { !gone.contains($0.id) }
        forget(gone)
        let target = narrowed(query, now: Clock.now)
        let diff = BrowseDiff.between(current: rows, fetched: target, order: sort)
        let outcome = BrowseRefreshApply.apply(
            diff, to: rows, cursorID: cursor.id, cursorIndex: cursor.index, picks: cursor.picks
        )
        rows = outcome.rows
        fresh = outcome.fresh
        return outcome
    }

    /// Makes the held answer the list (`r` on the banner): the cursor stays on its item, the picks that still exist
    /// stay picked.
    func applyPending() {
        guard let held, let cursor = cursorState?() else { return }
        recomputePending()
        guard pending != nil else { return }
        var byID = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        for item in held.fetched {
            byID[item.id] = item
        }
        items = byID.values.filter { !held.gone.contains($0.id) }
        forget(held.gone)
        self.held = nil
        pending = nil
        let outcome = replace(with: [], gone: [], cursor: cursor)
        adopt?(outcome)
    }

    /// The fake world's: a held diff drawn as given (the shots and previews), with no answer behind it.
    func previewPending(_ diff: BrowseDiff?) { pending = diff }

    private func discardPending() {
        held = nil
        pending = nil
        fresh = []
    }

    /// Drops rows GitHub no longer lists from the cache, so a restart does not bring them back.
    private func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let store = store
        Task { try? await store?.forget(ids: Array(ids)) }
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
