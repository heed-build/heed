import Foundation
import HeedCore
import Observation

/// Every Mindmap heed keeps: one per GitHub org and one for personal work, each in its own store. The app reads and
/// changes one instance at a time; nothing here ever puts two instances' nodes together.
@MainActor
@Observable
final class MindmapModel {
    private(set) var trees: [String: MindmapTree] = [:]
    @ObservationIgnored private var stores: [String: MindmapStore] = [:]
    @ObservationIgnored let directory: URL
    /// What decides an instance beyond the repo's owner: your login, forks' upstreams, folder chats' repos.
    @ObservationIgnored var context = MindmapInstance.Context()
    /// Naming calls made today, per instance (`MindmapNaming.dailyCalls`).
    @ObservationIgnored private var named: [String: (day: Date, count: Int)] = [:]
    @ObservationIgnored let fixture: Bool

    init(fixture: Bool, directory: URL = MindmapStore.defaultDirectory()) {
        self.fixture = fixture
        self.directory = directory
        context.login = UserDefaults.standard.string(forKey: Self.loginKey)
    }

    static let loginKey = "mindmap.login"

    /// Opens every instance that has a file.
    func load() async {
        guard !fixture else { return }
        for instance in MindmapStore.instances(in: directory) where stores[instance] == nil {
            guard let store = await MindmapStore.open(instance, in: directory) else { continue }
            stores[instance] = store
            trees[instance] = await MindmapTree((try? store.nodes()) ?? [])
        }
    }

    func setLogin(_ login: String) {
        context.login = login
        UserDefaults.standard.set(login, forKey: Self.loginKey)
    }

    func tree(_ instance: String) -> MindmapTree { trees[instance] ?? MindmapTree() }

    /// Where an entry goes.
    func instance(of entry: LedgerEntry) -> MindmapInstance.Resolved { MindmapInstance.of(entry, context: context) }

    /// Changes one instance's tree and writes what changed.
    func change(_ instance: String, _ body: (inout MindmapTree) -> Void) async {
        let before = tree(instance)
        var after = before
        body(&after)
        guard after != before else { return }
        trees[instance] = after
        guard !fixture, let store = await store(instance) else { return }
        let changed = after.nodes.values.filter { before[$0.id] != $0 }
        let removed = before.nodes.keys.filter { after[$0] == nil }
        try? await store.upsert(Array(changed))
        try? await store.delete(Array(removed))
    }

    private func store(_ instance: String) async -> MindmapStore? {
        if let store = stores[instance] { return store }
        let store = await MindmapStore.open(instance, in: directory)
        stores[instance] = store
        return store
    }

    /// Whether a naming call fits today's budget for `instance`; counts it when it does.
    func spendNamingCall(_ instance: String, now: Date = Date()) -> Bool {
        let today = Calendar.current.startOfDay(for: now)
        let spent = named[instance].map { $0.day == today ? $0.count : 0 } ?? 0
        guard spent < MindmapNaming.dailyCalls else { return false }
        named[instance] = (today, spent + 1)
        return true
    }

    /// How placement does, across every instance (counts only, no content mixes).
    var stats: MindmapStats { MindmapStats(Array(trees.values)) }

    /// Every node, for Hunch's harvest (one shared head learns from all of them, as it does from everything else).
    var allNodes: [MindNode] { trees.values.flatMap { Array($0.nodes.values) } }
}
