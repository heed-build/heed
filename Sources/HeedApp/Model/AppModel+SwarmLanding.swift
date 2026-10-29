import Foundation
import HeedCore

/// A swarm PR as every row it shows on sees it: which swarm, its place in the merge order, why it is held.
struct SwarmPull: Hashable {
    var ref: PullRef
    var swarm: String
    var number: Int
    var goal: String
    var task: String
    var position: Int
    /// `2/4 · after #412`.
    var label: String
    /// Why it may not merge yet (`SwarmLanding.hold`); nil when the swarm does not hold it.
    var hold: String?
    /// The swarm's get it merged setting, which its PRs follow (`SwarmSettings.Merge`).
    var merge: SwarmSettings.Merge = .repo
}

/// A task's worker taken back to its PR: who, the PR, the items it gets, the few words that say what, and what to do
/// once it started (mark the items sent).
struct WorkerReturn {
    var owner: GoalItem.Owner
    var ref: PullRef
    var items: [FeedbackItem]
    var what: String
    var started: @MainActor () -> Void
}

/// Landing swarms (`SwarmLanding`): the merge order on every row a swarm PR shows on and in the merge queue, a PR held
/// while what it waits for is unmerged, a stacked PR moved to where its parent merged and rebased there by a get it
/// green run, and the run done once every task merged. heed never merges here: each PR's get it merged setting does.
extension AppModel {
    // MARK: Reading

    /// The swarm's facts as the schedule and the landing read them: the PRs gh knows (with the pilot's details, for
    /// its green verdict), the evidence, the live workers' states.
    func swarmFacts(_ board: SwarmBoard, tasks: [SwarmTask]) -> [String: SwarmTaskFacts] {
        let swarm = board.swarm
        return SwarmFacts.build(
            swarm: swarm, tasks: tasks, items: goals.snapshot.items(of: swarm.goal),
            evidence: goals.snapshot.evidence(of: swarm.goal), steering: board.steering,
            pulls: github.pulls + goals.fixturePulls, states: swarmWorkerStates(), details: pullDetails
        )
    }

    /// The merge order's rows for a run (the plan pane's merge order).
    func landingRows(_ board: SwarmBoard) -> [SwarmLanding.Row] {
        let tasks = runTasks(board)
        guard !tasks.isEmpty else { return [] }
        return SwarmLanding.rows(tasks, swarm: board.swarm, facts: swarmFacts(board, tasks: tasks))
    }

    /// Every swarm PR in merge order, swarm by swarm: what a merge queue run follows.
    var swarmMergeOrder: [PullRef] {
        swarmPulls.values.sorted { ($0.swarm, $0.position) < ($1.swarm, $1.position) }.map(\.ref)
    }

    /// The swarm PRs again, from the boards last read: on each tick, and when the fake world lays a run down. A done
    /// run's PRs keep their place until they merged or closed (`SwarmLanding.labelled`).
    func refreshSwarmPulls() {
        var next: [String: SwarmPull] = [:]
        for swarm in goals.snapshot.swarms where swarm.status != .stopped && swarm.approved != nil {
            guard var board = goals.boards[swarm.id] else { continue }
            board.swarm = swarm
            let tasks = runTasks(board)
            guard !tasks.isEmpty else { continue }
            let facts = swarmFacts(board, tasks: tasks)
            let rows = SwarmLanding.labelled(
                SwarmLanding.rows(tasks, swarm: swarm, facts: facts), status: swarm.status
            ) { row in
                facts[row.slot.task]?.ref.map(isOpen) ?? false
            }
            for row in rows {
                guard let ref = facts[row.slot.task]?.ref else { continue }
                next[ref.description] = SwarmPull(
                    ref: ref, swarm: swarm.id, number: swarm.number, goal: swarm.goal, task: row.slot.task,
                    position: row.slot.position, label: row.label, hold: row.hold, merge: swarm.settings.merge
                )
            }
        }
        if next != swarmPulls { swarmPulls = next }
    }

