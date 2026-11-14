import Foundation
import HeedCore

/// Step 4, Split (`wizardsplit`), and the goal's page with a board (`page.*`): the split call, assignment, the board's
/// cursor and a part's actions, defining a part with its agent over ACP (read-only), and the live board of a goal that
/// builds. The domain is HeedCore's (`SplitDraft`, `SplitAssign`, `SplitSchedule`, `PartDefinition`, `GoalPage`);
/// this gathers inputs, runs calls and the ACP session off the main actor, and saves the wizard after every change.
extension AppModel {
    func performSplit(_ command: CommandInvocation) -> Bool {
        let words = command.arguments
        switch command.name {
        case "split.move": moveSplit(words.first ?? "l")
        case "split.fold": foldSplit()
        case "split.agent": nextAgent(words.first)
        case "split.shift": shiftPart(Int(words.first ?? "") ?? 1)
        case "split.split": splitPart()
        case "split.waits": beginSplitTyping(.waits)
        case "split.size": resizePart()
        case "split.later": putOffPart()
        case "split.note": beginSplitTyping(.note)
        case "split.define": startDefining()
        case "split.balance": balance(words.first)
        case "split.resplit": if let goal = goals.wizard.open { runSplit(goal) }
        case "define.answer": beginSplitTyping(.define)
        case "define.pick": pickDefinition(Int(words.first ?? "") ?? 1)
        case "define.use": useDefinition()
        case "define.later": closeDefinition(keep: true)
        case "define.close": closeDefinition(keep: false)
        case "page.move": movePage(words.first ?? "l")
        case "page.fold": foldPage(words.first == "in")
        case "page.steer": steerPagePart()
        case "page.answer": beginSplitTyping(.nextStep)
        case "page.pick": answerNextStep(option: Int(words.first ?? "") ?? 1)
        default: return false
        }
        updateScope()
        return true
    }

    // MARK: What the board reads

    /// The split on the wizard that shows.
    var openSplit: (goal: String, draft: SplitDraft)? {
        guard let goal = goals.wizard.open, let draft = goals.wizard.current?.split, draft.drafted else { return nil }
        return (goal, draft)
    }

    /// The agents' rows: the agents with parts, in board order; the fleet's entry for each (a bare one when heed has
    /// none, so a part on an agent you no longer have still shows).
    func splitRows(_ draft: SplitDraft) -> [FleetAgent] {
        let used = Set(draft.active.compactMap(\.agent))
        let fleet = goals.wizard.fleet
        let known = fleet.filter { used.contains($0.id) }
        let missing = used.subtracting(known.map(\.id)).map { FleetAgent(id: $0) }
        return AgentFleet.sorted(known + missing)
    }

    func splitNumbers(_ draft: SplitDraft) -> [String: Int] {
        Dictionary(draft.parts.enumerated().map { ($0.element.id, $0.offset + 1) }) { first, _ in first }
    }

    func splitSchedule(_ draft: SplitDraft) -> SplitSchedule {
        SplitSchedule.make(draft.parts, numbers: splitNumbers(draft))
    }

    // MARK: Your agents

    /// Folders an agent keeps its sign-in in: an agent installed without one has never been signed in here.
    static let signInFolders: [String: [String]] = [
        "claude": [".claude"], "codex": [".codex"], "gemini": [".gemini"],
        "opencode": [".local/share/opencode", ".config/opencode"], "cursor": [".cursor"],
    ]

    /// Gathers the board's agents off the main actor: those installed and signed in, Copilot's coding agent when one
    /// of the goal's repos allows it, with what the ledger and live sessions reported. The fake world's are fixed.
    func refreshFleet() {
        if isFixture {
            goals.wizard.fleet = SplitFixtures.fleet(now: Clock.now)
            goals.wizard.records = SplitFixtures.records
            return
        }
        let agents = settings.agents.map { ($0.name, $0.command, $0.model) }
        let ledger = Array(ledger.entries.values)
        let live = sessions.compactMap { session in session.usage.map { (session.agent, session.lastActivity, $0) } }
        let goal = goals.wizard.open
        let slugs = goal.map { goalRepoSlugs($0) } ?? []
        let copilot = repos
            .contains { record in slugs.contains(record.repo.slug) && copilotAvailable(record.repo) == true }
        Task {
            var installed: [String: String?] = [:]
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for (name, command, model) in agents {
                let executable = ACPAgents.words(command).first ?? name
                guard await ToolLocator.shared.executable(executable).path != nil else { continue }
                let folders = Self.signInFolders[name] ?? []
                let signedIn = folders.isEmpty || folders.contains {
                    FileManager.default.fileExists(atPath: "\(home)/\($0)")
                }
                if signedIn { installed[name] = model }
            }
            let fleet = AgentFleet.build(
                installed: installed, copilot: copilot, ledger: ledger, live: live, now: Clock.now
            )
            goals.wizard.fleet = fleet
            goals.wizard.records = AgentFleet.records(ledger)
        }
    }

