import Foundation

/// What a swarm used, summed from its workers: the ones that ended as recorded, the live ones as their hooks report now
/// (a live worker's record holds what was persisted last; the live number wins, so nothing counts twice).
public struct SwarmUsageRollup: Hashable, Sendable {
    /// One worker's use: dollars (reported or estimated) and tokens.
    public struct Use: Hashable, Sendable, Codable {
        public var dollars: Double?
        public var tokens: Int

        public init(dollars: Double? = nil, tokens: Int = 0) {
            self.dollars = dollars
            self.tokens = tokens
        }
    }

    public var dollars: Double
    public var tokens: Int
    /// By task (item id).
    public var byTask: [String: Use]
    /// By agent (`claude`, `codex · o4`).
    public var byAgent: [String: Use]
    /// Wall time workers ran, summed (live ones up to `now`).
    public var agentTime: TimeInterval

    /// `live`: a live worker's use by worker id, from its hooks now.
    public static func of(_ swarm: GoalSwarm, live: [String: Use] = [:], now: Date) -> SwarmUsageRollup {
        var rollup = SwarmUsageRollup(dollars: 0, tokens: 0, byTask: [:], byAgent: [:], agentTime: 0)
        for worker in swarm.workers {
            let use = worker.isLive ? live[worker.id] ?? worker.use : worker.use
            rollup.dollars += use.dollars ?? 0
            rollup.tokens += use.tokens
            for key in [worker.task] {
                var task = rollup.byTask[key] ?? Use()
                task.dollars = (task.dollars ?? 0) + (use.dollars ?? 0)
                task.tokens += use.tokens
                rollup.byTask[key] = task
            }
            var agent = rollup.byAgent[worker.owner.label] ?? Use()
            agent.dollars = (agent.dollars ?? 0) + (use.dollars ?? 0)
            agent.tokens += use.tokens
            rollup.byAgent[worker.owner.label] = agent
            rollup.agentTime += max(0, (worker.endedAt ?? now).timeIntervalSince(worker.startedAt))
        }
        return rollup
    }

    /// `1.2M tokens`, `840k tokens`.
    public static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM tokens", Double(count) / 1_000_000)
        case 1000...: "\(count / 1000)k tokens"
        default: "\(count) tokens"
        }
    }

    /// Whether a live worker's use moved enough since it was persisted to be written again: a cent, or 10k tokens.
    public static func worthPersisting(_ now: Use, over stored: Use) -> Bool {
        abs((now.dollars ?? 0) - (stored.dollars ?? 0)) >= 0.01 || now.tokens - stored.tokens >= 10000
    }
}

public extension SwarmWorker {
    /// What it used as its record holds it.
    var use: SwarmUsageRollup.Use { SwarmUsageRollup.Use(dollars: costUSD, tokens: tokens ?? 0) }
}