    /// Done runs' boards, read once: their PRs keep their merge-order labels until they merged or closed.
    func loadDoneSwarmBoards() async {
        guard let ops = goals.ops else { return }
        for swarm in goals.snapshot.swarms where swarm.status == .done && goals.boards[swarm.id] == nil {
            if let board = try? await ops.board(of: swarm.id) { goals.boards[swarm.id] = board }
        }
        refreshSwarmPulls()
    }

    // MARK: Ticking

    /// On a tick: the run's open PRs tracked by the session its workers run in (so the pilot drives them), the
    /// stacked PRs whose parent merged moved on, and the rows' merge order read again.
    func landSwarm(_ board: SwarmBoard) async {
        goals.boards[board.swarm.id] = board
        let tasks = runTasks(board)
        let facts = swarmFacts(board, tasks: tasks)
        for task in tasks {
            guard case .open = facts[task.id]?.pr, let ref = facts[task.id]?.ref else { continue }
            trackSwarmPull(ref, swarm: board.swarm, task: task.id)
        }
        await retarget(board, tasks: tasks, facts: facts, only: nil, byHand: false)
        refreshSwarmPulls()
    }

    /// A worker's PR (its hook said it opened one, or heed found it on the task's branch) is tracked by the session
    /// its tab is in: the pilot watches it by its repo's settings from there.
    func trackSwarmPull(_ ref: PullRef, swarm: GoalSwarm, task: String) {
        let host = swarm.lastWorker(on: task)?.host ?? swarm.lead
        guard var session = sessions.first(where: { $0.id == host }),
              session.track(ref, because: "swarm \(swarm.number) task \(SwarmPlan.short(task))")
        else { return }
        commit(.sessionUpserted(session))
        logPilot(ref, .watch, "opened by a worker of swarm \(swarm.number)")
        fetchDetail(ref)
    }

    /// Moves each stacked PR whose parent merged: `gh pr edit --base` (unless GitHub moved it already), the worker's
    /// record and a steering row, then a rebase item on its pipeline that a get it green run picks up. A refusal is a
    /// steering row and waits ten minutes, or for `swarm.land`.
    private func retarget(
        _ board: SwarmBoard, tasks: [SwarmTask], facts: [String: SwarmTaskFacts], only: String?, byHand: Bool
    ) async {
        var bases: [String: String] = [:]
        for (task, fact) in facts {
            if let ref = fact.ref, let base = pullDetails[ref.description]?.baseBranch, !base.isEmpty {
                bases[task] = base
            }
        }
        let moves = SwarmLanding.retargets(
            tasks, swarm: board.swarm, facts: facts, bases: bases, defaultBranch: defaultBranch(of: board.swarm)
        )
        let now = Clock.now
        for move in moves where only == nil || move.task == only {
            guard let ref = facts[move.task]?.ref else { continue }
            if !byHand, let failed = landFailures[ref.description], now.timeIntervalSince(failed) < 600 { continue }
            if move.edit, !isFixture {
                do {
                    try await GitHub.retarget(ref, base: move.to, caller: "swarm.land")
                } catch {
                    landFailures[ref.description] = now
                    let text = "\(error)"
                    _ = await goalOp { try await $0.retargetFailed(swarm: board.swarm.id, move, error: text, now: now) }
                    say("swarm \(board.swarm.number): could not move #\(ref.number) to \(move.to): "
                        + "\(keyText(for: "swarm.land", in: "goalplan")) tries again")
                    continue
                }
            }
            landFailures[ref.description] = nil
            _ = await goalOp { try await $0.retargeted(swarm: board.swarm.id, move, now: now) }
            let parent = facts[move.parent]?.ref.flatMap { pullDetails[$0.description]?.headSHA }
            queueRebase(ref, move, past: parent ?? "origin/\(move.from)")
            logPilot(ref, .updated, move.text)
            say("swarm \(board.swarm.number): \(move.text)")
        }
    }

