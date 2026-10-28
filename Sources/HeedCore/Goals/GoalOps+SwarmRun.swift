import Foundation

/// A running swarm through `GoalOps`: its status as the scheduler moves it, its workers starting and ending, your
/// pauses, resumes, swaps and limit answers. Every act is a steering row; nothing here starts an agent (the app does).
public extension GoalOps {
    // MARK: Status

    /// heed moves the run on (`SwarmScheduler.status`): running once workers start, landing once every task has its
    /// PR, paused at a limit (which waits for you). A steering row by heed says so.
    @discardableResult
    func advanceSwarm(_ id: String, to status: GoalSwarm.Status, limit: SwarmLimit? = nil, now: Date) throws
        -> GoalSwarm
    {
        let swarm = try active(id)
        guard swarm.status != status else { return swarm }
        let (kind, text, reason): (SwarmSteer.Kind, String, String?) = switch status {
        case .running where swarm.status == .landing:
            (.start, "Running again: a task has no PR any more", nil)
        case .running: (.start, "Running: workers start on plan v\(swarm.approved ?? swarm.plan)", nil)
        case .landing: (.land, "Landing: every task has its PR", nil)
        case .done:
            (
                .land, "Done: every task merged, in merge order",
                "the swarm ends; the goal stays open until its own done rule holds"
            )
        case .paused:
            (
                .limit, "Paused at \((limit ?? .hours).text(swarm.settings.limits))",
                "nothing more starts until you raise it"
            )
        case .planning, .stopped: (.start, status.rawValue, nil)
        }
        return try setStatus(
            id,
            to: status,
            actor: .heed,
            kind: kind,
            text: text,
            reason: reason,
            limit: limit,
            now: now
        )
    }

    /// You pause the run: nothing more starts; workers at work finish their turn.
    @discardableResult
    func pauseSwarm(_ id: String, now: Date) throws -> GoalSwarm {
        let swarm = try active(id)
        guard swarm.status != .paused else { return swarm }
        return try setStatus(
            id, to: .paused, actor: .you, kind: .pause, text: "Paused swarm \(swarm.number)",
            reason: "nothing more starts; workers at work finish their turn", limit: nil, now: now
        )
    }

    /// You resume the run. Stopped at a limit, resuming raises that limit (`Limits.raised`) first: it is you who
    /// gives it more.
    @discardableResult
    func resumeSwarm(_ id: String, now: Date) throws -> GoalSwarm {
        var swarm = try active(id)
        guard swarm.status == .paused else { return swarm }
        if let limit = swarm.held {
            let before = swarm.settings.limits
            swarm.settings.limits = before.raised(limit)
            try store.save(swarm)
            _ = try store.add(SwarmSteer(
                swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .limit,
                text: "Raised \(limit.rawValue): \(before.line) → \(swarm.settings.limits.line)"
            ))
        }
        return try setStatus(
            id, to: swarm.runningAt == nil ? .planning : .running, actor: .you, kind: .resume,
            text: "Resumed swarm \(swarm.number)", reason: nil, limit: nil, now: now
        )
    }

