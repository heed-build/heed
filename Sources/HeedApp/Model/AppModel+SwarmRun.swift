import Foundation
import HeedCore

/// Swarms that run: the scheduler's ready tasks start as workers in tabs of the lead's session (as get it green runs
/// do: their own worktree, hooks, state and usage), the run's status follows its schedule, and you pause, resume,
/// swap and stop. Every decision goes through `GoalOps` and leaves a steering row. A worker's worktree and branch stay
/// when it ends: they hold the task's work and its PR.
extension AppModel {
    // MARK: Reading

    func swarmWorkerStates() -> [String: AgentState] {
        var states: [String: AgentState] = [:]
        for (id, live) in liveWorkers {
            if let state = runStates[live.paneID] { states[id] = state }
        }
        return states
    }

    /// The approved plan's tasks, in outline order: what workers run from.
    func runTasks(_ board: SwarmBoard) -> [SwarmTask] {
        guard let approved = board.swarm.approved, let version = board.version(approved) else { return [] }
        return SwarmPlan.grouped(version.tasks)
    }

    /// The run's schedule as heed sees it now: where every task stands, what starts, the limit it reached. Nil before
    /// a plan is approved.
    func swarmSchedule(_ board: SwarmBoard) -> SwarmScheduler.Schedule? {
        let tasks = runTasks(board)
        guard !tasks.isEmpty else { return nil }
        let swarm = board.swarm
        let facts = swarmFacts(board, tasks: tasks)
        return SwarmScheduler.schedule(
            swarm, tasks: tasks, facts: facts, usage: swarmUsage(swarm), defaultBranch: defaultBranch(of: swarm),
            now: Clock.now
        )
    }

    /// What the run used: its recorded workers' costs plus what the live ones used so far; the agents rate limited
    /// in a session or a worker now.
    func swarmUsage(_ swarm: GoalSwarm) -> SwarmScheduler.Usage {
        var limited = LLMRunner.limits(of: sessions)
        for live in liveWorkers.values where runStates[live.paneID] == .limited {
            limited[live.agent] = live.usage?.rateLimitResetsAt
        }
        var usage = SwarmScheduler.Usage.of(swarm, limited: limited, now: Clock.now)
        // A live worker's record holds what was persisted last: its hooks' number now replaces it, never adds to it.
        usage.dollars = swarmRollup(swarm).dollars
        return usage
    }

    /// The default branch of the swarm's first repo on this Mac.
    func defaultBranch(of swarm: GoalSwarm) -> String {
        swarmRecord(swarm, at: .local)?.defaultBranch ?? "main"
    }

    private func swarmRecord(_ swarm: GoalSwarm, at location: Location) -> RepoRecord? {
        swarm.settings.repos.lazy.compactMap { slug in
            self.repos.first { $0.repo.slug == slug && $0.location == location }
        }.first
    }

    /// The live worker on a task.
    func liveWorker(on task: String) -> LiveWorker? { liveWorkers.values.first { $0.task == task } }

    // MARK: Ticking

    /// Every approved, active swarm's schedule run once: its status moves (running, landing, paused at a limit) and
    /// its ready tasks start. Never in the fake world: nothing starts there.
    func tickSwarms() {
        guard !isFixture, tutor == nil, let ops = goals.ops, !swarmTicking else { return }
        let active = goals.snapshot.swarms.filter { $0.status.active && $0.approved != nil }
        guard !active.isEmpty else { return }
        swarmTicking = true
        Task {
            for run in active {
                guard let board = try? await ops.board(of: run.id) else { continue }
                await tick(board)
            }
            swarmTicking = false
        }
    }

