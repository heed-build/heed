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
        await readUnanswered(entry, session: session)
        await refreshLooseEnds(instance)
        await nameMindmapCampaigns(instance)
        applyGoalBriefs()
    }

    /// Whether a finished session's last message left a question nobody answered: one yes/no for Hunch, once.
    private func readUnanswered(_ entry: LedgerEntry, session: Session?) async {
        guard entry.endedAt != nil, mindmap.unanswered[entry.id] == nil, decisionsOn,
              let message = session?.lastMessage, !message.isEmpty
        else { return }
        let tail = String(message.suffix(1500))
        let answers = try? await decider(caller: "mindmap.loose").decide(
            subject: "mindmap:\(entry.id)", state: tail, questions: ["asks": LooseEnds.questionCheck]
        )
        let asks = (answers?["asks"]?.probability ?? 0) >= MindmapPlace.checkHolds
        let line = tail.split(separator: "\n").last { $0.contains("?") }.map(String.init) ?? "a question"
        mindmap.unanswered[entry.id] = asks ? String(line.prefix(160)) : ""
    }

    /// Every piece of work's loose ends in `instance`, worked out again from what heed knows now.
    func refreshLooseEnds(_ instance: String) async {
        let pulls = Dictionary(github.pulls.map { ($0.ref, $0) }) { first, _ in first }
        let now = Date()
        let entries = ledger.entries
        let unanswered = mindmap.unanswered
        await mindmap.change(instance) { tree in
            for node in tree.nodes.values where node.kind == .work {
                guard let id = node.entry, let entry = entries[id] else { continue }
                let facts = LooseEnds.Facts(
                    pulls: entry.pulls.compactMap { pulls[$0] },
                    unanswered: unanswered[id].flatMap { $0.isEmpty ? nil : $0 }
                )
                var updated = node
                updated.open = LooseEnds.merge(LooseEnds.of(entry, facts: facts, now: now), into: node.open)
                if updated.open != node.open { tree.upsert(updated) }
            }
        }
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

// MARK: The view's commands

extension AppModel {
    func performMindmap(_ command: CommandInvocation) {
        let words = command.arguments
        let now = Date()
        let instance = mindmap.instance
        let node = mindmap.focused
        func change(_ body: @escaping (inout MindmapTree) -> Void) {
            Task { await mindmap.change(instance, body) }
        }
        switch command.name {
        case "mindmap.link.next", "mindmap.link.prev":
            guard let node else { return }
            let links = MindmapLinks.of(node.id, in: mindmap.shown, ledger: ledger.entries)
            guard !links.isEmpty else { return say("nothing linked to \(node.title)") }
            let step = command.name == "mindmap.link.next" ? 0 : links.count - 1
            let target = links[step].target
            mindmap.focus = target
            say("\(links[step].label): \(mindmap.shown[target]?.title ?? target)")
        case "mindmap.in": mindmap.enter()
        case "mindmap.out": mindmap.leave()
        case "mindmap.less": mindmap.changeDepth(by: -1)
        case "mindmap.more": mindmap.changeDepth(by: 1)
        case "mindmap.org.next": mindmap.cycleInstance(by: 1)
        case "mindmap.org.prev": mindmap.cycleInstance(by: -1)
        case "mindmap.accept":
            guard let node, node.suggested else { return say("nothing suggested here") }
            change { $0.accept(node.id, now: now) }
            say("kept where heed put it")
        case "mindmap.done":
            guard let node, let item = mindmap.shown.stillOpen(under: node.id).first else {
                return say("nothing open here")
            }
            let holder = ([node] + mindmap.shown.descendants(of: node.id)).first { $0.stillOpen.contains(item) }
            change { $0.resolve(item.text, in: holder?.id ?? node.id, now: now) }
            say("done: \(item.text)")
        case "mindmap.pin":
            guard let node, let decision = node.decisions.first else { return say("no decision here") }
            change { $0.togglePin(decision.text, in: node.id, now: now) }
        case "mindmap.nest":
            let rows = mindmap.siblings
            let index = mindmap.cursor
            guard let node, rows.indices.contains(index + 1) else { return say("nothing next to it to group with") }
            let id = "group:\(UUID().uuidString.prefix(8).lowercased())"
            change { _ = $0.group([node.id, rows[index + 1].id], title: "New group", id: id, now: now) }
            mindmap.focus = id
            openCommandLine("mindmap.rename ")
        case "mindmap.lift":
            guard let node else { return }
            change { $0.lift(node.id, now: now) }
        case "mindmap.rename":
            guard let node else { return say("no node here") }
            guard !words.isEmpty else { return openCommandLine("mindmap.rename " + node.title) }
            change { $0.rename(node.id, to: words.joined(separator: " "), now: now) }
        case "mindmap.move", "mindmap.join":
            guard let node else { return say("no node here") }
            guard !words.isEmpty else { return openCommandLine(command.name + " ") }
            let title = words.joined(separator: " ")
            if command.name == "mindmap.move", title == "top" {
                change { $0.move(node.id, to: nil, now: now) }
                return
            }
            let target = mindmap.shown.nodes.values.filter { $0.kind != .work && $0.id != node.id }
                .first { $0.title.localizedCaseInsensitiveContains(title) }
            guard let target else { return say("no campaign or group called \(title)") }
            if command.name == "mindmap.move" {
                change { $0.move(node.id, to: target.id, now: now) }
                say("moved into \(target.title)")
            } else {
                change { $0.join(node.id, into: target.id, now: now) }
                mindmap.focus = target.id
                say("joined into \(target.title)")
            }
        case "mindmap.name":
            guard config.llm.enabled else { return say("naming campaigns needs model calls ([llm])") }
            Task { await nameMindmapCampaigns(instance) }
            say("naming campaigns for \(mindmap.shown.unsorted.count) waiting")
        case "mindmap.session":
            guard let node else { return say("no node here") }
            guard !words.isEmpty else { return openCommandLine("mindmap.session ") }
            Task { await startMindmapSession(on: node, prompt: words.joined(separator: " ")) }
        case "mindmap.open":
            guard let entry = node?.entry, ledger.entries[entry] != nil else { return mindmap.enter() }
            view = .ledger
            moveCursor(.ledger, to: entry)
        default: break
        }
    }
}

// MARK: Memory: what sessions are told

extension AppModel {
    /// The brief a session started on `node` is told, from the instance shown; nil when off or there is nothing to say.
    func memoryBrief(on node: MindNode) -> String? {
        guard config.memory.brief != .off else { return nil }
        return MemoryBrief.text(
            for: node.id, in: mindmap.shown, ledger: ledger.entries, instance: mindmap.instance
        )
    }

    /// Sessions on a goal are told the brief of the campaign most of the goal's work sits in, from that work's own
    /// Mindmap.
    func applyGoalBriefs() {
        var briefs: [String: String] = [:]
        if config.memory.brief != .off, config.mindmap.enabled {
            let snapshot = goals.snapshot
            for goal in snapshot.goals where goal.status != .archived {
                let sessions = snapshot.links.filter { $0.goal == goal.id && ($0.kind == .session || $0.kind == .chat) }
                    .map(\.target)
                let entries = sessions.compactMap { ledger.entries[$0] }
                guard let first = entries.first else { continue }
                let instance = mindmap.instance(of: first).instance
                let tree = mindmap.tree(instance)
                guard let campaign = MemoryBrief.campaign(holding: entries.map(\.id), in: tree),
                      let text = MemoryBrief.text(
                          for: campaign.id, in: tree, ledger: ledger.entries, instance: instance
                      )
                else { continue }
                for session in sessions where briefs[session] == nil {
                    briefs[session] = text
                }
            }
        }
        // A session started on a node keeps that node's brief.
        setMemoryBriefs(briefs.merging(mindmap.sessionBriefs) { _, node in node })
    }

    /// `s` in the Mindmap: a new session in the repo of the node's newest work, with the default agent, told the
    /// node's brief at launch.
    func startMindmapSession(on node: MindNode, prompt: String) async {
        let work = mindmap.shown.entries(under: node.id).compactMap { ledger.entries[$0] }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let slug = work.first?.repos.first,
              let record = repos.first(where: { $0.repo.slug == slug && $0.location == .local })
        else { return say("no repo on this Mac for \(node.title)") }
        guard let agent = settings.agent(settings.defaultAgent) else { return say("no default agent") }
        var plan = StartWorkPlan(
            prompt: prompt, repos: [record], name: StartWork.branchName(for: prompt, prefixes: settings.prefixes),
            agent: agent, integration: integration
        )
        let id = plan.sessionID
        mindmap.sessionNodes[id] = (mindmap.instance, node.id)
        if let brief = memoryBrief(on: node) {
            mindmap.sessionBriefs[id] = brief
            applyGoalBriefs()
        }
        plan.signOff = settings.signOffArguments(agent: agent, repo: record.repo, session: id)
        let changes: [DomainChange]
        do {
            changes = try await StartWork.execute(plan, settings: settings, hosts: config.hosts)
        } catch {
            mindmap.sessionBriefs[id] = nil
            applyGoalBriefs()
            return say("start failed: \(error)")
        }
        var panes: [PaneSpec] = []
        for case let .layoutChanged(_, layout) in changes {
            for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                panes.append(pane)
            }
        }
        commit(changes)
        for pane in panes {
            TerminalSurfaces.shared.prepare(pane, sessionID: id)
        }
        say("started a session on \(node.title)" +
            (mindmap.sessionBriefs[id] == nil ? "" : ", told what was decided here"))
    }
}