    /// `org/name` of the repos the goal's planner reads.
    func goalRepoSlugs(_ goal: String) -> [String] {
        let paths = Set(planRepos(goal))
        return repos.filter { paths.contains($0.path) }.map(\.repo.slug)
    }

    // MARK: The split call

    /// Splits the agreed plan and its done-when into parts (a cheap call), then puts each on an agent.
    func runSplit(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), let plan = wizard.plan.current else {
            return say("no plan to split yet")
        }
        if goals.wizard.fleet.isEmpty { refreshFleet() }
        let calls = wizardCalls
        let criteria = wizard.criteria.criteria.map(\.text)
        let slugs = goalRepoSlugs(goal)
        let version = goals.snapshot.goal(goal)?.version
        busy(goal, "splitting the plan into parts")
        Task {
            do {
                var (draft, cost) = try await calls.split(
                    plan: plan, criteria: criteria, repos: slugs, goal: goal, version: version
                )
                draft.lead = draft.lead ?? GoalItem.Owner(agent: settings.defaultAgent, model: PlanTalk.strongest(
                    agent: settings.defaultAgent
                ))
                draft.balance = wizard.split?.balance ?? .credits
                let assigned = SplitAssign.assign(draft, fleet: goals.wizard.fleet, records: goals.wizard.records)
                change(goal) { wizard in
                    wizard.split = assigned
                    wizard.spent(cost)
                }
                goals.wizard.part = nil
                goals.wizard.folded = false
                busy(goal, nil)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// Changes the open split; `reassign` runs assignment after (parts you placed stay).
    func editSplit(reassign: Bool = false, _ edit: (inout SplitDraft) -> Void) {
        guard let (goal, _) = openSplit else { return }
        let fleet = goals.wizard.fleet
        let records = goals.wizard.records
        change(goal) { wizard in
            guard var draft = wizard.split else { return }
            edit(&draft)
            if reassign { draft = SplitAssign.assign(draft, fleet: fleet, records: records) }
            wizard.split = draft
        }
    }

    // MARK: The board's cursor and a part's actions

    func moveSplit(_ direction: String) {
        guard let (_, draft) = openSplit else { return }
        let rows = splitRows(draft).map(\.id)
        goals.wizard.part = SplitCursor.move(
            from: goals.wizard.part, direction, schedule: splitSchedule(draft), rows: rows
        )
    }

    /// The part under the cursor; the first one when there is none yet.
    private func cursorPart() -> SplitPart? {
        guard let (_, draft) = openSplit else { return nil }
        if goals.wizard.part == nil { moveSplit("l") }
        return goals.wizard.part.flatMap(draft.part)
    }

    func foldSplit() {
        guard cursorPart() != nil else { return say("no parts yet") }
        goals.wizard.folded.toggle()
    }

    /// `split.agent [name]`: the part on that agent, or on the next one down the list of who should do it.
    func nextAgent(_ name: String?) {
        guard let (_, draft) = openSplit, let part = cursorPart() else { return }
        let ranked = SplitAssign.candidates(
            for: part, fleet: goals.wizard.fleet, records: goals.wizard.records, draft: draft
        )
        guard !ranked.isEmpty else { return say("heed knows none of your agents yet") }
        let target: FleetAgent? = if let name {
            ranked.first { $0.agent.id == name.lowercased() }?.agent
        } else {
            ranked[((ranked.firstIndex { $0.agent.id == part.agent } ?? -1) + 1) % ranked.count].agent
        }
        guard let target else { return say("no agent \(name ?? "") here") }
        place(part.id, on: target)
    }

    /// `split.shift ±1`: the part on the agent's row below or above (the agents with parts, then the rest).
    func shiftPart(_ delta: Int) {
        guard let (_, draft) = openSplit, let part = cursorPart() else { return }
        let rows = splitRows(draft).map(\.id)
        let order = rows + AgentFleet.sorted(goals.wizard.fleet).map(\.id).filter { !rows.contains($0) }
        guard let index = order.firstIndex(of: part.agent ?? ""), order.indices.contains(index + delta),
              let agent = goals.wizard.fleet.first(where: { $0.id == order[index + delta] })
              ?? (rows.contains(order[index + delta]) ? FleetAgent(id: order[index + delta]) : nil)
        else { return say(delta > 0 ? "no agent below" : "no agent above") }
        place(part.id, on: agent)
    }

    /// Puts a part on an agent by hand (a drop, `a`, `J` `K`): it stays there when assignment runs again.
    func place(_ id: String, on agent: FleetAgent) {
        editSplit { draft in
            draft.update(id) { part in
                part.task.owner = GoalItem.Owner(agent: agent.id, model: agent.onGitHub ? nil : agent.model)
                part.pinned = true
            }
        }
        goals.wizard.part = id
        say("on \(agent.name)")
    }

    func splitPart() {
        guard let (goal, _) = openSplit, let part = cursorPart() else { return }
        let calls = wizardCalls
        let plan = goals.wizard.current?.plan.current
        busy(goal, "splitting \(part.title) in two")
        Task {
            do {
                let (halves, cost) = try await calls.split(part: part, plan: plan, goal: goal)
                editSplit { $0.replace(part.id, with: halves) }
                change(goal) { $0.spent(cost) }
                goals.wizard.part = goals.wizard.current?.split?.parts.first { halves.map(\.id).contains($0.id) }?.id
                    ?? goals.wizard.current?.split?.parts.first { $0.id.hasPrefix(part.id) }?.id
                busy(goal, nil)
            } catch {
                failed(goal, error)
            }
        }
    }

    func resizePart() {
        guard let part = cursorPart() else { return }
        let size = part.size.next
        editSplit { draft in
            draft.update(part.id) { part in
                part.size = size
                part.task.estimate = size.typicalMinutes
            }
        }
        say("\(size.rawValue) · ~\(SplitSchedule.text(Double(size.typicalMinutes) / 60))")
    }

    func putOffPart() {
        guard let part = cursorPart() else { return }
        editSplit { $0.update(part.id) { $0.later.toggle() } }
        goals.wizard.folded = false
        say(part.later ? "\(part.title) is back on the board" : "\(part.title) is put off: p on it brings it back")
    }

    func balance(_ word: String?) {
        guard let (_, draft) = openSplit else { return }
        let next = word.flatMap(SplitBalance.init(rawValue:)) ?? draft.balance.next
        editSplit(reassign: true) { $0.balance = next }
        say("balanced for \(next.title)")
    }

    // MARK: Typing

    func beginSplitTyping(_ kind: WizardBrowser.Typing.Kind) {
        var text = ""
        switch kind {
        case .note:
            guard let part = cursorPart() else { return }
            text = part.note ?? ""
        case .waits:
            guard let (_, draft) = openSplit, let part = cursorPart() else { return }
            let numbers = splitNumbers(draft)
            text = part.task.after.compactMap { numbers[$0].map(String.init) }.joined(separator: " ")
        case .define:
            guard goals.wizard.defining != nil else { return }
        case .nextStep:
            guard let goal = goals.selected, goalPage(goal.id)?.next != nil else { return say("nothing asks you here") }
        default:
            return
        }
        goals.wizard.typing = WizardBrowser.Typing(kind: kind, text: text)
        textInputActive = true
    }

    /// Typing that belongs to Split or the goal's page; false for the wizard's own.
    func submitSplitTyping(_ kind: WizardBrowser.Typing.Kind, _ text: String) -> Bool {
        switch kind {
        case .note:
            guard let part = cursorPart() else { return true }
            editSplit { $0.update(part.id) { $0.note = text.isEmpty ? nil : text } }
        case .waits:
            guard let (_, draft) = openSplit, let part = cursorPart() else { return true }
            let words = text.split { $0 == " " || $0 == "," }.compactMap { Int($0) }
            let ids = words.compactMap { draft.parts.indices.contains($0 - 1) ? draft.parts[$0 - 1].id : nil }
                .filter { $0 != part.id }
            var tasks = draft.parts.map(\.task)
            if let index = tasks.firstIndex(where: { $0.id == part.id }) { tasks[index].after = ids }
            guard SwarmPlan.cycle(tasks) == nil else {
                say("they would wait for each other in a circle")
                return true
            }
            editSplit { $0.update(part.id) { $0.task.after = ids } }
        case .define:
            guard !text.isEmpty, var definition = goals.wizard.defining else { return true }
            definition.say(text)
            goals.wizard.defining = definition
            defineTurn(text)
        case .nextStep:
            guard !text.isEmpty else { return true }
            answerNextStep(text: text)
        default:
            return false
        }
        return true
    }

    // MARK: Defining a part with its agent

    /// `split.define`: an ACP session with the part's agent (else the helpers' agent) in the part's repo that reads
    /// and writes nothing; its first turn reads the repo and asks.
    func startDefining() {
        guard let (goal, draft) = openSplit, let part = cursorPart(), let number = draft.number(of: part.id) else {
            return
        }
        goals.wizard.folded = false
        if let parked = goals.wizard.parkedDefinitions.removeValue(forKey: part.id) {
            goals.wizard.defining = parked
            if !isFixture { connectDefinition(goal: goal, part: part, number: number, draft: draft, resume: true) }
            return
        }
        if isFixture {
            var definition = SplitFixtures.definition(now: Clock.now)
            definition.part = part.id
            definition.agent = part.agent ?? definition.agent
            definition.via = "\(definition.agent) via ACP"
            goals.wizard.defining = definition
            return
        }
        connectDefinition(goal: goal, part: part, number: number, draft: draft, resume: false)
    }

    private func connectDefinition(goal: String, part: SplitPart, number: Int, draft: SplitDraft, resume: Bool) {
        let adapter = part.agent.flatMap(ACPAgents.adapter(for:))
            ?? ACPAgents.chosen(config.helpers, defaultAgent: settings.defaultAgent)
        guard let adapter else { return say("heed knows no ACP way to \(part.agent ?? "the agent"): [helpers] agent") }
        let local = repos.filter(\.location.isLocal)
        let directory = part.repo.flatMap { repo in
            local.first { SplitAssign.same($0.repo.slug, repo) }?.path
        } ?? planRepos(goal).first
        guard let directory else { return say("\(part.repoName ?? "its repo") is not cloned on this Mac") }
        if !resume {
            goals.wizard.defining = PartDefinition(
                part: part.id, agent: adapter.agent, via: adapter.title, at: Clock.now
            )
        }
        let others = draft.active.filter { $0.id != part.id }.compactMap { other in
            draft.number(of: other.id).map { "\($0) \(other.title)" }
        }
        let prompt = PartDefinition.prompt(
            part: part, number: number, goal: goals.snapshot.goal(goal)?.title ?? goal,
            plan: goals.wizard.current?.plan.current,
            criteria: goals.wizard.current?.criteria.criteria.map(\.text) ?? [], others: others
        )
        let history = goals.wizard.defining?.turns.map { ($0.role == .you ? "Developer: " : "You: ") + $0.text } ?? []
        goals.wizard.defineRoot = directory
        goals.wizard.defining?.working = true
        Task {
            let (path, pathVariable) = await ToolLocator.shared.executable(adapter.executable)
            guard let path else {
                return defineFailed("\(adapter.executable) is not installed" +
                    (adapter.install.map { ": \($0)" } ?? ""))
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = pathVariable
            do {
                let transport = try ACPProcessTransport(
                    executable: path, arguments: adapter.arguments, directory: directory, environment: environment
                )
                let client = ACPClient(transport: transport)
                goals.wizard.defineClient = client
                await client.start()
                Task { [weak self] in
                    for await event in client.events {
                        self?.defineEvent(event, client: client)
                    }
                }
                _ = try await client.initialize(clientVersion: appVersion)
                goals.wizard.defineSession = try await client.newSession(cwd: directory)
                defineTurn(resume ? prompt + "\n\n# So far\n" + history.joined(separator: "\n") : prompt)
            } catch {
                defineFailed("\(error)")
            }
        }
    }

    private func defineFailed(_ why: String) {
        goals.wizard.defining?.working = false
        goals.wizard.defining?.problem = why
        say(why)
    }

    /// One turn: the agent's reply is read when it ends.
    func defineTurn(_ text: String) {
        if isFixture {
            goals.wizard.defining?.received(
                "Noted. \n{\"question\": null, \"options\": [], \"doneWhen\": [], \"context\": [\"note: \(text)\"]}"
            )
            return
        }
        guard let client = goals.wizard.defineClient, let session = goals.wizard.defineSession else { return }
        goals.wizard.defineBuffer = ""
        goals.wizard.defining?.working = true
        let started = Clock.now
        Task {
            do {
                _ = try await client.prompt(sessionID: session, text: text)
                let reply = goals.wizard.defineBuffer
                goals.wizard.defining?.received(reply)
                goals.wizard.defining?.working = false
                goals.wizard.defining?.seconds += Clock.now.timeIntervalSince(started)
            } catch {
                defineFailed("\(error)")
            }
        }
    }

    private func defineEvent(_ event: ACPEvent, client: ACPClient) {
        switch event {
        case let .update(_, update):
            switch update {
            case let .agentMessage(chunk): goals.wizard.defineBuffer += chunk
            case let .toolCall(call), let .toolCallUpdate(call):
                if [.read, .search].contains(call.kind ?? .other), let paths = call.paths, !paths.isEmpty {
                    goals.wizard.definePaths += paths
                    goals.wizard.defining?.reads = PartDefinition.reads(
                        goals.wizard.definePaths, root: goals.wizard.defineRoot
                    )
                }
            case let .usage(_, _, cost, _): if let cost { goals.wizard.defining?.cost = cost }
            default: break
            }
        case let .permission(requestID, _, request):
            // Reading goes ahead; anything that would change something is refused (DefinePolicy).
            Task { await client.answerPermission(requestID, optionID: DefinePolicy.answer(request)) }
        case let .closed(reason):
            if goals.wizard.defineClient === client, goals.wizard.defining?.working == true {
                defineFailed("the agent exited" + (reason.map { ": \($0)" } ?? ""))
            }
        }
    }

    func pickDefinition(_ number: Int) {
        guard var definition = goals.wizard.defining, let answer = definition.pick(number - 1) else {
            return say("no option \(number)")
        }
        goals.wizard.defining = definition
        defineTurn(answer)
    }

    /// `define.use`: the part takes the definition (done when added to, estimate, context); the session ends.
    func useDefinition() {
        guard let definition = goals.wizard.defining, let draft = definition.draft else {
            return say("nothing defined yet: answer its question first")
        }
        editSplit { split in
            split.update(definition.part) { part in part = PartDefinition.apply(draft, to: part) }
        }
        closeDefinition(keep: false)
        say("part defined")
    }

    func closeDefinition(keep: Bool) {
        guard let definition = goals.wizard.defining else { return }
        if keep { goals.wizard.parkedDefinitions[definition.part] = definition }
        goals.wizard.defining = nil
        goals.wizard.defineSession = nil
        goals.wizard.definePaths = []
        if let client = goals.wizard.defineClient {
            goals.wizard.defineClient = nil
            Task { await client.close() }
        }
        if keep { say("put off: d on the part comes back to it") }
    }

    // MARK: The goal's page

    /// The goal's page with a board: for a goal split in the wizard, or one whose swarm has an approved plan. Nil
    /// keeps the overview as it was.
    func goalPage(_ goal: String) -> GoalPage? {
        if isFixture, goal == SplitFixtures.complexID,
           goals.wizard.wizard(of: goal)?.finished == true
        {
            return SplitFixtures.page(now: Clock.now)
        }
        let wizard = goals.wizard.wizard(of: goal)
        let board = goals.board.flatMap { $0.swarm.goal == goal ? $0 : nil }
        var draft: SplitDraft
        if let split = wizard?.split, split.drafted, wizard?.completed.contains(.split) == true {
            draft = split
        } else if let board, !runTasks(board).isEmpty {
            draft = SplitDraft(parts: GoalPage.parts(runTasks(board), workers: board.swarm.workers))
            draft.lead = board.swarm.settings.lead
        } else {
            return nil
        }
        var states: [String: PartState] = [:]
        if let board {
            let schedule = swarmSchedule(board)
            for part in draft.active {
                let live = liveWorker(on: part.id)
                let map = SwarmMap.state(
                    schedule?.states[part.id], worker: live.flatMap { runStates[$0.paneID] },
                    stuck: stuckSignal(part.id, board: board)?.strong == true
                )
                states[part.id] = PartState.of(
                    schedule?.states[part.id] == nil ? nil : map, startedAt: live?.startedAt, minutes: part.minutes,
                    now: Clock.now
                )
            }
        }
        let numbers = splitNumbers(draft)
        let done = draft.active.count { states[$0.id]?.isDone == true }
        let spent = board.map { SwarmUsageRollup.of($0.swarm, now: Clock.now).dollars }
        return GoalPage(
            draft: draft, states: states, startedAt: board?.swarm.runningAt, now: Clock.now,
            journey: GoalJourney.of(
                wizard: wizard, done: done, total: draft.active.count, swarm: board?.swarm,
                goalDone: goals.snapshot.goal(goal)?.status == .done
            ),
            next: board.flatMap { GoalNextStep.from($0.steering, numbers: numbers) }, spent: spent
        )
    }

    /// Whether the overview under the cursor is a page with a board.
    var pageShows: Bool {
        view == .goals && goals.pane == .overview && goals.wizard.open == nil
            && goals.selected.map { goalPage($0.id) != nil } == true
    }

    func movePage(_ direction: String) {
        guard pageShows, let goal = goals.selected, let page = goalPage(goal.id),
              goals.wizard.pagePart != nil || ["h", "l"].contains(direction)
        else {
            let fallback = ["h": "pane.left", "l": "pane.right", "j": "row.next", "k": "row.prev"][direction]
            if let fallback { perform(CommandInvocation(name: fallback)) }
            return
        }
        let rows = splitRowsOnPage(page).map(\.id)
        goals.wizard.pagePart = SplitCursor.move(
            from: goals.wizard.pagePart, direction, schedule: page.schedule, rows: rows
        )
    }

    func splitRowsOnPage(_ page: GoalPage) -> [FleetAgent] {
        if goals.wizard.fleet.isEmpty, isFixture { refreshFleet() }
        return splitRows(page.draft)
    }

    func foldPage(_ inward: Bool) {
        guard pageShows, goals.wizard.pagePart != nil else {
            if inward { perform(CommandInvocation(name: "overlay.close")) } else {
                perform(CommandInvocation(name: "goal.open"))
            }
            return
        }
        if inward {
            if goals.wizard.pageFolded { goals.wizard.pageFolded = false } else { goals.wizard.pagePart = nil }
        } else {
            goals.wizard.pageFolded.toggle()
        }
    }

    /// `page.steer`: the running part's worker, in its tab (its live helper, where steering happens).
    func steerPagePart() {
        guard let id = goals.wizard.pagePart else { return say("no part here: h l pick one") }
        if isFixture { return say("steering opens its worker; nothing runs in the fake world") }
        guard let live = liveWorker(on: id),
              let index = layouts[live.sessionID]?.tabs.firstIndex(where: { $0.id == live.tabID })
        else { return say("nothing works on it now") }
        select(sessionID: live.sessionID)
        selectTab(index)
    }

    func answerNextStep(option: Int) {
        guard let goal = goals.selected, let next = goalPage(goal.id)?.next,
              next.options.indices.contains(option - 1)
        else { return say("no option \(option)") }
        answerNextStep(text: next.options[option - 1])
    }

    func answerNextStep(text: String) {
        guard let goal = goals.selected, let next = goalPage(goal.id)?.next else { return }
        guard let question = next.question else { return say("answered “\(text)” (the fake world keeps no answers)") }
        answerSwarm([text], question: question)
    }
}

// MARK: The fake world

extension AppModel {
    enum SplitFixture {
        case complex, small, page
    }

    /// Shots: the complex or small goal at Split (a part under the cursor, folded out, or hovered), or the complex
    /// goal's page while it builds.
    func loadSplitFixture(_ variant: SplitFixture, part: String? = nil, folded: Bool = false, hover: String? = nil) {
        guard isFixture else { return }
        let id = variant == .small ? SplitFixtures.smallID : SplitFixtures.complexID
        var wizard = SplitFixtures.wizard(id, now: Clock.now)
        if variant == .page {
            wizard.advance(at: Clock.now)
            wizard.advance(at: Clock.now)
            wizard.advance(at: Clock.now)
        }
        goals.loadWizardFixture(SplitFixtures.goal(id, now: Clock.now), wizard: wizard)
        refreshFleet()
        view = .goals
        goals.point(to: id)
        goals.wizard.resetCursors()
        if variant == .page {
            goals.wizard.open = nil
            goals.show(.overview)
        } else {
            goals.wizard.open = id
            goals.wizard.part = part.map { "\(id)/\($0)" }
            goals.wizard.folded = folded
            goals.wizard.hover = hover.map { "\(id)/\($0)" }
        }
        updateScope()
    }
}