    private func tick(_ board: SwarmBoard) async {
        await landSwarm(board)
        guard let schedule = swarmSchedule(board) else { return }
        let swarm = board.swarm
        if let next = SwarmScheduler.status(swarm, schedule: schedule, tasks: runTasks(board)) {
            let limit = next == .paused ? schedule.limit : nil
            _ = await goalOp { try await $0.advanceSwarm(swarm.id, to: next, limit: limit, now: Clock.now) }
            let title = goals.snapshot.goal(swarm.goal)?.title ?? swarm.goal
            if next == .paused, let limit {
                say("swarm \(swarm.number) on \(title) paused at \(limit.text(swarm.settings.limits)): Needs you asks")
                return
            }
            if next == .done {
                refreshSwarmPulls()
                if let board = try? await goals.ops?.board(of: swarm.id) { await keepSummary(board) }
                say("swarm \(swarm.number) on \(title) is done: every task merged, in merge order")
                return
            }
        }
        for start in schedule.starts where !startingWorkers.contains(start.task) && liveWorker(on: start.task) == nil {
            await startWorker(board, start)
        }
    }

    /// A `GoalOps` call awaited, its snapshot applied.
    func goalOp<T: Sendable>(_ operation: @escaping @Sendable (GoalOps) async throws -> T) async -> T? {
        await withCheckedContinuation { continuation in
            goals.run(operation) { continuation.resume(returning: try? $0.get()) }
        }
    }

    // MARK: Workers

