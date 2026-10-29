import Foundation
import HeedCore

/// Goals' item sources, as the Goals view reads them.
extension GoalsBrowser {
    /// The selected goal's sources and heed's proposal.
    var sources: GoalSourceState { selected.map { snapshot.sources(of: $0.id) } ?? .empty }

    /// Reads the goals again (after a sync wrote to them).
    func reload() {
        guard let ops else { return }
        Task { if let snapshot = try? await ops.snapshot() { apply(snapshot) } }
    }

    /// The fake world's item sources laid over it: at once for what is drawn, and into the in-memory store once the
    /// fake world is in it.
    func loadSourcesFixture() {
        let fixtures = ItemSourceFixtures.all()
        let states = ItemSourceFixtures.states()
        var fresh = snapshot
        let added = GoalFixtures.snapshot(fixtures)
        fresh.goals = (fresh.goals + added.goals).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        fresh.items = (fresh.items + added.items).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let first = Int64(fresh.evidence.count)
        fresh.evidence += added.evidence.map { entry in
            var entry = entry
            entry.id = (entry.id ?? 0) + first
            return entry
        }
        fresh.evidence.sort { ($0.at, $0.id ?? 0) < ($1.at, $1.id ?? 0) }
        fresh.docs.merge(added.docs) { _, new in new }
        fresh.sources.merge(states) { _, new in new }
        apply(fresh)
        guard let ops else { return }
        let load = fixtureLoad
        Task {
            await load?.value
            try? await ops.adopt(fixtures)
            try? await ops.adopt(sources: states)
            if let snapshot = try? await ops.snapshot() { apply(snapshot) }
        }
    }
}