    /// The rebase a retargeted PR needs, on its pipeline as get it green feedback: queued when its get it green is
    /// auto (a run picks it up), else New for you to send. Never twice for the same parent.
    private func queueRebase(_ ref: PullRef, _ move: SwarmLanding.Retarget, past: String) {
        var pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
        _ = pipeline.settle(pilotSettings(for: ref))
        let item = SwarmLanding.rebaseItem(move, past: past, queued: pilot(for: ref).green == .auto)
        guard !pipeline.items.contains(where: { $0.id == item.id }) else { return }
        pipeline.items.append(item)
        commit(.feedbackChanged(pipeline))
        fetchDetail(ref)
        deliver(ref, explicit: false)
    }

    // MARK: Back to the worker

    /// Where a swarm PR's conflict or rebase goes (`SwarmHandback.route`): its task's last worker, unless that worker
    /// is at work, its agent is not set up or is rate limited, its worktree is gone, or the swarm is not running.
    func handbackRoute(_ pull: SwarmPull) -> SwarmHandback.Route {
        guard let swarm = goals.snapshot.swarms.first(where: { $0.id == pull.swarm }) else {
            return .pilot("its swarm is gone")
        }
        // A worker on a host: its worktree is there if the host answers (looked at over ssh before it starts).
        let kept = swarm.lastWorker(on: pull.task).map { worker in
            !goneWorktrees.contains(worker.id) && SwarmPlace.keptWorktree(
                worker, exists: { FileManager.default.fileExists(atPath: $0) },
                problem: { SwarmPlace.problem($0, hosts: config.hosts, statuses: hostStatuses) }
            )
        } ?? false
        return SwarmHandback.route(
            task: pull.task, swarm: swarm, agents: Set(settings.agents.map(\.name)),
            limited: swarmUsage(swarm).limited, worktreeExists: kept, now: Clock.now
        )
    }

    /// The task's worker starts again in its worktree, its agent and model, on a prompt that says what the PR needs
    /// now; the items count as sent to it once it started, and a `handback` row says so.
    func returnToWorker(
        _ ref: PullRef, pull: SwarmPull, worker: SwarmWorker, items: [FeedbackItem], session: String
    ) {
        guard !startingWorkers.contains(pull.task) else { return }
        guard let board = goals.boards[pull.swarm] else {
            return noteHandbackToPilot(pull, items: items, why: "its swarm's board is not read yet")
        }
        let back = WorkerReturn(
            owner: worker.owner, ref: ref, items: items, what: SwarmHandback.what(items, pr: ref.number)
        ) { [weak self] in
            guard let self, var pipeline = feedback[ref.description],
                  var host = sessions.first(where: { $0.id == session })
            else { return }
            markSent(ref, pipeline: &pipeline, session: &host, to: "\(worker.owner.label) (its swarm worker)")
            logPilot(ref, .sent, "back to swarm \(pull.number)'s worker on its task: \(worker.owner.label)")
        }
        let start = SwarmScheduler.Start(task: pull.task, base: worker.base, stackedOn: worker.stackedOn)
        startingWorkers.insert(pull.task)
        Task {
            // On a host: its kept worktree must still be there, or a get it merged run takes the PR after all.
            if let host = worker.location.hostName,
               await SwarmWorktree.existing(worker.worktree, on: worker.location) == nil
            {
                startingWorkers.remove(pull.task)
                goneWorktrees.insert(worker.id)
                noteHandbackToPilot(pull, items: items, why: "its worktree on @\(host) is gone")
                return deliver(ref, explicit: false)
            }
            await startWorker(board, start, back: back)
            startingWorkers.remove(pull.task)
        }
    }