    /// A worker on a task: its own worktree on the task's branch, made from `start.base` (or the one it left, for a
    /// handoff or a resumed task), and a tab in the lead's session running the task's agent on the worker's prompt,
    /// with heed's hooks and the goal's skill. The tab is appended without being selected: nothing takes your focus.
    func startWorker(_ board: SwarmBoard, _ start: SwarmScheduler.Start, handoff: String? = nil) async {
        let swarm = board.swarm
        let tasks = runTasks(board)
        guard let goal = goals.snapshot.goal(swarm.goal), let task = tasks.first(where: { $0.id == start.task })
        else { return }
        startingWorkers.insert(task.id)
        defer { startingWorkers.remove(task.id) }
        let numbers = SwarmPlan.numbers(tasks)
        let number = numbers[task.id] ?? ""
        let owner = task.owner ?? GoalItem.Owner(agent: swarm.settings.team.first ?? swarm.settings.lead.agent)
        let branch = SwarmWork.branch(of: task, goal: goal.id)
        let now = Clock.now
        func fail(_ reason: String) async {
            let worker = SwarmWorker(
                id: UUID().uuidString.lowercased(), task: task.id, owner: owner, host: swarm.lead ?? "",
                repo: swarm.settings.repos.first ?? "", branch: branch, base: start.base, stackedOn: start.stackedOn,
                worktree: "", startedAt: now
            )
            _ = await goalOp { ops in
                try await ops.startWorker(swarm: swarm.id, worker, text: "\(number) \(task.title): no worker", now: now)
                return try await ops.endWorker(
                    swarm: swarm.id, worker: worker.id, outcome: .failed(reason), cost: nil, now: now
                )
            }
            say("swarm \(swarm.number): \(task.title) did not start: \(reason)")
        }
        // The lead's session hosts the workers; else the newest open session on the goal, on this Mac.
        let onGoal = goals.snapshot.links(of: goal.id).filter { $0.kind == .session }.sorted { $0.at > $1.at }
            .map(\.target)
        guard let session = ([swarm.lead].compactMap(\.self) + onGoal).lazy.compactMap({ id in
            self.sessions.first { $0.id == id && $0.host == nil && self.layouts[id] != nil }
        }).first else {
            return await fail("no open session on the goal to hold its tab: reopen the lead's")
        }
        guard let record = swarmRecord(swarm, at: session.location) else {
            return await fail("none of the swarm's repos is on this Mac")
        }
        guard let agent = settings.agent(owner.agent) else { return await fail("no agent \(owner.agent)") }
        let root = Runs.worktreeRoot(local: settings.worktreeRoot, host: nil, hosts: config.hosts)
        let path = SwarmWork.worktreePath(root: root, repo: record.repo, goal: goal.id, slug: task.slug)
        // A task resumed or handed over carries on in the worktree it left; a new one starts from its base.
        let previous = swarm.lastWorker(on: task.id)
        let reuse = FileManager.default.fileExists(atPath: path)
        let base = reuse ? previous?.base ?? start.base : start.base
        let stackedOn = reuse ? previous?.stackedOn : start.stackedOn
        let worktree: String
        if reuse {
            worktree = path
        } else {
            do {
                worktree = try await Git.addRunWorktree(record, path: path, branch: base, runBranch: branch)
            } catch {
                return await fail("could not make its worktree: \(error)")
            }
            await WorktreeInclude.copy(from: record.path, to: worktree, on: record.location)
        }
        let setup = reuse ? [] : settings.setup.commands(for: record.repo) ?? []
        guard var layout = layouts[session.id] else { return await fail("its session is gone") }
        if agent.name == "cursor" {
            try? AgentIntegration.installCursorHooks(worktree: worktree, heed: integration.heedBinary)
        }
        let pointer = GoalPointer.text(title: goal.title, path: goals.files.doc(goal.id).path)
        let told = config.goals.tellAgents
            ? GoalLaunch.arguments(agent: agent.name, signOff: nil, pointer: pointer, plugin: integration.plugin)
            : []
        let prompt = SwarmWork.prompt(
            task: task, number: number, swarm: swarm, goal: goal.title, doc: Paths.tilde(goals.files.doc(goal.id).path),
            branch: branch, base: base,
            stackedOn: stackedOn.map { id in (numbers[id] ?? "", tasks.first { $0.id == id }?.title ?? id) },
            numbers: numbers, handoff: handoff
        )
        let agentSession = UUID().uuidString.lowercased()
        let command = agent.launchCommand(
            prompt: prompt,
            extraArguments: told
                + AgentIntegration.launchArguments(agent: agent, sessionID: agentSession, files: integration),
            environment: AgentIntegration.launchEnvironment(agent: agent, files: integration), model: owner.model
        )
        let title = SwarmWork.title(number: number)
        let pane = PaneSpec(
            role: .helper, title: title, directory: worktree,
            command: WorktreeSetup.paneCommand(setup: setup, then: command, report: true), location: session.location
        )
        let tab = PaneTab(title: title, tree: .leaf(pane))
        layout.tabs.append(tab)
        commit(.layoutChanged(session: session.id, layout))
        let worker = SwarmWorker(
            id: UUID().uuidString.lowercased(), task: task.id, owner: owner, host: session.id,
            repo: record.repo.slug, branch: branch, base: base, stackedOn: stackedOn, worktree: worktree,
            startedAt: now
        )
        liveWorkers[worker.id] = LiveWorker(
            id: worker.id, swarm: swarm.id, goal: goal.id, task: task.id, sessionID: session.id, tabID: tab.id,
            paneID: pane.id, agent: agent.name, worktree: worktree, startedAt: now
        )
        runStates[pane.id] = .working
        workerPanes.insert(pane.id)
        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
        TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
        let from = stackedOn.map { "stacked on \(numbers[$0] ?? SwarmPlan.short($0))'s PR" } ?? "from \(base)"
        let text = "\(number) \(task.title): \(owner.label) " + (handoff.map { "takes over from \($0)" } ?? from)
        _ = await goalOp { try await $0.startWorker(swarm: swarm.id, worker, text: text, now: now) }
        say("swarm \(swarm.number): \(text)")
    }