    /// No to more at a limit: the run stays paused, and stops asking.
    @discardableResult
    func keepPaused(_ id: String, now: Date) throws -> GoalSwarm {
        var swarm = try active(id)
        guard let limit = swarm.held else { return swarm }
        swarm.held = nil
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .limit,
            text: "Kept paused at \(limit.text(swarm.settings.limits))"
        ))
        return swarm
    }

    // MARK: Tasks

    /// You pause a task (its worker stops; nothing restarts it) or resume it (it may start again, even after a worker
    /// that ended without a PR).
    @discardableResult
    func pauseTask(swarm id: String, task: String, title: String, paused: Bool, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: paused ? .pause : .resume,
            text: "\(paused ? "Paused" : "Resumed") \(title)", ref: "task:\(task)"
        ))
    }

    /// The task's agent swapped: the plan's owner changes (a small change, so it stays approved) and a swap row says
    /// from whom to whom. The app hands a working worker's worktree to the new agent.
    @discardableResult
    func swapOwner(swarm id: String, task: String, owner: GoalItem.Owner, now: Date) throws -> SwarmPlanVersion? {
        let swarm = try active(id)
        var tasks = try store.plans(of: id).first { $0.number == swarm.plan }?.tasks ?? []
        guard let index = tasks.firstIndex(where: { $0.id == task }) else { throw GoalOpError.unknownItem(task) }
        let before = tasks[index].owner?.label ?? "nobody"
        tasks[index].owner = owner
        return try changePlan(
            swarm: id, tasks: tasks, kind: .swap, text: "\(tasks[index].title): \(before) → \(owner.label)", now: now
        )
    }

    // MARK: Workers

    /// A worker started: on the run's record, its branch on the item (so its PR is found), evidence that the item is
    /// being built, and a row saying which agent from which base.
    @discardableResult
    func startWorker(swarm id: String, _ worker: SwarmWorker, text: String, now: Date) throws -> GoalSwarm {
        var swarm = try active(id)
        swarm.workers.removeAll { $0.id == worker.id }
        swarm.workers.append(worker)
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .work, text: text, ref: "task:\(worker.task)"
        ))
        if try store.item(worker.task) != nil {
            _ = try link(item: worker.task, GoalItem.Link(.branch, worker.branch))
            _ = try addEvidence(GoalEvidence(
                goal: swarm.goal, item: worker.task, kind: .built, state: .inProgress, at: now,
                source: "swarm \(swarm.number)", text: "\(worker.owner.label) works on it in \(worker.branch)",
                ref: worker.id
            ))
        }
        return swarm
    }

    /// A worker ended: when, how, what it cost. Its worktree and branch stay (they hold the task's work).
    @discardableResult
    func endWorker(
        swarm id: String, worker workerID: String, outcome: SwarmWorker.Outcome, cost: Double?, now: Date
    ) throws -> SwarmWorker? {
        var swarm = try existing(id)
        guard let index = swarm.workers.firstIndex(where: { $0.id == workerID && $0.isLive }) else { return nil }
        swarm.workers[index].endedAt = now
        swarm.workers[index].outcome = outcome
        if let cost { swarm.workers[index].costUSD = cost }
        try store.save(swarm)
        let worker = swarm.workers[index]
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .work,
            text: "\(worker.owner.label) on \(SwarmPlan.short(worker.task)) ended: \(outcome.text)",
            ref: "task:\(worker.task)"
        ))
        if try store.item(worker.task) != nil {
            let state: GoalEvidence.State = switch outcome {
            case .turnOver: .done
            case .stopped, .handedOff: .inProgress
            case .interrupted, .failed: .issue
            }
            _ = try addEvidence(GoalEvidence(
                goal: swarm.goal, item: worker.task, kind: .built, state: state, at: now,
                source: "swarm \(swarm.number)", text: "\(worker.owner.label) ended: \(outcome.text)", ref: worker.id
            ))
        }
        return worker
    }

    // MARK: Landing

    /// A stacked PR went to a new base (`gh pr edit --base`, or GitHub moved it): its newest worker's record says so
    /// (`base`, `stackedOn`) and a row by heed says from where to where and why. The run may have ended meanwhile: the
    /// record follows the PR anyway.
    @discardableResult
    func retargeted(swarm id: String, _ retarget: SwarmLanding.Retarget, now: Date) throws -> GoalSwarm {
        var swarm = try existing(id)
        guard let index = swarm.workers.lastIndex(where: { $0.task == retarget.task }) else {
            throw GoalOpError.unknownItem(retarget.task)
        }
        swarm.workers[index].base = retarget.to
        swarm.workers[index].stackedOn = retarget.stackedOn
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .retarget,
            text: retarget.text + " (was \(retarget.from))",
            reason: retarget.edit ? "its branch is rebased there by a get it green run" : "GitHub had moved it already",
            ref: "task:\(retarget.task)"
        ))
        return swarm
    }

    /// A retarget `gh` refused: a row by heed with why, so the plan pane shows it until `swarm.land` gets it through.
    @discardableResult
    func retargetFailed(swarm id: String, _ retarget: SwarmLanding.Retarget, error: String, now: Date) throws
        -> SwarmSteer
    {
        let swarm = try existing(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .retarget,
            text: "Could not move #\(retarget.pr) to \(retarget.to)", reason: error, ref: "task:\(retarget.task)"
        ))
    }

    /// At launch: workers still recorded as working were cut off when heed quit.
    func interruptWorkers(now: Date) throws {
        for swarm in try store.swarms() where swarm.workers.contains(where: \.isLive) {
            for worker in swarm.liveWorkers {
                try endWorker(swarm: swarm.id, worker: worker.id, outcome: .interrupted, cost: nil, now: now)
            }
        }
    }

    // MARK: Inside

    private func setStatus(
        _ id: String, to status: GoalSwarm.Status, actor: SwarmSteer.Actor, kind: SwarmSteer.Kind, text: String,
        reason: String?, limit: SwarmLimit?, now: Date
    ) throws -> GoalSwarm {
        var swarm = try active(id)
        swarm.status = status
        if status == .running, swarm.runningAt == nil { swarm.runningAt = now }
        if !status.active { swarm.endedAt = now }
        swarm.held = status == .paused ? limit : nil
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: actor, kind: kind, text: text, reason: reason
        ))
        return swarm
    }
}
