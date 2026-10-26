import Foundation

/// What goals put in Attention: a goal heed marked done (with undo), and reviewers held back by the day's budget.
public enum GoalAttention {
    /// How long a goal heed marked done stays in Attention.
    public static let doneFor: TimeInterval = 3 * 24 * 3600

    /// `waiting`: goal id → reviewers due but over budget; `blocked`: goal id → why its reviewers cannot run;
    /// `spawns`: goal id → spawns held past the goal's cap, with why.
    public static func items(
        goals: [HeedGoal], qualities: [String: GoalQuality], waiting: [String: [String]],
        blocked: [String: String] = [:], spawns: [String: [GoalHeldSpawn]] = [:], now: Date
    ) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for goal in goals where goal.status != .archived {
            let quality = qualities[goal.id]
            if goal.status == .done, quality?.doneMark?.done == true, let at = quality?.doneAt,
               now.timeIntervalSince(at) < doneFor
            {
                items.append(AttentionItem(
                    id: "goal:\(goal.id):done", kind: .goal, repo: nil, number: nil,
                    title: "\(goal.title) is done: every criterion has evidence, every lens is at its bar",
                    url: nil, reasons: [.goalDone], updatedAt: at
                ))
            }
            if goal.status == .active, let ids = waiting[goal.id], !ids.isEmpty {
                let names = ids.compactMap { id in quality?.reviewer(id)?.config.kind.title.lowercased() ?? id }
                items.append(AttentionItem(
                    id: "goal:\(goal.id):budget", kind: .goal, repo: nil, number: nil,
                    title: "\(goal.title): \(names.joined(separator: ", ")) wait for tomorrow's reviewer budget",
                    url: nil, reasons: [.goalBudget], updatedAt: quality?.runs.last ?? now
                ))
            }
            if goal.status == .active, let held = spawns[goal.id], let last = held.last {
                let what = held.count == 1 ? "\(last.title) waits to start" : "\(held.count) spawns wait to start"
                items.append(AttentionItem(
                    id: "goal:\(goal.id):spawn", kind: .goal, repo: nil, number: nil,
                    title: "\(goal.title): \(what), asked by \(last.spawn.from) (\(last.reason))", url: nil,
                    reasons: [.goalSpawn], updatedAt: last.at
                ))
            }
            if goal.status == .active, let why = blocked[goal.id] {
                items.append(AttentionItem(
                    id: "goal:\(goal.id):blocked", kind: .goal, repo: nil, number: nil,
                    title: "\(goal.title): reviewers cannot run, \(why)", url: nil, reasons: [.goalReviewBlocked],
                    updatedAt: quality?.runs.last ?? goal.updatedAt
                ))
            }
        }
        return items
    }

    /// The goal an Attention item is about.
    public static func goal(of item: AttentionItem) -> String? {
        guard item.kind == .goal, item.id.hasPrefix("goal:") else { return nil }
        return item.id.dropFirst(5).split(separator: ":").first.map(String.init)
    }
}

/// A spawn held past its goal's cap, until you say y or n in Attention.
public struct GoalHeldSpawn: Equatable, Sendable {
    public var spawn: GoalSpawn
    /// The item's title.
    public var title: String
    public var reason: String
    public var at: Date

    public init(spawn: GoalSpawn, title: String, reason: String, at: Date) {
        self.spawn = spawn
        self.title = title
        self.reason = reason
        self.at = at
    }
}