    /// A worker's hooks: its own state and usage, as a run's. Its turn over (idle after working, or exited) ends it;
    /// asking or blocked shows on its task in the plan.
    func receiveWorker(_ message: HookMessage, pane: String) {
        guard let id = liveWorkers.first(where: { $0.value.paneID == pane })?.key else { return }
        if case let .taskExit(code) = message.kind, code != 0 {
            return endWorker(id, .failed("its setup or its agent did not start"))
        }
        if case let .usage(report) = message.kind {
            liveWorkers[id]?.usage = (liveWorkers[id]?.usage ?? AgentUsage()).applying(report)
            return
        }
        // A tool call: its activity, for the agents pane and the stuck signal.
        if case let .toolCall(call) = message.kind {
            return recordWorkerCall(call, worker: id, at: message.sentAt)
        }
        // Its PR: tracked by the session its tab is in, so the pilot drives it.
        if case let .prAdd(url) = message.kind, let live = liveWorkers[id], let ref = PullRef(url: url),
           let swarm = goals.snapshot.swarms.first(where: { $0.id == live.swarm })
        {
            return trackSwarmPull(ref, swarm: swarm, task: live.task)
        }
        let reported: AgentState? = switch message.kind {
        case let .state(state, _): state
        case .guess: .done
        case .atPrompt: .idle
        default: nil
        }
        guard let state = reported else { return }
        runStates[pane] = state
        if state == .working { liveWorkers[id]?.worked = true }
        if let live = liveWorkers[id], Runs.ended(state, worked: live.worked) {
            // Something waits for it (a message, a peer's question, an answer): its turn goes on once it is handed.
            if workerHasMail(live) {
                Task { await tickSteering() }
                return
            }
            endWorker(id, .turnOver)
        }
    }

    /// Workers whose end hook never comes (cursor, codex): over once they worked and went quiet.
    func readWorkerScreens(now: Date) {
        for (id, live) in liveWorkers {
            guard let text = TerminalSurfaces.shared.visibleText(paneID: live.paneID), live.worked,
                  runStates[live.paneID] == .working, QuietTurn.applies(to: live.agent),
                  quietTurns.isQuiet(
                      pane: live.paneID, text: text, lastHook: lastHookAt[live.paneID], now: now,
                      after: QuietTurn.runAfter
                  )
            else { continue }
            runStates[live.paneID] = .done
            if workerHasMail(live) { continue }
            endWorker(id, .turnOver)
        }
    }

    /// Ends a worker: its tab closed, how it ended and what it cost recorded on the run. Its worktree and branch stay.
    /// Then the schedule runs again: a slot is free.
    func endWorker(_ id: String, _ outcome: SwarmWorker.Outcome, then: (@MainActor () -> Void)? = nil) {
        guard let (live, cost) = closeWorker(id) else { return }
        let now = Clock.now
        goals.run { ops in
            try await ops.endWorker(swarm: live.swarm, worker: id, outcome: outcome, cost: cost, now: now)
        } done: { [weak self] _ in
            if let then { then() } else { self?.tickSwarms() }
        }
    }

    /// The worker's tab closed and its pane let go; what it cost.
    private func closeWorker(_ id: String) -> (LiveWorker, Double?)? {
        guard let live = liveWorkers.removeValue(forKey: id) else { return nil }
        quietTurns.forget(pane: live.paneID)
        forgetHunchReading(pane: live.paneID)
        lastHookAt[live.paneID] = nil
        TerminalSurfaces.shared.close(paneID: live.paneID)
        runStates[live.paneID] = nil
        if var layout = layouts[live.sessionID], let index = layout.tabs.firstIndex(where: { $0.id == live.tabID }) {
            layout.removeTab(at: index)
            commit(.layoutChanged(session: live.sessionID, layout))
        }
        return (live, live.usage.flatMap(config.usage.cost(of:)))
    }

    /// At launch: workers recorded as working were cut off when heed quit (their tabs went with the layouts).
    func interruptSwarmWorkers() {
        guard !isFixture else { return }
        goals.run { ops in try await ops.interruptWorkers(now: Clock.now) } done: { [weak self] _ in
            self?.tickSwarms()
        }
    }

