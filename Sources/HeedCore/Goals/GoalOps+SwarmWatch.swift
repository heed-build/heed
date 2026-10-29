import Foundation

/// Watching a running swarm through `GoalOps`: what its live workers used so far, stuck episodes and the ladder they
/// start, reminders of what waits on you, the lead's end-of-build summary, and your repeat rules. Each is a steering
/// row (what a worker used is not: it is the worker's record, kept up to date).
public extension GoalOps {
    // MARK: Use

    /// What a live worker used so far, on its record: a restart does not lose it, and the swarm's dollars count it
    /// while it works. A worker that ended is left as its end wrote it.
    @discardableResult
    func noteWorkerUse(swarm id: String, worker workerID: String, use: SwarmUsageRollup.Use) throws -> Bool {
        var swarm = try existing(id)
        guard let index = swarm.workers.firstIndex(where: { $0.id == workerID && $0.isLive }) else { return false }
        if let dollars = use.dollars { swarm.workers[index].costUSD = dollars }
        if use.tokens > 0 { swarm.workers[index].tokens = use.tokens }
        try store.save(swarm)
        return true
    }

    // MARK: Stuck

    /// A worker looks stuck: a `stuck` row by heed with why, and a nudge to it (a message from heed, handed over as any
    /// message is) to note what it tried and take another way.
    @discardableResult
    func nudgeStuck(swarm id: String, task: String, title: String, signal: SwarmStuck.Signal, now: Date) throws
        -> SwarmSteer
    {
        let swarm = try active(id)
        let row = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .stuck, text: "\(title) looks stuck",
            reason: signal.text, ref: "task:\(task)", step: SwarmStuck.Step.nudge.rawValue
        ))
        _ = try message(
            swarm: id, from: .heed, to: .task(task), text: SwarmStuck.nudge(signal), actor: .heed, now: now
        )
        return row
    }

    /// Still stuck after the nudge: heed asks on the worker's behalf how it should go on. The question climbs the
    /// ladder as any does (a peer at work nearby, then the controller, then you): getting a worker unstuck is a
    /// reversible choice, so the controller may answer it.
    @discardableResult
    func askStuck(
        swarm id: String, task: String, number: String, title: String, signal: SwarmStuck.Signal, now: Date
    ) throws -> SwarmSteer {
        let swarm = try active(id)
        let tasks = try approvedTasks(swarm)
        let peer = SwarmLadder.peer(for: task, tasks: tasks, live: Set(swarm.liveWorkers.map(\.task)))
        let asked = SwarmStuck.question(number: number, title: title, signal: signal)
        let ladder: [SwarmAuthority.Answerer] = (peer == nil ? [] : [.peer]) + [.controller, .you]
        let question = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .question, text: asked.text,
            reason: "a stuck worker: \(SwarmAuthority.Category.implementation.title), the controller may answer it",
            state: .pending, options: asked.options, from: SwarmAddress.task(task).raw,
            to: peer.map { SwarmAddress.task($0).raw }, effects: asked.effects,
            category: SwarmAuthority.Category.implementation.rawValue, ladder: ladder.map(\.rawValue),
            step: ladder.first?.rawValue
        ))
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .stuck, text: "\(title) is still stuck",
            reason: signal.text, about: question.id, ref: "task:\(task)", step: SwarmStuck.Step.ask.rawValue
        ))
        return question
    }

    /// The worker moves again: its episode ends.
    @discardableResult
    func clearStuck(swarm id: String, task: String, title: String, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .stuck, text: "\(title) moves again",
            ref: "task:\(task)", step: SwarmStuck.Step.clear.rawValue
        ))
    }

    /// heed reminded you of a question that waits on you.
    @discardableResult
    func remind(swarm id: String, question: Int64, minutes: Int, now: Date) throws -> SwarmSteer {
        let swarm = try active(id)
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .heed, kind: .remind,
            text: "reminded you: it waits on you for \(minutes) min", about: question
        ))
    }

    // MARK: The summary

    /// The lead's end-of-build summary (`heed swarm summary`): its outcome, decisions and follow-ups. A done swarm
    /// takes it too: that is when it is written. Written again, the newest counts.
    @discardableResult
    func writeSummary(
        swarm id: String, outcome: String?, decisions: [String], followUps: [String], now: Date
    ) throws -> SwarmSteer {
        let swarm = try existing(id)
        let lines = { (lines: [String]) in lines.map(GoalDoc.oneLine).filter { !$0.isEmpty } }
        return try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .lead, kind: .summary,
            text: outcome.map(GoalDoc.oneLine) ?? "", from: SwarmAddress.lead.raw, decisions: lines(decisions),
            followUps: lines(followUps)
        ))
    }

    /// The run's summary kept on it, for the goal's page and History.
    @discardableResult
    func saveSummary(swarm id: String, _ summary: SwarmSummary) throws -> GoalSwarm {
        var swarm = try existing(id)
        guard swarm.summary != summary else { return swarm }
        swarm.summary = summary
        try store.save(swarm)
        return swarm
    }

    /// When the swarm counts a worker as stuck, changed by you: a `limit` row says from what to what.
    @discardableResult
    func setStuck(swarm id: String, _ settings: SwarmStuck.Settings, now: Date) throws -> GoalSwarm {
        var swarm = try active(id)
        let before = swarm.settings.stuck
        guard before != settings else { return swarm }
        swarm.settings.stuck = settings
        try store.save(swarm)
        _ = try store.add(SwarmSteer(
            swarm: id, goal: swarm.goal, at: now, actor: .you, kind: .limit,
            text: "Stuck when: \(before.line) → \(settings.line)"
        ))
        return swarm
    }

    // MARK: Repeat rules

    /// Your repeat rules on the goal, newest first, without the ones you deleted.
    func repeatRules(goal: String) throws -> [SwarmSteer] {
        try SwarmRepeat.rules(store.steering(goal: goal))
    }

    /// A repeat rule deleted: an `unrule` row about it, in the goal's newest swarm run (rows are never removed). The
    /// controller stops answering with it.
    @discardableResult
    func deleteRule(_ rule: Int64, goal: String, now: Date) throws -> SwarmSteer {
        let rows = try store.steering(goal: goal)
        guard let found = rows.first(where: { $0.id == rule && $0.kind == .rule }) else {
            throw GoalOpError.unknownQuestion(rule)
        }
        let swarm = try store.swarms().filter { $0.goal == goal }.max { $0.number < $1.number }?.id ?? found.swarm
        return try store.add(SwarmSteer(
            swarm: swarm, goal: goal, at: now, actor: .you, kind: .unrule,
            text: "deleted the rule: \(found.text) → \(found.answer ?? "")", about: rule
        ))
    }
}
