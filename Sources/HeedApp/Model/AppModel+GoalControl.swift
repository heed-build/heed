import Foundation
import HeedCore

/// `heed goal …` over the control socket: every change through `GoalOps` (`GoalControl`), with the UI's rules;
/// what needs the app (spawning work on an item, asking a reviewer) is done here. Nothing takes focus.
extension AppModel {
    func controlGoal(_ request: ControlRequest) async -> ControlReply {
        guard let command = request.goal else { return .failure("goal needs a command") }
        var asked = request.session.flatMap { id in
            sessions.first { $0.id == id } ?? history.first { $0.id == id }?.session
        }.map(GoalCaller.init)
        // A swarm worker's tab is a pane of the lead's session: the caller is the worker, on its task.
        if let pane = request.pane, let live = liveWorkers.values.first(where: { $0.paneID == pane }) {
            let record = goals.snapshot.swarms.first { $0.id == live.swarm }?.workers.first { $0.id == live.id }
            asked = GoalCaller(
                session: live.sessionID, title: "swarm worker on \(SwarmPlan.short(live.task))",
                repo: record?.repo ?? asked?.repo, worker: live.task
            )
        }
        let caller = asked
        let files = goals.files
        let table = goals.table
        let outcome: GoalControl.Outcome = await withCheckedContinuation { continuation in
            goals.run { ops in
                await GoalControl.run(command, caller: caller, ops: ops, files: files, table: table, now: Clock.now)
            } done: { result in
                continuation.resume(returning: (try? result.get()) ?? .reply(.refused("Goals did not open")))
            }
        }
        switch outcome {
        case let .reply(reply):
            // A waiting `heed goal ask` reads its question every few seconds: that is no news.
            let polling = command.verb == .ask && command.question != nil
            if reply.exit == .ok, reply.outcome != "read", !polling { flash = "goal: \(reply.message)" }
            if reply.exit == .ok { steeringCommandDone(command, reply: reply) }
            return ControlReply(goal: reply)
        case let .app(.spawn(spawn), goal):
            return await ControlReply(goal: requestSpawn(spawn, goal: goal))
        case let .app(.review(goal: _, kind: kind), goal):
            return ControlReply(goal: requestReview(kind, goal: goal, from: GoalControl.from(caller)))
        }
    }

    // MARK: Reviews

    /// `review request <kind>`: the goal's reviewer of that kind looks again, within the day's budget.
    private func requestReview(_ word: String, goal: HeedGoal, from: String) -> GoalReply {
        let live = goals.qualities[goal.id]?.live ?? []
        let key = word.lowercased()
        let chosen = live.filter {
            $0.id == word || $0.config.kind.rawValue == key || $0.config.kind.title.lowercased().hasPrefix(key)
        }
        guard !chosen.isEmpty else {
            let kinds = live.map(\.config.kind.rawValue)
            return .refused(
                "no \(word) reviewer on \(goal.id)"
                    + (kinds.isEmpty ? ": it has none yet" : " (it has \(kinds.joined(separator: ", ")))"),
                goal: goal.id
            )
        }
        guard let plan = runReviewers(goal: goal, trigger: .asked(from), only: Set(chosen.map(\.id))) else {
            return .refused("reviewers do not run here", goal: goal.id)
        }
        if !plan.run.isEmpty {
            return GoalReply(
                "started",
                message: "\(plan.run.count) reviewer\(plan.run.count == 1 ? "" : "s") "
                    + "looking at \(goal.id)",
                goal: goal.id
            )
        }
        if !plan.overBudget.isEmpty {
            return GoalReply(
                "held", exit: .waiting,
                message: "the goal's reviewer runs for today are spent: it waits in Heed's Attention", goal: goal.id
            )
        }
        return GoalReply(
            "quiet", message: "nothing to look at: " + (plan.quiet.values.first ?? "no reviewer ran"), goal: goal.id
        )
    }

    // MARK: Spawning

    /// Whether a spawned session or run still works: an open session not exited or done, a run not finished.
    private func spawnGoing(_ ref: String) -> Bool {
        if ref.hasPrefix("run:") { return goals.spawnRuns.contains(ref) }
        guard let session = sessions.first(where: { $0.id == ref }) else { return false }
        return session.state.state != .exited && session.state.state != .done
    }

    /// `item spawn`: within the goal's cap it starts; past it, it waits for you in Attention.
    private func requestSpawn(_ spawn: GoalSpawn, goal: HeedGoal) async -> GoalReply {
        guard let item = goals.snapshot.item(spawn.item) else { return .refused("no item \(spawn.item)") }
        if isFixture || tutor != nil { return .refused("nothing spawns in the fake world", goal: goal.id) }
        let verdict = GoalSpawnCap.verdict(
            goal: goal.id, evidence: goals.snapshot.evidence(of: goal.id), going: spawnGoing,
            atOnce: config.goals.spawnConcurrent, perDay: config.goals.spawnPerDay, now: Clock.now
        )
        if let reason = verdict.reason {
            goals.hold(GoalHeldSpawn(spawn: spawn, title: item.title, reason: reason, at: Clock.now))
            return GoalReply(
                "held", exit: .waiting,
                message: "\(item.id) waits for you in Heed's Attention: \(reason) (y there starts it)",
                goal: goal.id, item: item.id
            )
        }
        return await startSpawn(spawn, item: item, goal: goal)
    }

