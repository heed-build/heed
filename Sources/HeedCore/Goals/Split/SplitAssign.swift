import Foundation

/// Who should do a part: each agent's fit for it from heed's records (its PRs in the part's repo, how many merged, how
/// many it left), and the assignment of every part to an agent under Balance for.
public enum SplitAssign {
    /// One agent for one part, as "who should do it" lists it.
    public struct Candidate: Hashable, Sendable, Identifiable {
        public var agent: FleetAgent
        /// 0…1; the board shows it as 0–100.
        public var fit: Double
        /// Its merged PRs in the part's repo.
        public var merged: Int
        /// What the part costs on it beyond what you pay already: 0 on a subscription or included, dollars when its
        /// rate is known, nil when heed cannot tell.
        public var extra: Double?
        /// One reason worth saying: `shares the lead's window`, `PR only`, `already on 1 and 2`.
        public var note: String?

        public var id: String { agent.id }
        public var score: Int { Int((fit * 100).rounded()) }
    }

    /// Whether a record's repo is the part's: the same `org/name`, or the same short name.
    public static func same(_ record: String, _ repo: String) -> Bool {
        if record.caseInsensitiveCompare(repo) == .orderedSame { return true }
        let short = { (text: String) in text.split(separator: "/").last.map(String.init)?.lowercased() ?? text }
        return short(record) == short(repo)
    }

    /// An agent's fit for a part, 0.05…0.99. Its merged share of PRs in the part's repo (from even odds with none),
    /// how many merged there (up to ten), less for PRs it left; an agent new to the repo borrows half its record
    /// elsewhere. Copilot needs a repo to open its PR in; an L part on an agent new to the repo is a little riskier.
    public static func fit(_ part: SplitPart, _ agent: FleetAgent, records: [AgentRecord]) -> Double {
        let own = records.filter { $0.agent == agent.id }
        let here = part.repo.map { repo in own.filter { same($0.repo, repo) } } ?? []
        func score(_ list: [AgentRecord], weight: Double) -> Double {
            let pulls = list.reduce(0) { $0 + $1.pulls }
            let merged = list.reduce(0) { $0 + $1.merged }
            let stalls = list.reduce(0) { $0 + $1.stalls }
            let success = Double(merged + 1) / Double(max(pulls, merged + stalls) + 2)
            let experience = min(Double(merged), 10) / 10
            let left = pulls + stalls == 0 ? 0 : Double(stalls) / Double(pulls + stalls)
            return weight * (0.25 * success + 0.25 * experience - 0.15 * left)
        }
        var fit = 0.45
        if here.contains(where: { $0.pulls + $0.merged + $0.stalls > 0 }) {
            fit += score(here, weight: 1)
        } else {
            fit += score(own, weight: 0.5)
            if part.size == .l { fit -= 0.05 }
        }
        if agent.onGitHub, part.repo == nil { fit *= 0.5 }
        return min(max(fit, 0.05), 0.99)
    }

    /// What a part costs on an agent beyond what you pay.
    public static func extra(_ part: SplitPart, on agent: FleetAgent) -> Double? {
        if agent.plan.extraIsFree { return 0 }
        return agent.dollarsPerHour.map { $0 * part.hours }
    }

    /// Every agent for `part`, best fit first. `draft` names the parts each agent already has; `lead` the lead's agent.
    public static func candidates(
        for part: SplitPart, fleet: [FleetAgent], records: [AgentRecord], draft: SplitDraft
    ) -> [Candidate] {
        fleet.map { agent in
            let mine = draft.active.filter { $0.agent == agent.id && $0.id != part.id }
                .compactMap { draft.number(of: $0.id) }.map(String.init)
            let merged = part.repo.map { repo in
                records.filter { $0.agent == agent.id && same($0.repo, repo) }.reduce(0) { $0 + $1.merged }
            } ?? 0
            var note: String?
            if agent.onGitHub {
                note = "PR only"
            } else if !mine.isEmpty {
                note = "already on " + list(mine)
            } else if agent.id == draft.lead?.agent, agent.plan == .subscription {
                note = "shares the lead's window"
            } else if agent.weekTotal == 0 {
                note = "you haven't used it this week"
            }
            return Candidate(
                agent: agent, fit: fit(part, agent, records: records), merged: merged, extra: extra(part, on: agent),
                note: note
            )
        }
        .sorted { $0.fit == $1.fit ? $0.agent.id < $1.agent.id : $0.fit > $1.fit }
    }

