import Foundation

/// What heed knows about how an agent is paid for, from evidence only: Copilot's coding agent comes with GitHub, an
/// agent that reports what its requests cost is paid per use, an agent that ran into a rate-limit window runs on a
/// subscription. Anything else is unknown, and the board shows no plan icon for it.
public enum FleetPlan: String, Hashable, Sendable, Codable {
    case subscription, metered, included, unknown

    /// What a part on it costs beyond what you already pay: nothing on a subscription or included, dollars when
    /// metered, unknown otherwise.
    public var extraIsFree: Bool { self == .subscription || self == .included }

    public var title: String {
        switch self {
        case .subscription: "a subscription: it has rate-limit windows"
        case .metered: "paid per use: it reports what its requests cost"
        case .included: "included with GitHub"
        case .unknown: "heed has not seen how it is paid for"
        }
    }
}

/// How much of an agent's limit is left, and how heed knows. Only what an agent reported: Codex's rate-limit window
/// (its rollout's `used_percent`), or any agent having run into its limit (a reset time ahead). Never invented: an
/// agent heed has nothing on has no quota, and the board draws no ring for it.
public struct FleetQuota: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// Codex's fullest rate-limit window, from its rollout.
        case window
        /// It ran into its limit; the window resets at `resetsAt`.
        case limited
        /// The window it last reported has reset since: it starts empty.
        case reset
    }

    /// 0…1.
    public var left: Double
    public var source: Source
    public var resetsAt: Date?
    /// When the agent reported it.
    public var at: Date

    public init(left: Double, source: Source, resetsAt: Date? = nil, at: Date) {
        self.left = min(max(left, 0), 1)
        self.source = source
        self.resetsAt = resetsAt
        self.at = at
    }

    /// The ring's hover: what it shows and where it comes from.
    public func text(timeZone: TimeZone = .current) -> String {
        let percent = "\(Int((left * 100).rounded()))% left"
        let reset = resetsAt.map { " · resets \(AgentUsage.clock($0, timeZone: timeZone))" } ?? ""
        return switch source {
        case .window: percent + " of its rate-limit window, as its last session reported" + reset
        case .limited: "it hit its limit" + reset
        case .reset: "its rate-limit window reset since it last reported: 100% left"
        }
    }

    /// The quota from an agent's reported usage, newest last: its newest report with a limit in it.
    public static func of(agent _: String, usages: [(at: Date, usage: AgentUsage)], now: Date) -> FleetQuota? {
        for (at, usage) in usages.sorted(by: { $0.at > $1.at }) {
            if let used = usage.rateLimitUsedPercent {
                if let resets = usage.rateLimitResetsAt, resets <= now {
                    return FleetQuota(left: 1, source: .reset, at: at)
                }
                return FleetQuota(left: 1 - used / 100, source: .window, resetsAt: usage.rateLimitResetsAt, at: at)
            }
            if let resets = usage.rateLimitResetsAt {
                guard resets > now else { return nil }
                return FleetQuota(left: 0, source: .limited, resetsAt: resets, at: at)
            }
        }
        return nil
    }
}

/// One of your agents as the Split board's row shows it: who, on which model, how it is paid for, what is left of its
/// limit (when heed knows) and what it used each of the last seven days.
public struct FleetAgent: Hashable, Sendable, Identifiable {
    /// heed's name for it: `claude`, `codex`, `gemini`, `opencode`, `cursor`, or `copilot` (GitHub's coding agent).
    public var id: String
    public var model: String?
    public var plan: FleetPlan
    public var quota: FleetQuota?
    /// Tokens per day, the oldest of the seven days first.
    public var week: [Int]
    /// Its dollars per hour of work, from what it reported (metered agents); nil: unknown.
    public var dollarsPerHour: Double?

    public init(
        id: String, model: String? = nil, plan: FleetPlan = .unknown, quota: FleetQuota? = nil,
        week: [Int] = Array(repeating: 0, count: 7), dollarsPerHour: Double? = nil
    ) {
        self.id = id
        self.model = model
        self.plan = plan
        self.quota = quota
        self.week = week
        self.dollarsPerHour = dollarsPerHour
    }

    /// GitHub's Copilot coding agent: it works on GitHub, from an issue to a PR.
    public var onGitHub: Bool { id == AgentFleet.copilot }

    /// `Claude`, `Copilot agent`.
    public var name: String { AgentFleet.name(id) }

    public var weekTotal: Int { week.reduce(0, +) }
}

/// What heed's records say about an agent in a repo: its PRs there, how many merged, how many it left (abandoned or
/// closed without merging). The fit of an agent for a part reads these.
public struct AgentRecord: Hashable, Sendable {
    public var agent: String
    /// `org/name`.
    public var repo: String
    public var pulls: Int
    public var merged: Int
    public var stalls: Int

    public init(agent: String, repo: String, pulls: Int = 0, merged: Int = 0, stalls: Int = 0) {
        self.agent = agent
        self.repo = repo
        self.pulls = pulls
        self.merged = merged
        self.stalls = stalls
    }
}

public enum AgentFleet {
    public static let copilot = "copilot"
    /// The agents a board knows by name, in the order its rows take.
    public static let order = ["claude", "codex", copilot, "gemini", "cursor", "opencode", "pi"]

