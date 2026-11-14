import Foundation

/// Step 6, Go: five choices, each with a default, and what they come to. ⌘↩ turns the split into the swarm's first
/// approved plan (`GoLaunch`); the goal's page takes over from there.
public struct GoChoices: Hashable, Sendable, Codable {
    /// Who works on the parts.
    public enum Who: String, Hashable, Sendable, Codable, CaseIterable {
        /// Agents heed starts over ACP in worktrees of their own: they stop at their done when.
        case helpers
        /// Terminals in the lead's session, which you can type in.
        case sessions
        /// Sessions for the parts on the longest chain (the ones you are likeliest to steer), helpers for the rest.
        case mix

        public var title: String { rawValue }
    }

    /// When heed asks you.
    public enum Ask: String, Hashable, Sendable, Codable, CaseIterable {
        /// When the plan or its scope changes; the controller answers reversible choices.
        case planChanges
        /// Every question an agent asks goes to you.
        case everyQuestion

        public var title: String {
            switch self {
            case .planChanges: "plan changes"
            case .everyQuestion: "every question"
            }
        }
    }

    /// Who merges a part's PR once its checks pass.
    public enum Merge: String, Hashable, Sendable, Codable, CaseIterable {
        case askMe, heed

        public var title: String {
            switch self {
            case .askMe: "ask me"
            case .heed: "heed merges"
            }
        }

        public var swarm: SwarmSettings.Merge { self == .heed ? .heed : .off }
    }

    /// The rows, in order, as `j` `k` move through them.
    public enum Row: String, Hashable, Sendable, CaseIterable {
        case who, atOnce, ask, budget, merge

        public var title: String {
            switch self {
            case .who: "Who works"
            case .atOnce: "At once"
            case .ask: "Ask me"
            case .budget: "Budget"
            case .merge: "Merge"
            }
        }

        public var line: String {
            switch self {
            case .who: "helpers stop at their done when; sessions are terminals you type in"
            case .atOnce: "parts that can run together"
            case .ask: "when the plan changes, or every question"
            case .budget: "pause and ask when reached"
            case .merge: "each part's PR once its checks pass"
            }
        }

        public var symbol: String {
            switch self {
            case .who: "person.2"
            case .atOnce: "square.3.layers.3d"
            case .ask: "questionmark"
            case .budget: "cylinder"
            case .merge: "arrow.triangle.branch"
            }
        }
    }

    public static let atOnceOptions = [2, 3, 5]
    public static let budgetOptions: [Double] = [10, 25, 50]

    public var who: Who
    public var atOnce: Int
    public var ask: Ask
    /// Dollars, beyond what you pay already: the swarm pauses and asks when it reaches it.
    public var budget: Double
    public var merge: Merge

    public init(
        who: Who = .helpers, atOnce: Int = 5, ask: Ask = .planChanges, budget: Double = 25, merge: Merge = .heed
    ) {
        self.who = who
        self.atOnce = max(atOnce, 1)
        self.ask = ask
        self.budget = max(budget, 0)
        self.merge = merge
    }

    /// The defaults for a split: as many at once as the plan can use (of 2, 3 and 5), and $25, or $50 when twice
    /// what it is likely to cost is more.
    public static func defaults(for draft: SplitDraft, extra: Double) -> GoChoices {
        let wide = SplitSchedule.make(draft.parts).maxParallel
        let atOnce = atOnceOptions.first { $0 >= wide } ?? atOnceOptions.last!
        let budget = budgetOptions.first { $0 >= max(extra * 2, 25) } ?? budgetOptions.last!
        return GoChoices(atOnce: atOnce, budget: budget)
    }

    /// The options a row offers, as the segmented control shows them.
    public func options(_ row: Row) -> [String] {
        switch row {
        case .who: Who.allCases.map(\.title)
        case .atOnce: Self.atOnceOptions.map(String.init)
        case .ask: Ask.allCases.map(\.title)
        case .budget: Self.budgetOptions.map { "$\(Int($0))" }
        case .merge: Merge.allCases.map(\.title)
        }
    }

    /// The option picked on a row (0-based); a value off the options (from an older wizard) picks none.
    public func picked(_ row: Row) -> Int? {
        switch row {
        case .who: Who.allCases.firstIndex(of: who)
        case .atOnce: Self.atOnceOptions.firstIndex(of: atOnce)
        case .ask: Ask.allCases.firstIndex(of: ask)
        case .budget: Self.budgetOptions.firstIndex(of: budget)
        case .merge: Merge.allCases.firstIndex(of: merge)
        }
    }

    /// Picks option `index` (0-based) on `row`; out of range does nothing.
    public mutating func pick(_ row: Row, _ index: Int) {
        guard options(row).indices.contains(index) else { return }
        switch row {
        case .who: who = Who.allCases[index]
        case .atOnce: atOnce = Self.atOnceOptions[index]
        case .ask: ask = Ask.allCases[index]
        case .budget: budget = Self.budgetOptions[index]
        case .merge: merge = Merge.allCases[index]
        }
    }

    /// The option before or after on `row`, stopping at the ends.
    public mutating func step(_ row: Row, by delta: Int) {
        let count = options(row).count
        let current = picked(row) ?? 0
        pick(row, min(max(current + delta, 0), count - 1))
    }

    /// Whether the part `id` runs as a helper: all of them (helpers), none (sessions), or those off the longest chain
    /// (mix). A part on GitHub's coding agent is neither: it works on GitHub.
    public func runsAsHelper(_ id: String, chain: [String]) -> Bool {
        switch who {
        case .helpers: true
        case .sessions: false
        case .mix: !chain.contains(id)
        }
    }
}

