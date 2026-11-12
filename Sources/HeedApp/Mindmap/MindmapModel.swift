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
    /// Briefs of sessions started on a node (`s`), by session id: told again when they resume. Since launch only.
    @ObservationIgnored var sessionBriefs: [String: String] = [:]
    /// The node (and its instance) a session was started on with `s`, by session id. Since launch only.
    @ObservationIgnored var sessionNodes: [String: (instance: String, node: String)] = [:]
    /// What Hunch read in a finished session's last message: the question it left, by ledger id ("" for none).
    @ObservationIgnored var unanswered: [String: String] = [:]

    init(fixture: Bool, directory: URL = MindmapStore.defaultDirectory()) {
        self.fixture = fixture
        self.directory = directory
        if fixture {
            trees = Fixtures.mindmap.mapValues { MindmapTree($0) }
            instance = trees.keys.sorted().first ?? MindmapInstance.personal
        } else {
            context.login = UserDefaults.standard.string(forKey: Self.loginKey)
        }
    }

    // MARK: Browsing

    /// The instance shown: an org, or personal (`[o` `]o` switch).
    var instance = MindmapInstance.personal
    /// The node under the cursor; nil: the first top-level one.
    var focus: String?
    /// How many levels the map draws to the right of the focus (`-` `=`).
    var depth = 2
    static let depths = 1 ... 4

    /// Every instance there is, orgs by name, personal last.
    var instances: [String] {
        let all = Set(trees.keys).union([instance])
        return all.filter { $0 != MindmapInstance.personal }.sorted()
            + (all.contains(MindmapInstance.personal) ? [MindmapInstance.personal] : [])
    }

    var shown: MindmapTree { tree(instance) }

    /// The focused node, falling back to the first top-level one.
    var focused: MindNode? {
        let tree = shown
        if let focus, let node = tree[focus] { return node }
        return tree.roots.first
    }

    /// The focus and its siblings: the column the cursor moves in.
    var siblings: [MindNode] {
        let tree = shown
        guard let node = focused else { return [] }
        return node.parent.flatMap { tree[$0] == nil ? nil : tree.children(of: $0) } ?? tree.roots
    }

    var cursor: Int { siblings.firstIndex { $0.id == focused?.id } ?? 0 }

    func setCursor(_ index: Int) {
        let rows = siblings
        guard !rows.isEmpty else { return }
        focus = rows[min(max(index, 0), rows.count - 1)].id
    }

    /// `l`: into the focus's first child. `h`: out to its parent.
    func enter() {
        guard let node = focused, let first = shown.children(of: node.id).first else { return }
        focus = first.id
    }

    func leave() {
        guard let parent = focused?.parent, shown[parent] != nil else { return }
        focus = parent
    }

    /// `[o` `]o`: the next or previous instance.
    func cycleInstance(by step: Int) {
        let all = instances
        guard let index = all.firstIndex(of: instance), all.count > 1 else { return }
        instance = all[(index + step + all.count) % all.count]
        focus = nil
    }

    func changeDepth(by step: Int) {
        depth = min(max(depth + step, Self.depths.lowerBound), Self.depths.upperBound)
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

    /// `instance`'s standup reports, newest first.
    func reports(_ instance: String) async -> [StandupReport] {
        guard !fixture, let store = await store(instance) else { return [] }
        return await (try? store.reports()) ?? []
    }

    func save(_ report: StandupReport) async {
        guard !fixture, let store = await store(report.instance) else { return }
        try? await store.save(report)
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
