import Foundation

/// How careful and Go through `GoalOps`: a level applied to the goal's quality record, and Go starting the goal's
/// swarm on the split, approved, running. Nothing here starts an agent: the app starts the lead and the scheduler the
/// workers, as for any swarm.
public extension GoalOps {
    /// A level on the goal: its bars pinned to the level's (`GoalOps.pin`, which spawns what is missing), then the
    /// reviewers the level runs cheap set to the cheap model, and those it does not need taken off. Recorded as any
    /// change to the bars is, so Reviewers shows it and `Q` can change it after.
    @discardableResult
    func applyCare(goal id: String, _ plan: CarePlan, now: Date, table: GoalBarTable = .defaults) throws
        -> GoalQuality
    {
        var quality = try pin(goal: id, plan.pins, now: now, table: table)
        var entries: [QualityEntry] = []
        for state in quality.reviewers where !state.config.removed {
            var config = state.config
            if plan.cheap.contains(config.kind), config.tier == nil {
                config.tier = .cheap
            }
            if let lens = config.kind.lens, (plan.pins[lens] ?? 0) == 0, config.persona == nil,
               config.kind != .custom
            {
                config.removed = true
            }
            if config != state.config { entries.append(.reviewer(config)) }
        }
        if !entries.isEmpty { quality = try record(entries, goal: id, at: now.addingTimeInterval(0.01), table: table) }
        return quality
    }

    /// Go: the level applied, a swarm started with `launch`'s settings (or the goal's swarm still planning, with
    /// nothing approved, taking them), the split as its plan version (by heed, from the wizard), approved and running,
    /// and the wizard finished with the swarm's id. One swarm at a time per goal, as ever.
    @discardableResult
    func go(
        goal id: String, launch: GoLaunch, care: CarePlan, now: Date, table: GoalBarTable = .defaults
    ) throws -> GoalSwarm {
        guard var wizard = try store.wizards()[id] else { throw GoalOpError.unknownGoal(id) }
        // A swarm still planning, with nothing approved (a lead drafting from the old form): Go's split is its plan,
        // with Go's settings. Any other swarm going stops Go, as it stops a second swarm.
        let swarm: GoalSwarm
        if var planning = try activeSwarm(of: id), planning.status == .planning, planning.approved == nil {
            planning.settings = launch.settings
            try store.save(planning)
            swarm = planning
        } else {
            swarm = try startSwarm(goal: id, settings: launch.settings, now: now)
        }
        try applyCare(goal: id, care, now: now, table: table)
        _ = try proposePlan(
            swarm: swarm.id, input: SwarmPlanInput(tasks: launch.tasks, note: "the wizard's split", scope: []),
            actor: .heed, now: now
        )
        try approvePlan(swarm: swarm.id, now: now)
        let running = try advanceSwarm(swarm.id, to: .running, now: now)
        wizard.complete(.careful)
        wizard.complete(.go)
        wizard.step = .go
        wizard.swarm = running.id
        wizard.updatedAt = now
        try store.save(wizard: wizard)
        return running
    }
}