public extension SplitSchedule {
    /// The most parts that run at the same time anywhere in the schedule.
    var maxParallel: Int {
        var points: [(at: Double, delta: Int)] = []
        for slot in slots.values {
            points.append((slot.start, 1))
            points.append((slot.end, -1))
        }
        // An end before a start at the same hour: parts back to back do not overlap.
        points.sort { lhs, rhs in lhs.at == rhs.at ? lhs.delta < rhs.delta : lhs.at < rhs.at }
        var running = 0
        var most = 0
        for (_, delta) in points {
            running += delta
            most = max(most, running)
        }
        return most
    }
}

/// What Go comes to, for the right side of the step: the parts that start now and on how many agents, how long it
/// takes and when it ends, what it costs beyond what you pay already (against the budget), the PRs and their repos, and
/// the agents with a quota heed knows (their rings).
public struct GoForecast: Hashable, Sendable {
    /// Parts with nothing to wait for, up to `atOnce`.
    public var startNow: Int
    /// The agents those parts are on.
    public var agentsNow: Int
    public var hours: Double
    public var endsAt: Date
    /// The parts' extra (metered agents) plus the reviews the level runs.
    public var extra: Double
    /// Parts on agents whose cost heed cannot tell: the extra is a floor.
    public var unpriced: Int
    public var budget: Double
    /// A PR per part on the board.
    public var pulls: Int
    public var repos: Int
    /// The agents the parts are on, in the board's order.
    public var agents: [FleetAgent]

    public static func of(
        draft: SplitDraft, choices: GoChoices, care: CarePlan?, fleet: [FleetAgent], now: Date
    ) -> GoForecast {
        let schedule = SplitSchedule.make(draft.parts)
        let active = draft.active
        let ready = active.filter { part in part.task.after.allSatisfy { id in !active.contains { $0.id == id } } }
        let now_ = Array(ready.prefix(choices.atOnce))
        // At most `atOnce` at a time: no faster than the hours spread over that many.
        let hours = max(schedule.makespan, schedule.alone / Double(max(choices.atOnce, 1)))
        let stats = SplitStats(draft: draft, schedule: schedule, fleet: fleet)
        let used = Set(active.compactMap(\.agent))
        return GoForecast(
            startNow: now_.count, agentsNow: Set(now_.compactMap(\.agent)).count, hours: hours,
            endsAt: now.addingTimeInterval(hours * 3600),
            extra: stats.extra + (care?.dollars(parts: active.count) ?? 0), unpriced: stats.unpriced,
            budget: choices.budget, pulls: active.count, repos: Set(active.compactMap(\.repoName)).count,
            agents: fleet.filter { used.contains($0.id) }
        )
    }

    /// The extra goes past the budget: the swarm will pause and ask before it ends.
    public var overBudget: Bool { extra > budget }

    /// `Tue 18:40`.
    public static func endText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// `~19 h`, `~2 h 20`.
    public var hoursText: String { "~" + SplitSchedule.text(hours) }
}

/// Go, as the swarm it starts: the settings its form would have had (repos, lead, a worker seat per agent, limits from
/// at once, the time and the budget, how much you are asked, the merge mode, which parts run as helpers and which wait
/// for you, the level), and the split's parts as its first plan, approved.
public struct GoLaunch: Hashable, Sendable {
    public var settings: SwarmSettings
    public var tasks: [SwarmTask]

    /// `repos`: the goal's repos as `org/name`, matched to the parts' repo names; parts' repos not among them are
    /// kept as the parts wrote them. `defaultAgent`: the lead when the split named none.
    public static func of(
        draft: SplitDraft, choices: GoChoices, care: CarePlan, repos: [String], defaultAgent: String
    ) -> GoLaunch {
        let tasks = draft.swarmTasks
        let schedule = SplitSchedule.make(draft.parts)
        var slugs: [String] = []
        for part in draft.active {
            guard let name = part.repo else { continue }
            let slug = repos.first { $0 == name || $0.hasSuffix("/" + name) } ?? name
            if !slugs.contains(slug) { slugs.append(slug) }
        }
        for slug in repos where slugs.isEmpty && !slugs.contains(slug) {
            slugs.append(slug)
        }
        var seats: [SwarmSettings.Worker] = []
        for part in draft.active {
            guard let owner = part.task.owner else { continue }
            if let index = seats.firstIndex(where: { $0.agent == owner.agent }) {
                seats[index].count = min(seats[index].count + 1, choices.atOnce)
            } else {
                seats.append(SwarmSettings.Worker(agent: owner.agent, model: owner.model, effort: owner.effort))
            }
        }
        let hours = max(schedule.makespan, schedule.alone / Double(max(choices.atOnce, 1)))
        var settings = SwarmSettings(
            repos: slugs, lead: draft.lead ?? GoalItem.Owner(agent: defaultAgent), workers: seats,
            limits: SwarmSettings.Limits(
                agents: choices.atOnce, hours: max(1, (hours * 1.5).rounded(.up)), dollars: choices.budget
            ),
            autonomy: .planChanges, merge: choices.merge.swarm
        )
        settings.askEverything = choices.ask == .everyQuestion
        settings.care = care.level
        settings.helpers = draft.active.map(\.id).filter { id in
            draft.part(id)?.agent != AgentFleet.copilot && choices.runsAsHelper(id, chain: schedule.chain)
        }
        settings.waitForYou = draft.active.map(\.id).filter { care.waitsForYou($0, in: draft) }
        return GoLaunch(settings: settings, tasks: tasks)
    }
}