    /// Starts a spawn now: a session on the item, or a background run.
    private func startSpawn(_ spawn: GoalSpawn, item: GoalItem, goal: HeedGoal) async -> GoalReply {
        let name = spawn.agent.flatMap { $0.isEmpty ? nil : $0 } ?? settings.defaultAgent
        guard let agent = settings.agent(name) else {
            return .refused("no agent \(name) (\(settings.agents.map(\.name).joined(separator: ", ")))", goal: goal.id)
        }
        guard let records = spawnRepos(spawn, goal: goal), !records.isEmpty else {
            return .refused(
                "no repo on this Mac to start \(item.id) in: spawn from a session on the goal", goal: goal.id
            )
        }
        return spawn.background
            ? await startSpawnRun(spawn, item: item, goal: goal, agent: agent, record: records[0])
            : await startSpawnSession(spawn, item: item, goal: goal, agent: agent, records: records)
    }

    /// Where a spawn works: the asking session's repos, else those of the newest open session on the goal; this Mac's.
    private func spawnRepos(_ spawn: GoalSpawn, goal: HeedGoal) -> [RepoRecord]? {
        let onGoal = goals.snapshot.links(of: goal.id).sorted { $0.at > $1.at }.compactMap { link in
            sessions.first { $0.id == link.target }
        }
        let source = (spawn.caller.flatMap { id in sessions.first { $0.id == id } }).map { [$0] } ?? []
        for session in source + onGoal where !session.repos.isEmpty && session.host == nil {
            let records = session.repos.compactMap { repo in
                repos.first { $0.repo == repo && $0.location.isLocal }
            }
            if !records.isEmpty { return records }
        }
        return nil
    }

    private func spawnPrompt(_ item: GoalItem, goal: HeedGoal) -> String {
        item.workPrompt(goal: goal.title, doc: Paths.tilde(goals.files.doc(goal.id).path))
    }