    public static func name(_ id: String) -> String {
        switch id {
        case copilot: "Copilot agent"
        case "opencode": "OpenCode"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    /// Rows in board order: known agents first, the rest by name.
    public static func sorted(_ agents: [FleetAgent]) -> [FleetAgent] {
        agents.sorted { one, other in
            let a = order.firstIndex(of: one.id) ?? order.count
            let b = order.firstIndex(of: other.id) ?? order.count
            return a == b ? one.id < other.id : a < b
        }
    }

    /// Each agent's records per repo, from the ledger: a session with PRs counts as one PR's worth of work there; its
    /// outcome says merged, or left (`abandoned`, `closed`).
    public static func records(_ ledger: [LedgerEntry]) -> [AgentRecord] {
        var byKey: [String: AgentRecord] = [:]
        for entry in ledger where !entry.chat {
            for repo in entry.repos {
                let key = entry.agent + " " + repo
                var record = byKey[key] ?? AgentRecord(agent: entry.agent, repo: repo)
                if !entry.pulls.isEmpty { record.pulls += 1 }
                switch entry.outcome {
                case "merged": record.merged += 1
                case "abandoned", "closed": record.stalls += 1
                default: break
                }
                byKey[key] = record
            }
        }
        return byKey.values.sorted { ($0.agent, $0.repo) < ($1.agent, $1.repo) }
    }

    /// Tokens per day over the seven days up to `now` (today last), by agent.
    public static func week(
        _ samples: [(agent: String, at: Date, tokens: Int)], now: Date, calendar: Calendar = .current
    ) -> [String: [Int]] {
        let today = calendar.startOfDay(for: now)
        var result: [String: [Int]] = [:]
        for sample in samples {
            let day = calendar.startOfDay(for: sample.at)
            guard let back = calendar.dateComponents([.day], from: day, to: today).day, (0 ..< 7).contains(back)
            else { continue }
            result[sample.agent, default: Array(repeating: 0, count: 7)][6 - back] += sample.tokens
        }
        return result
    }

    /// How an agent is paid for, from what it reported (`FleetPlan`).
    public static func plan(_ id: String, usages: [AgentUsage]) -> FleetPlan {
        if id == copilot { return .included }
        if usages.contains(where: { $0.rateLimitUsedPercent != nil || $0.rateLimitResetsAt != nil }) {
            return .subscription
        }
        if usages.contains(where: { ($0.costUSD ?? 0) > 0 || ($0.telemetryCostUSD ?? 0) > 0 }) { return .metered }
        return .unknown
    }

    /// The board's agents: those installed (by name, with the model set for them), Copilot's coding agent when the
    /// goal's repos allow it, each with its plan, quota, week and cost from the ledger and live sessions.
    public static func build(
        installed: [String: String?], copilot: Bool, ledger: [LedgerEntry],
        live: [(agent: String, at: Date, usage: AgentUsage)], now: Date, calendar: Calendar = .current
    ) -> [FleetAgent] {
        var usages: [String: [(at: Date, usage: AgentUsage)]] = [:]
        var samples: [(agent: String, at: Date, tokens: Int)] = []
        var dollars: [String: (spent: Double, hours: Double)] = [:]
        for entry in ledger {
            guard let usage = entry.usage else { continue }
            let at = entry.endedAt ?? entry.startedAt
            usages[entry.agent, default: []].append((at, usage))
            samples.append((entry.agent, entry.startedAt, usage.tokens.allInput + usage.tokens.output))
            if let spent = usage.telemetryCostUSD ?? usage.costUSD, let time = entry.agentTime, time > 0 {
                dollars[entry.agent, default: (0, 0)].spent += spent
                dollars[entry.agent, default: (0, 0)].hours += time / 3600
            }
        }
        for sample in live {
            usages[sample.agent, default: []].append((sample.at, sample.usage))
            samples.append((sample.agent, sample.at, sample.usage.tokens.allInput + sample.usage.tokens.output))
        }
        let weeks = week(samples, now: now, calendar: calendar)
        var names = Array(installed.keys)
        if copilot { names.append(Self.copilot) }
        let agents = names.map { id -> FleetAgent in
            let reported = usages[id] ?? []
            let model = installed[id].flatMap(\.self) ?? reported.max { $0.at < $1.at }?.usage.model
                .map { AgentUsage.shortModel($0) }
            let rate = dollars[id].flatMap { $0.hours > 0.25 ? $0.spent / $0.hours : nil }
            return FleetAgent(
                id: id, model: id == Self.copilot ? "on GitHub" : model,
                plan: plan(id, usages: reported.map(\.usage)), quota: FleetQuota.of(
                    agent: id,
                    usages: reported,
                    now: now
                ),
                week: weeks[id] ?? Array(repeating: 0, count: 7), dollarsPerHour: rate
            )
        }
        return sorted(agents)
    }

    /// Agents with spare room this week: they used under a quarter of the busiest agent's tokens (the ⚡ on a row).
    public static func spare(_ agents: [FleetAgent]) -> Set<String> {
        let busiest = agents.map(\.weekTotal).max() ?? 0
        guard busiest > 0 else { return Set(agents.map(\.id)) }
        return Set(agents.filter { Double($0.weekTotal) < Double(busiest) / 4 }.map(\.id))
    }
}
