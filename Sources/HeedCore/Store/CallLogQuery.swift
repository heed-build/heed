import Foundation

/// What the `:log` view filters on, besides `/`: one kind or all, a caller, an agent, and three toggles. Each command
/// of the view changes one of these.
public struct CallLogQuery: Equatable, Sendable {
    public var kind: CallKind?
    public var caller: String?
    public var agent: String?
    public var failedOnly = false
    public var slowOnly = false
    public var githubWritesOnly = false

    public init() {}

    /// All, then each kind in turn (`log.kind`); a kind named sets it, the same kind again goes back to all.
    public mutating func cycleKind(to named: CallKind? = nil) {
        if let named {
            kind = kind == named ? nil : named
            return
        }
        let order: [CallKind?] = [nil] + CallKind.all
        let index = order.firstIndex(of: kind) ?? 0
        kind = order[(index + 1) % order.count]
    }

    /// Only this caller's calls; the same one again shows every caller.
    public mutating func toggleCaller(_ name: String?) {
        caller = name == nil || caller == name ? nil : name
    }

    /// Only this agent's calls; the same one again shows every agent.
    public mutating func toggleAgent(_ name: String?) {
        agent = name == nil || agent == name ? nil : name
    }

    public var isEmpty: Bool { self == CallLogQuery() }

    public func filter(search: String, limit: Int = 500) -> CallFilter {
        var filter = CallFilter()
        if let kind { filter.kinds = [kind] }
        filter.caller = caller
        filter.agent = agent
        filter.failedOnly = failedOnly
        filter.slowOnly = slowOnly
        filter.githubWritesOnly = githubWritesOnly
        filter.search = search
        filter.limit = limit
        return filter
    }
}

public extension CallFilter {
    /// The same test the store's query makes, for rows already in memory (fixtures, shots).
    func matches(_ call: LoggedCall) -> Bool {
        if !kinds.isEmpty, !kinds.contains(call.kind) { return false }
        if let caller, call.caller != caller { return false }
        if let agent, call.agent != agent { return false }
        if failedOnly, !call.failed { return false }
        if slowOnly, call.duration < CallFilter.slow { return false }
        if githubWritesOnly, !(call.kind == .github && call.write) { return false }
        if let since, call.at < since { return false }
        let search = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !search.isEmpty {
            let fields = [call.command, call.caller, call.operation, call.host, call.stderr, call.agent]
            if !fields.contains(where: { $0?.lowercased().contains(search) == true }) { return false }
        }
        return true
    }
}

/// The view's strip: LLM calls and cost per agent today, and GitHub's rate limit as last seen.
public struct CallUsage: Equatable, Sendable {
    public struct Agent: Equatable, Sendable {
        public let name: String
        public let calls: Int
        /// Nil when no call had a cost (none reported, no `[usage.prices]` for its model).
        public let cost: Double?
        /// Some of the cost is an estimate from `[usage.prices]`.
        public let estimated: Bool
    }

    public let agents: [Agent]
    public let rateRemaining: Int?
    public let rateAt: Date?

    public init(llm: [LoggedCall], rateRemaining: Int?, rateAt: Date?) {
        let byAgent = Dictionary(grouping: llm.filter { $0.kind == .llm }) { $0.agent ?? "unknown" }
        agents = byAgent.keys.sorted().map { name in
            let calls = byAgent[name] ?? []
            let costs = calls.compactMap(\.cost)
            return Agent(
                name: name, calls: calls.count, cost: costs.isEmpty ? nil : costs.reduce(0, +),
                estimated: calls.contains { $0.cost != nil && $0.costEstimated }
            )
        }
        self.rateRemaining = rateRemaining
        self.rateAt = rateAt
    }

    /// The same from rows in memory: LLM calls since `since`, the newest rate limit any row saw.
    public init(rows: [LoggedCall], since: Date) {
        let newest = rows.filter { $0.rateRemaining != nil }.max { $0.at < $1.at }
        self.init(
            llm: rows.filter { $0.kind == .llm && $0.at >= since }, rateRemaining: newest?.rateRemaining,
            rateAt: newest?.at
        )
    }

    /// `≈$0.04`, `$0.12`: what an agent cost, marked when estimated.
    public static func money(_ cost: Double, estimated: Bool) -> String {
        (estimated ? "≈" : "") + String(format: cost < 0.1 ? "$%.3f" : "$%.2f", cost)
    }
}