    /// The worker could not take it: a get it merged run does, and a `handback` row says why.
    func noteHandbackToPilot(_ pull: SwarmPull, items: [FeedbackItem], why: String) {
        let what = SwarmHandback.what(SwarmHandback.needs(items), pr: pull.ref.number)
        let now = Clock.now
        goals.run { try await $0.handback(
            swarm: pull.swarm, task: pull.task, what: what, to: nil, reason: why, now: now
        ) } done: { _ in }
        logPilot(pull.ref, .updated, "not back to its swarm worker: \(why)")
    }

    // MARK: You

    /// `swarm.land`: the task under the cursor's PR moved now if its parent merged (again after a refusal), or why
    /// nothing is to do.
    func landTask() {
        guard let board = goals.board, board.swarm.approved != nil else {
            return say(goals.selected.map { "\($0.title) has no swarm with an approved plan" } ?? "no goal here")
        }
        guard let task = goals.selectedTask else { return say("no task here") }
        let tasks = runTasks(board)
        let facts = swarmFacts(board, tasks: tasks)
        let fact = facts[task.id] ?? SwarmTaskFacts()
        let numbers = SwarmPlan.numbers(tasks)
        let prs = SwarmLanding.prs(facts)
        guard case let .open(number, _, _) = fact.pr else {
            return say(fact.merged ? "\(task.title) merged: nothing to move" : "\(task.title) has no open PR to move")
        }
        let moves = SwarmLanding.retargets(
            tasks, swarm: board.swarm, facts: facts, defaultBranch: defaultBranch(of: board.swarm)
        )
        guard moves.contains(where: { $0.task == task.id }) else {
            if let hold = SwarmLanding.hold(task, facts: facts, prs: prs, numbers: numbers) {
                return say("#\(number) stays where it is: \(hold)")
            }
            let base = board.swarm.lastWorker(on: task.id)?.base ?? defaultBranch(of: board.swarm)
            return say("#\(number) goes against \(base) already: nothing to move")
        }
        say("moving #\(number)…")
        Task { await retarget(board, tasks: tasks, facts: facts, only: task.id, byHand: true) }
    }

    /// `swarm.order`: the plan's outline in merge order (dependencies first), or by phase again.
    func toggleMergeOrder() {
        guard goals.board != nil
        else { return say(goals.selected.map { "\($0.title) has no swarm" } ?? "no goal here") }
        if goals.pane != .plan { goals.togglePlan() }
        goals.toggleOrder()
        say(goals.byMergeOrder ? "the plan in merge order: what each task waits for merges first"
            : "the plan by phase")
    }

    /// Why merge now holds back for a swarm PR whose blockers have not merged.
    func swarmHold(_ ref: PullRef) -> String? {
        guard let pull = swarmPulls[ref.description], let hold = pull.hold else { return nil }
        return "#\(ref.number) waits (swarm \(pull.number), \(pull.label)): \(hold)"
    }

    /// The fake world: the swarm PRs' merge order from the run laid down, and the pilot's details for them (the merge
    /// queue and the rows read those), as if heed had fetched them. Nothing runs.
    func loadLandingFixture(_ world: SwarmFixtures.RunningWorld) {
        guard isFixture else { return }
        var changes: [DomainChange] = world.details.map { .pullDetailFetched($0) }
        if let host = world.swarm.workers.last?.host, var session = sessions.first(where: { $0.id == host }) {
            for pull in world.pulls where pull.state == .open {
                session.trackedPRs.removeAll { $0 == pull.ref }
                session.trackedPRs.append(pull.ref)
                var pipeline = feedback[pull.ref.description] ?? PullFeedback(ref: pull.ref)
                pipeline.watching = true
                pipeline.watchSet = true
                pipeline.merge = .auto
                pipeline.mergeSet = true
                pipeline.items += world.feedback[pull.ref.description] ?? []
                changes.append(.feedbackChanged(pipeline))
            }
            changes.append(.sessionUpserted(session))
        }
        commit(changes)
        refreshSwarmPulls()
    }
}
