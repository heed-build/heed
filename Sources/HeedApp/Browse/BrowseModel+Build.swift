import Foundation
import HeedCore
import Observation

/// Browse's query builder: the add-filter popover, saved queries kept in the rail, the org view builder and the
/// rail's slow count refresh. What leaves the pure builders as an action is acted on here.
extension BrowseModel {
    // MARK: The add-filter popover

    func builderContext(wordsOff: String?, now: Date = Clock.now) -> BrowseBuilder.Context {
        BrowseBuilder.Context(
            items: items, viewer: viewer, maxAgeDays: settings.maxAgeDays, now: now,
            projects: scopes.filter { if case .project = $0 { true } else { false } }, wordsOff: wordsOff,
            reads: reads, checkouts: checkouts
        )
    }

    func openBuilder(wordsOff: String?) {
        builder = BrowseBuilder(base: query, context: builderContext(wordsOff: wordsOff))
    }

    /// Carries out what the popover said; the caller handles the ones that need the app (`read`, `copy`).
    func applyBuilder(_ query: BrowseQuery) {
        self.query = query
        activeQuery = nil
        changed()
    }

    /// Keeps a query in the rail: a new one at the end, or the one being renamed in place.
    func keep(_ keep: BrowseBuilder.Keep) {
        var kept = keep.query
        kept.scope = nil
        let store = store
        if let id = keep.id, let index = queries.firstIndex(where: { $0.id == id }) {
            queries[index].name = keep.name
            queries[index].glyph = keep.glyph
            queries[index].tint = keep.tint
            let saved = queries[index]
            Task { try? await store?.save(saved) }
            return
        }
        let id = "q\(Int(Date().timeIntervalSince1970))-\(queries.count)"
        let saved = SavedQuery(id: id, name: keep.name, glyph: keep.glyph, tint: keep.tint, query: kept)
        queries.append(saved)
        activeQuery = id
        Task { try? await store?.save(saved) }
    }

    func removeQuery(_ id: String) {
        queries.removeAll { $0.id == id }
        queryTotals[id] = nil
        if activeQuery == id { activeQuery = nil }
        let store = store
        Task { try? await store?.removeQuery(id: id) }
    }

    func moveQuery(_ id: String, by step: Int) {
        queries = SavedQuery.moved(queries, id: id, by: step)
        let order = queries.map(\.id)
        let store = store
        Task { try? await store?.reorderQueries(order) }
    }

    /// Keeps the query you are on, with the glyph its filter picks (what `S` did before the popover had a step).
    func saveQuery(named name: String? = nil) {
        var query = query
        query.scope = nil
        keep(.init(
            id: nil, name: name ?? SavedQuery.suggestedName(for: query), glyph: BrowseGlyph.pick(for: query),
            tint: BrowseGlyph.pick(for: query).tint, query: query
        ))
    }

    // MARK: Org views

    func openOrgBuilder(owner: String) {
        orgBuilder = BrowseOrgBuilder(owner: owner)
        guard !fixture else {
            orgBuilder?.loaded(Fixtures.Browse.globexRepos)
            return
        }
        Task { [weak self] in
            let loaded = await BrowseFetch.orgRepos(owner: owner)
            guard let self, orgBuilder?.owner == owner else { return }
            if let loaded {
                orgBuilder?.loaded(loaded)
            } else {
                orgBuilder?.problem = "gh could not list \(owner)'s repos"
                orgBuilder?.loaded([])
            }
        }
    }

    /// Pins the view as a scope and goes to it.
    func create(_ view: BrowseOrgView) {
        var view = view
        let taken = Set(scopes.compactMap { scope -> String? in
            if case let .view(other) = scope, other.owner == view.owner { other.name } else { nil }
        })
        var name = view.name
        var number = 2
        while taken.contains(name) {
            name = "\(view.name) \(number)"
            number += 1
        }
        view.name = name
        orgBuilder = nil
        go(to: .view(view))
    }

    // MARK: The rail's counts

    /// Counts come from the cache until a saved query is run; while Browse is in front they are refreshed, one
    /// query every `pause` seconds, oldest count first, and none that is younger than `stale` seconds.
    func startCounts(front: @escaping @MainActor () -> Bool, pause: Double = 20, stale: Double = 600) {
        guard !fixture, countsTask == nil else { return }
        countsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pause))
                guard let self, front() else { break }
                let now = Date()
                // GitHub cannot count heed's own filters: those queries count what is cached and read.
                let due = queries.filter { $0.query.localTokens.isEmpty }
                    .filter { now.timeIntervalSince(countedAt[$0.id] ?? .distantPast) > stale }
                    .min { (countedAt[$0.id] ?? .distantPast) < (countedAt[$1.id] ?? .distantPast) }
                guard let saved = due else { continue }
                countedAt[saved.id] = now
                let asked = effective(saved)
                if let total = try? await BrowseFetch.count(
                    asked, maxAgeDays: settings.maxAgeDays, checkouts: checkouts
                ) {
                    queryTotals[saved.id] = total
                }
            }
            self?.countsTask = nil
        }
    }
}