    /// Stops a run's workers, then the run: one op, so their records end before it does.
    func stopSwarmWorkers(_ swarm: GoalSwarm, done: @escaping @MainActor (Result<GoalSwarm, Error>) -> Void) {
        let ended = liveWorkers.values.filter { $0.swarm == swarm.id }.compactMap { closeWorker($0.id) }
            .map { (id: $0.0.id, cost: $0.1) }
        let now = Clock.now
        goals.run { ops in
            for worker in ended {
                try await ops.endWorker(
                    swarm: swarm.id,
                    worker: worker.id,
                    outcome: .stopped,
                    cost: worker.cost,
                    now: now
                )
            }
            return try await ops.stopSwarm(swarm.id, now: now)
        } done: { done($0) }
    }

    // MARK: You

    /// The plan pane's run: the selected goal's active swarm, approved.
    private func runningBoard() -> SwarmBoard? {
        guard let board = goals.board, board.swarm.status.active else {
            say(goals.selected.map { "\($0.title) has no swarm going" } ?? "no goal here")
            return nil
        }
        guard board.swarm.approved != nil else {
            say(
                "the plan is not approved yet: nothing runs (\(keyText(for: "swarm.approve", in: "goalplan")) approves)"
            )
            return nil
        }
        return board
    }

    /// `swarm.pause`: the swarm pauses (nothing more starts; workers at work finish their turn); again, it resumes.
    /// Paused at a limit, resuming raises that limit.
    func toggleSwarmPause() {
        guard let goal = goals.selected else { return say("no goal here") }
        guard let swarm = goals.snapshot.activeSwarm(of: goal.id)
        else { return say("\(goal.title) has no swarm going") }
        let now = Clock.now
        if swarm.status == .paused {
            goals.run { try await $0.resumeSwarm(swarm.id, now: now) } done: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(run):
                    say("swarm \(run.number) resumed" + (run.settings.limits != swarm.settings.limits
                            ? ": limits now \(run.settings.limits.line)" : ""))
                    tickSwarms()
                case let .failure(error): say("\(error)")
                }
            }
        } else {
            goals.run { try await $0.pauseSwarm(swarm.id, now: now) } done: { [weak self] result in
                switch result {
                case .success: self?.say("swarm \(swarm.number) paused: nothing more starts, workers finish their turn")
                case let .failure(error): self?.say("\(error)")
                }
            }
        }
    }

    /// `y` / `n` on a swarm paused at a limit in Needs you: more (the limit raised, it goes on), or it stays paused.
    func answerSwarmAsk(_ goalID: String, yes: Bool) {
        guard let swarm = goals.snapshot.activeSwarm(of: goalID), swarm.status == .paused else {
            return say("that swarm is not paused any more")
        }
        let now = Clock.now
        if yes {
            goals.run { try await $0.resumeSwarm(swarm.id, now: now) } done: { [weak self] result in
                if case let .success(run) = result {
                    self?.say("swarm \(run.number) goes on: limits now \(run.settings.limits.line)")
                    self?.tickSwarms()
                }
            }
        } else {
            goals.run { try await $0.keepPaused(swarm.id, now: now) } done: { [weak self] _ in
                self?.say("swarm \(swarm.number) stays paused: \(self?.keyText(for: "swarm.pause") ?? "") resumes it")
            }
        }
    }

    /// The Attention item's goal, when it is a swarm's limit ask.
    var swarmAskGoal: String? {
        guard view == .attention, let item = attentionSelected?.item, item.reasons.contains(.swarmAsk),
              item.id.hasSuffix(":swarm")
        else {
            return nil
        }
        return GoalAttention.goal(of: item)
    }

    /// `swarm.task.pause`: the task under the cursor pauses (its worker stops, its worktree stays) or, paused or
    /// stalled, resumes (it may start again).
    func toggleTaskPause() {
        guard let board = runningBoard() else { return }
        guard let task = goals.selectedTask else { return say("no task here") }
        let state = swarmSchedule(board)?.states[task.id]?.state
        let resume = state == .paused || state == .stalled
        if !resume, let state, state.landed {
            return say("\(task.title) has its PR: there is nothing to pause")
        }
        let id = board.swarm.id
        let now = Clock.now
        let live = liveWorker(on: task.id)
        let record: @MainActor () -> Void = { [weak self] in
            self?.goals.run { ops in
                try await ops.pauseTask(swarm: id, task: task.id, title: task.title, paused: !resume, now: now)
            } done: { [weak self] _ in
                self?.say("\(resume ? "resumed" : "paused") \(task.title)"
                    + (resume ? "" : live == nil ? "" : ": its worker stopped, its worktree stays"))
                self?.tickSwarms()
            }
        }
        if !resume, let live { return endWorker(live.id, .stopped, then: record) }
        record()
    }

    /// `swarm.task.swap <agent[:model]>`: the task goes to another agent (a small plan change, so it stays approved).
    /// A worker at work stops and the new agent starts in its worktree on a handoff prompt.
    func swapTaskAgent(_ word: String?) {
        guard let board = runningBoard() else { return }
        guard let task = goals.selectedTask else { return say("no task here") }
        guard let word, !word.isEmpty else { return openCommandLine("swarm.task.swap ") }
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        let owner = GoalItem.Owner(agent: parts[0], model: parts.count > 1 ? parts[1] : nil)
        guard settings.agent(owner.agent) != nil else {
            return say("no agent \(owner.agent) (\(settings.agents.map(\.name).joined(separator: ", ")))")
        }
        guard owner != task.owner else { return say("\(task.title) is \(owner.label)'s already") }
        let id = board.swarm.id
        let now = Clock.now
        let live = liveWorker(on: task.id)
        let previous = board.swarm.lastWorker(on: task.id)
        let swap: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            goals.run { ops in
                _ = try await ops.swapOwner(swarm: id, task: task.id, owner: owner, now: now)
                return try await ops.board(of: id)
            } done: { [weak self] result in
                guard let self else { return }
                guard case let .success(fresh) = result else {
                    if case let .failure(error) = result { say("\(error)") }
                    return
                }
                guard live != nil, let previous else {
                    say("\(task.title) goes to \(owner.label)")
                    return tickSwarms()
                }
                Task {
                    await self.startWorker(
                        fresh, SwarmScheduler.Start(task: task.id, base: previous.base, stackedOn: previous.stackedOn),
                        handoff: previous.owner.label
                    )
                }
            }
        }
        if let live { return endWorker(live.id, .handedOff(owner.label), then: swap) }
        swap()
    }

    /// `swarm.task.open`: the task's worker, in its tab.
    func openTaskWorker() {
        guard let task = goals.selectedTask else { return say("no task here") }
        guard let live = liveWorker(on: task.id),
              let index = layouts[live.sessionID]?.tabs.firstIndex(where: { $0.id == live.tabID })
        else { return say("no worker on \(task.title) now") }
        select(sessionID: live.sessionID)
        selectTab(index)
    }

    // MARK: The fake world

    /// The fake world's running swarm (shots, previews): the anchors goal's run with its workers, their states and
    /// the PRs they opened, as if heed had started them. Nothing runs.
    func loadRunningSwarmFixture(_ variant: SwarmFixtures.Running = .running) {
        guard isFixture else { return }
        let fixture = goals.loadRunningFixture(variant)
        for worker in fixture.swarm.liveWorkers {
            let pane = "fixture-worker-\(worker.id)"
            liveWorkers[worker.id] = LiveWorker(
                id: worker.id, swarm: fixture.swarm.id, goal: fixture.swarm.goal, task: worker.task,
                sessionID: worker.host, tabID: "fixture-tab-\(worker.id)", paneID: pane, agent: worker.owner.agent,
                worktree: worker.worktree, startedAt: worker.startedAt, worked: true
            )
            runStates[pane] = SwarmFixtures.workerStates[worker.task] ?? .working
        }
        if variant == .landing || variant == .done || variant == .summary { loadLandingFixture(fixture) }
    }
}