    /// `1`, `1 and 2`, `1, 2 and 5`.
    static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }

    /// Every part on an agent, under `draft.balance`; parts you placed (`pinned`) stay where they are.
    ///
    /// - credits: the agents with room this week and quota left are used first, and each part an agent takes makes it
    ///   less attractive for the next, so work spreads over what you pay for already.
    /// - speed: each part goes where it finishes soonest (after what it waits for and the agent's earlier parts),
    ///   among agents that fit it at least fairly.
    /// - fewest: the agent that fits the most parts best takes them all, but for parts it fits poorly.
    public static func assign(_ draft: SplitDraft, fleet: [FleetAgent], records: [AgentRecord]) -> SplitDraft {
        guard !fleet.isEmpty else { return draft }
        var draft = draft
        let order = SwarmPlan.order(draft.active.map(\.task))?.map(\.id) ?? draft.active.map(\.id)
        let busiest = Double(fleet.map(\.weekTotal).max() ?? 0)
        func fits(_ part: SplitPart) -> [(FleetAgent, Double)] {
            fleet.map { ($0, fit(part, $0, records: records)) }
        }
        func set(_ id: String, _ agent: FleetAgent) {
            draft.update(id) { part in
                guard !part.pinned else { return }
                part.task.owner = GoalItem.Owner(agent: agent.id, model: agent.onGitHub ? nil : agent.model)
            }
        }
        switch draft.balance {
        case .fewest:
            let totals = fleet.map { agent in
                (agent, draft.active.reduce(0.0) { $0 + fit($1, agent, records: records) })
            }
            guard let best = totals.max(by: { $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 < $1.1 })?.0 else { break }
            for id in order {
                guard let part = draft.part(id) else { continue }
                let ranked = fits(part).sorted { $0.1 > $1.1 }
                let own = fit(part, best, records: records)
                let keep = own >= 0.4 || (ranked.first?.1 ?? 0) < 0.4
                set(id, keep ? best : ranked[0].0)
            }
        case .credits:
            var load: [String: Double] = [:]
            for id in order {
                guard let part = draft.part(id) else { continue }
                if part.pinned, let agent = part.agent {
                    load[agent, default: 0] += part.hours
                    continue
                }
                let pick = fits(part).max { one, other in
                    let a = creditScore(one.0, fit: one.1, load: load[one.0.id] ?? 0, busiest: busiest)
                    let b = creditScore(other.0, fit: other.1, load: load[other.0.id] ?? 0, busiest: busiest)
                    return a == b ? one.0.id > other.0.id : a < b
                }!.0
                load[pick.id, default: 0] += part.hours
                set(id, pick)
            }
        case .speed:
            var free: [String: Double] = [:]
            var end: [String: Double] = [:]
            for id in order {
                guard let part = draft.part(id) else { continue }
                let ready = part.task.after.compactMap { end[$0] }.max() ?? 0
                let options = fits(part)
                let fair = options.filter { $0.1 >= 0.5 }
                let pool = fair.isEmpty ? options : fair
                let pick: FleetAgent = if part.pinned, let agent = part.agent,
                                          let own = fleet.first(where: { $0.id == agent })
                {
                    own
                } else {
                    pool.min { one, other in
                        let a = max(ready, free[one.0.id] ?? 0) + part.hours
                        let b = max(ready, free[other.0.id] ?? 0) + part.hours
                        return a == b ? one.1 > other.1 : a < b
                    }!.0
                }
                let finish = max(ready, free[pick.id] ?? 0) + part.hours
                free[pick.id] = finish
                end[id] = finish
                set(id, pick)
            }
        }
        return draft
    }

    /// credits: fit, plus room this week and quota left, less a little for every hour the agent already took; paid
    /// per use costs.
    static func creditScore(_ agent: FleetAgent, fit: Double, load: Double, busiest: Double) -> Double {
        let room = busiest > 0 ? 1 - Double(agent.weekTotal) / busiest : 1
        let quota = agent.quota?.left ?? 0.5
        let plan: Double = switch agent.plan {
        case .subscription, .included: 0.05
        case .metered: -0.1
        case .unknown: 0
        }
        return fit + 0.2 * room + 0.15 * quota + plan - 0.06 * load
    }
}
