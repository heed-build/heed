import Foundation

/// When each part runs if every agent does one part at a time, each part starting once what it waits for is done:
/// the board's timeline, the longest chain (◆), the lead's planned moves on its spine, and the numbers in the stats
/// row. Hours from when the goal goes.
public struct SplitSchedule: Hashable, Sendable {
    public struct Slot: Hashable, Sendable {
        public var id: String
        public var agent: String?
        public var start: Double
        public var end: Double

        public var hours: Double { end - start }
    }

    /// What the lead does on its spine.
    public struct LeadMove: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            /// It briefs the agents.
            case start
            /// It checks a part on the longest chain before what waits for it starts.
            case check
            /// It asks you something (a question waiting on you, on the goal's page).
            case ask
            /// Halfway, it re-plans if the work runs late.
            case replan
            /// It reports the goal done.
            case done
        }

        public var at: Double
        public var kind: Kind
        public var label: String
        /// The part it is about, if one.
        public var part: String?
    }

    public var slots: [String: Slot]
    /// When the last part ends.
    public var makespan: Double
    /// Every part's hours, one after another: what one agent alone would take.
    public var alone: Double
    /// The longest chain of parts waiting for each other, first to last (◆ on the board).
    public var chain: [String]
    public var moves: [LeadMove]

    /// The pause between a part and what waits for it, and before an agent's next part (the lead checks, briefs).
    public static let handoff = 0.15
    /// The lead's brief before the first parts start.
    public static let brief = 0.15

    public var agents: [String] { Array(Set(slots.values.compactMap(\.agent))).sorted() }

    /// The schedule of `parts` (those not put off). `numbers` names parts on the lead's moves (`checks 4`).
    public static func make(_ parts: [SplitPart], numbers: [String: Int] = [:]) -> SplitSchedule {
        let parts = parts.filter { !$0.later }
        let byID = Dictionary(parts.map { ($0.id, $0) }) { first, _ in first }
        let order = SwarmPlan.order(parts.map(\.task))?.compactMap { byID[$0.id] } ?? parts
        var slots: [String: Slot] = [:]
        var free: [String: Double] = [:]
        for part in order {
            let after = part.task.after.compactMap { slots[$0]?.end }.max().map { $0 + handoff }
            let agentFree = part.agent.flatMap { free[$0] }.map { $0 + handoff }
            let start = max(brief, after ?? 0, agentFree ?? 0)
            let slot = Slot(id: part.id, agent: part.agent, start: start, end: start + part.hours)
            slots[part.id] = slot
            if let agent = part.agent { free[agent] = slot.end }
        }
        let makespan = slots.values.map(\.end).max() ?? 0
        let chain = longestChain(parts)
        var schedule = SplitSchedule(
            slots: slots, makespan: makespan, alone: parts.reduce(0) { $0 + $1.hours }, chain: chain, moves: []
        )
        schedule.moves = leadMoves(schedule, numbers: numbers)
        return schedule
    }

    /// The longest chain by hours through what parts wait for, first part first. Ties go to the earlier part in plan
    /// order, so the same plan always marks the same chain.
    public static func longestChain(_ parts: [SplitPart]) -> [String] {
        let parts = parts.filter { !$0.later }
        let byID = Dictionary(parts.map { ($0.id, $0) }) { first, _ in first }
        guard let order = SwarmPlan.order(parts.map(\.task)) else { return [] }
        var length: [String: Double] = [:]
        var previous: [String: String] = [:]
        for task in order {
            guard let part = byID[task.id] else { continue }
            var best: (String, Double)?
            for dep in part.task.after {
                guard let value = length[dep] else { continue }
                if best == nil || value > best!.1 { best = (dep, value) }
            }
            length[part.id] = part.hours + (best?.1 ?? 0)
            if let best { previous[part.id] = best.0 }
        }
        var end: String?
        for part in parts {
            guard let value = length[part.id] else { continue }
            if end == nil || value > length[end!]! + 1e-9 { end = part.id }
        }
        var chain: [String] = []
        var cursor = end
        while let id = cursor {
            chain.insert(id, at: 0)
            cursor = previous[id]
        }
        return chain
    }

    /// The lead's planned moves: it briefs at the start, checks each part on the longest chain as it ends (the last
    /// one excepted: reporting done covers it), re-plans halfway on a goal of eight parts or more, and reports done.
    public static func leadMoves(_ schedule: SplitSchedule, numbers: [String: Int]) -> [LeadMove] {
        guard schedule.makespan > 0 else { return [] }
        func name(_ id: String) -> String { numbers[id].map(String.init) ?? SwarmPlan.short(id) }
        var moves = [LeadMove(at: 0, kind: .start, label: "briefs the agents")]
        for id in schedule.chain.dropLast() {
            guard let slot = schedule.slots[id] else { continue }
            moves.append(LeadMove(at: slot.end + handoff / 2, kind: .check, label: "checks part \(name(id))", part: id))
        }
        if schedule.slots.count >= 8 {
            moves.append(LeadMove(at: schedule.makespan / 2, kind: .replan, label: "re-plans if it runs late"))
        }
        moves.append(LeadMove(at: schedule.makespan + 0.1, kind: .done, label: "reports done"))
        return moves.sorted { $0.at < $1.at }
    }

    /// The lead is light on a small goal: it briefs, checks and reports, little else.
    public var leadIsLight: Bool { slots.count <= 4 }

    /// `19 h`, `2 h 20`, `35 m`.
    public static func text(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "\(minutes) m" }
        let whole = minutes / 60
        let rest = minutes % 60
        if whole >= 10 || rest == 0 { return "\(Int(hours.rounded())) h" }
        return "\(whole) h \(rest < 10 ? "0" : "")\(rest)"
    }
}

/// The numbers on top of the board: parts, agents, hours together, extra spend, and the hours alone, struck through.
public struct SplitStats: Hashable, Sendable {
    public var parts: Int
    public var agents: Int
    public var together: Double
    public var alone: Double
    /// Dollars beyond what you pay already, from the agents whose rate heed knows.
    public var extra: Double
    /// Parts on agents whose cost heed cannot tell: the extra is a floor.
    public var unpriced: Int

    public init(draft: SplitDraft, schedule: SplitSchedule, fleet: [FleetAgent]) {
        let active = draft.active
        parts = active.count
        agents = Set(active.compactMap(\.agent)).count
        together = schedule.makespan
        alone = schedule.alone
        var extra = 0.0
        var unpriced = 0
        for part in active {
            guard let agent = fleet.first(where: { $0.id == part.agent }) else { continue }
            if let dollars = SplitAssign.extra(part, on: agent) { extra += dollars } else { unpriced += 1 }
        }
        self.extra = extra
        self.unpriced = unpriced
    }

    /// `$3`, `$0`, `$2.10`; `≥` when some parts could not be priced.
    public var extraText: String {
        (unpriced > 0 ? "≥" : "") + (extra == 0 ? "$0" : AgentUsage.dollars(extra))
    }
}
