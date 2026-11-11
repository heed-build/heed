import Foundation
import HeedCore

/// History's Mindmap: placing finished work as the ledger writes it, naming campaigns for work that fits none, and
/// what heed needs to keep orgs apart (your login, forks' upstreams, folder chats' repos).
extension AppModel {
    func startMindmap() {
        guard !isFixture, config.mindmap.enabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await mindmap.load()
            await learnMindmapContext()
            await backfillMindmap()
        }
    }

    /// Your login (once, kept), and the upstream of every repo that has an `upstream` remote.
    private func learnMindmapContext() async {
        if mindmap.context.login == nil, let login = try? await GitHub.viewer(caller: "mindmap.login"),
           !login.isEmpty
        {
            mindmap.setLogin(login)
        }
        for record in repos where mindmap.context.upstreams[record.repo.slug] == nil {
            if let upstream = await Git.upstream(at: record.path, on: record.location), upstream != record.repo {
                mindmap.context.upstreams[record.repo.slug] = upstream.slug
            }
        }
    }

    /// The route a placement question takes with the decider as set, for the stats.
    private var mindmapRoute: String {
        switch config.decisions.effective {
        case .hunch: hunch.status.modelReady ? "hunch" : localModel.ready ? "local" : "model"
        case .local: "local"
        case .model: "model"
        case .off: "off"
        }
    }

    /// A ledger entry, (re)written: placed in its Mindmap. Work already placed (or moved by you) only takes the
    /// entry's new words; new work is placed, as a suggestion while `[mindmap] shadow` is on.
    func placeInMindmap(_ entry: LedgerEntry, session: Session?) async {
        guard !isFixture, config.mindmap.enabled else { return }
        if entry.chat, entry.repos.isEmpty, session?.chat?.kind == .folder, let path = session?.chat?.path,
           mindmap.context.chatRepos[entry.id] == nil
        {
            let repo = await Git.repo(at: path, on: session?.location ?? .local)
            if repo.org != "local" { mindmap.context.chatRepos[entry.id] = repo.slug }
        }
        let instance = mindmap.instance(of: entry).instance
        let tree = mindmap.tree(instance)
        let known = tree.work(for: entry.id)
        var placed: MindmapPlace.Placed?
        if known == nil || (known?.parent == nil && known?.madeBy != .you) {
            let decider = decisionsOn ? decider(caller: "mindmap.place") : nil
            placed = await MindmapPlace.decide(
                entry, in: tree, ledger: ledger.entries, decider: decider, route: mindmapRoute
            )
            if config.mindmap.shadow, case let .campaign(id, confidence, route, _)? = placed?.outcome {
                placed?.outcome = .campaign(id, confidence: confidence, route: route, sure: false)
            }
        }
        var held: [MindmapPlace.Check] = []
        if !config.mindmap.shadow, case let .campaign(campaign, _, _, true)? = placed?.outcome, decisionsOn {
            var after = tree
            MindmapPlace.record(entry, placed: placed, in: &after, now: Date())
            held = await MindmapPlace.confirm(
                MindmapPlace.checks(for: entry, campaign: campaign, in: after), entry: entry,
                decider: decider(caller: "mindmap.check")
            )
        }
        await mindmap.change(instance) { tree in
            MindmapPlace.record(entry, placed: placed, in: &tree, now: Date())
            MindmapPlace.apply(held, entry: entry, to: &tree, now: Date())
        }
        await nameMindmapCampaigns(instance)
    }

    /// Campaigns for the work that waits in Unsorted, when enough of it does and today's budget allows.
    func nameMindmapCampaigns(_ instance: String) async {
        guard config.llm.enabled else { return }
        let waiting = mindmap.tree(instance).unsorted.compactMap { $0.entry }.compactMap { ledger.entries[$0] }
        guard waiting.count >= MindmapNaming.minimum, mindmap.spendNamingCall(instance) else { return }
        guard let text = try? await summarizer.summarize(
            kind: .mindmapName, inputs: MindmapNaming.inputs(waiting), caller: "mindmap.name"
        ) else { return }
        let proposals = MindmapNaming.parse(text, known: Set(waiting.map(\.id)))
        await mindmap.change(instance) { tree in MindmapNaming.apply(proposals, to: &tree, now: Date()) }
    }

    /// The ledger heed already has, placed once: oldest first, with no model calls for the placing (Hunch and the
    /// on-device model are free; with only model calls set, the words alone place it), then campaigns named.
    private func backfillMindmap() async {
        let placedAlready = Set(mindmap.allNodes.compactMap(\.entry))
        let waiting = ledger.entries.values.filter { !placedAlready.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
        guard !waiting.isEmpty else { return }
        let free = ["hunch", "local"].contains(mindmapRoute) && decisionsOn
        var touched: Set<String> = []
        for entry in waiting {
            let instance = mindmap.instance(of: entry).instance
            var placed = await MindmapPlace.decide(
                entry, in: mindmap.tree(instance), ledger: ledger.entries,
                decider: free ? decider(caller: "mindmap.place") : nil, route: mindmapRoute
            )
            if case let .campaign(id, confidence, route, _) = placed.outcome {
                placed.outcome = .campaign(id, confidence: confidence, route: route, sure: false)
            }
            await mindmap
                .change(instance) { tree in MindmapPlace.record(entry, placed: placed, in: &tree, now: Date()) }
            touched.insert(instance)
        }
        for instance in touched.sorted() {
            await nameMindmapCampaigns(instance)
        }
    }
}