// MARK: heed memory

extension AppModel {
    /// The Mindmap node a session's memory is read from, and its instance: the node it was started on, else its own
    /// piece of work, else the campaign its goal's work sits in.
    func memoryNode(forSession id: String) -> (instance: String, node: String)? {
        if let started = mindmap.sessionNodes[id] { return started }
        let session = sessions.first { $0.id == id } ?? history.first { $0.id == id }?.session
        let instance: String = if let entry = ledger.entries[id] {
            mindmap.instance(of: entry).instance
        } else if let repo = session?.repos.first {
            MindmapInstance.owner(of: repo.slug, context: mindmap.context)
        } else {
            MindmapInstance.personal
        }
        let tree = mindmap.tree(instance)
        if let work = tree.work(for: id) { return (instance, work.id) }
        let links = goals.snapshot.links
        let onGoals = Set(links.filter { $0.target == id }.map(\.goal))
        let siblings = links.filter { onGoals.contains($0.goal) }.map(\.target)
        guard let campaign = MemoryBrief.campaign(holding: siblings, in: tree) else { return nil }
        return (instance, campaign.id)
    }

    /// `heed memory show|search|note`, from a session's shell: that session's own Mindmap only.
    func controlMemory(_ request: ControlRequest) async -> ControlReply {
        let words = request.arguments ?? []
        guard let session = request.session, let verb = words.first else { return .failure("heed memory: no session") }
        let text = words.dropFirst().joined(separator: " ")
        let found = memoryNode(forSession: session)
        switch verb {
        case "search":
            let instance = found?.instance ?? memoryInstance(forSession: session)
            return ControlReply(memory: MemoryQuery.search(text, in: mindmap.tree(instance), ledger: ledger.entries))
        case "show":
            guard let found else { return ControlReply(memory: "nothing kept for this work yet") }
            return ControlReply(memory: MemoryQuery.show(
                found.node, in: mindmap.tree(found.instance), ledger: ledger.entries, instance: found.instance
            ))
        case "note":
            guard let found else {
                return ControlReply(ok: false, error: "no campaign for this session yet: nothing to keep it on")
            }
            var answer = ""
            await mindmap.change(found.instance) { tree in
                answer = MemoryQuery.note(text, on: found.node, session: session, in: &tree, now: Date())
            }
            return ControlReply(memory: answer)
        default:
            return .failure(MemoryCommandLine.usage)
        }
    }

    private func memoryInstance(forSession id: String) -> String {
        let session = sessions.first { $0.id == id } ?? history.first { $0.id == id }?.session
        return session?.repos.first.map { MindmapInstance.owner(of: $0.slug, context: mindmap.context) }
            ?? MindmapInstance.personal
    }
}