    /// A session on the item, as Start work makes one: on the goal and the item before its agent starts, so it is
    /// told about the goal at launch; off screen.
    private func startSpawnSession(
        _ spawn: GoalSpawn, item: GoalItem, goal: HeedGoal, agent: AgentProfile, records: [RepoRecord]
    ) async -> GoalReply {
        var plan = StartWorkPlan(
            prompt: spawnPrompt(item, goal: goal), repos: records,
            name: StartWork.branchName(for: item.title, prefixes: settings.prefixes), agent: agent,
            integration: integration
        )
        let id = plan.sessionID
        let now = Clock.now
        let link = GoalLink(
            goal: goal.id, kind: .session, target: id, origin: .manual, item: item.id,
            reason: "spawned by \(spawn.from)", at: now
        )
        let attached: Bool = await withCheckedContinuation { continuation in
            goals.run { ops in
                try await ops.attach(link)
                try await ops.link(item: item.id, GoalItem.Link(.session, id))
                return true
            } done: {
                continuation.resume(returning: (try? $0.get()) == true)
            }
        }
        guard attached else { return .refused("could not put the new session on \(goal.id)", goal: goal.id) }
        applyGoalPointers()
        plan.signOff = settings.signOffArguments(agent: agent, repo: records.first?.repo, session: id)
        let changes: [DomainChange]
        do {
            changes = try await StartWork.execute(plan, settings: settings, hosts: config.hosts)
        } catch {
            goals.run { ops in try await ops.detach(kind: .session, target: id) }
            return .refused("start failed: \(error)", goal: goal.id)
        }
        guard case let .sessionUpserted(session)? = changes.first(where: {
            if case .sessionUpserted = $0 { true } else { false }
        }) else { return .refused("start made no session", goal: goal.id) }
        var panes: [PaneSpec] = []
        for case let .layoutChanged(_, layout) in changes {
            for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                panes.append(pane)
            }
        }
        commit(changes)
        for pane in panes {
            TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
        }
        let evidence = GoalSpawnCap.started(spawn, ref: session.id, title: session.title, now: now)
        goals.run { ops in try await ops.addEvidence(evidence) }
        flash = "\(spawn.from) started \(session.title) on \(goal.title)"
        return GoalReply(
            "started", message: "started \(session.title) (\(session.id)) on \(item.id)", goal: goal.id,
            item: item.id, session: session.id
        )
    }

    /// A background run on the item: its agent headless in a worktree of its own (kept when it ends), told about the
    /// goal like a session; its end is evidence on the item.
    private func startSpawnRun(
        _ spawn: GoalSpawn, item: GoalItem, goal: HeedGoal, agent: AgentProfile, record: RepoRecord
    ) async -> GoalReply {
        let pointer = GoalPointer.text(title: goal.title, path: goals.files.doc(goal.id).path)
        let told = config.goals.tellAgents
            ? GoalLaunch.arguments(agent: agent.name, signOff: nil, pointer: pointer, plugin: integration.plugin)
            : []
        let root = Runs.worktreeRoot(local: settings.worktreeRoot, host: nil, hosts: config.hosts)
        let path = GoalSpawnRun.worktreePath(root: root, repo: record.repo, item: item)
        guard let probe = GoalSpawnRun.headless(
            agent: agent.name, command: agent.command, prompt: "", worktree: path, instructions: told
        ), !probe.isEmpty else {
            return .refused("\(agent.name) runs only in a pane: spawn without --background", goal: goal.id)
        }
        let worktree: String
        do {
            worktree = try await Git.addRunWorktree(
                record, path: path, branch: record.defaultBranch ?? "main", runBranch: GoalSpawnRun.branch(item: item)
            )
        } catch {
            return .refused("could not make its worktree: \(error)", goal: goal.id)
        }
        let words = GoalSpawnRun.headless(
            agent: agent.name, command: agent.command, prompt: spawnPrompt(item, goal: goal), worktree: worktree,
            instructions: told
        ) ?? probe
        let runID = UUID().uuidString.lowercased()
        let ref = "run:\(runID)"
        let now = Clock.now
        let started = GoalSpawnCap.started(spawn, ref: ref, title: GoalSpawnRun.branch(item: item), now: now)
        goals.spawnRuns.insert(ref)
        goals.run { ops in
            try await ops.attach(GoalLink(
                goal: goal.id, kind: .run, target: runID, origin: .manual, item: item.id,
                reason: "spawned by \(spawn.from)", at: now
            ))
            try await ops.link(item: item.id, GoalItem.Link(.run, runID))
            try await ops.addEvidence(started)
        }
        let helpers = Helper.path.map { ($0 as NSString).deletingLastPathComponent }
        Task {
            let (found, pathVariable) = await ToolLocator.shared.executable(words[0])
            let result = try? await ProcessRunner.run(
                found ?? words[0], Array(words.dropFirst()), in: worktree,
                environment: [
                    "PATH": [helpers, pathVariable].compactMap(\.self).joined(separator: ":"),
                    GoalCommandLine.goalVariable: goal.id,
                ],
                timeout: .seconds(Int64(GoalSpawnRun.timeout)), caller: "goals.spawn"
            )
            goals.spawnRuns.remove(ref)
            let ended = GoalEvidence(
                goal: goal.id, item: item.id, kind: .built, state: result?.succeeded == true ? .done : .issue,
                at: Clock.now, source: "run \(runID)",
                text: result.map { $0.succeeded ? "background run finished in \(worktree)"
                    : "background run failed (exit \($0.status)) in \(worktree)"
                }
                    ?? "background run did not finish in \(Int(GoalSpawnRun.timeout / 60)) minutes",
                ref: worktree
            )
            goals.run { ops in try await ops.addEvidence(ended) }
        }
        flash = "\(spawn.from) started a background run on \(item.title)"
        return GoalReply(
            "started", message: "background run on \(item.id) in \(Paths.tilde(worktree)) (branch "
                + "\(GoalSpawnRun.branch(item: item)))", goal: goal.id, item: item.id
        )
    }

    // MARK: Held spawns in Attention

    /// The goal of the spawn ask under Attention's cursor.
    var heldSpawnGoal: String? {
        guard view == .attention, let item = attentionSelected?.item, item.reasons.contains(.goalSpawn) else {
            return nil
        }
        return GoalAttention.goal(of: item)
    }

    /// `y` on a spawn ask: what waits starts now, past the cap (you said so).
    func startHeldSpawns(_ goalID: String) {
        let held = goals.release(goalID)
        guard let goal = goals.snapshot.goal(goalID) else { return }
        Task {
            var started: [String] = []
            for entry in held {
                guard let item = goals.snapshot.item(entry.spawn.item) else { continue }
                let reply = await startSpawn(entry.spawn, item: item, goal: goal)
                started.append(reply.exit == .ok ? item.title : "\(item.title): \(reply.message)")
            }
            say("started " + started.joined(separator: ", "))
        }
    }

    /// `n` on a spawn ask: what waits is dropped.
    func dropHeldSpawns(_ goalID: String) {
        let held = goals.release(goalID)
        say(
            "dropped \(held.count) spawn\(held.count == 1 ? "" : "s") on \(goals.snapshot.goal(goalID)?.title ?? goalID)"
        )
    }
}
