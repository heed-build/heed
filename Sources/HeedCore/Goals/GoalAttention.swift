import Foundation

/// What goals put in Attention: a goal heed marked done (with undo), and reviewers held back by the day's budget.
public enum GoalAttention {
    /// How long a goal heed marked done stays in Attention.
    public static let doneFor: TimeInterval = 3 * 24 * 3600

    /// `waiting`: goal id → reviewers due but over budget; `blocked`: goal id → why its reviewers cannot run;
    /// `spawns`: goal id → spawns held past the goal's cap, with why.
    public static func items(
        goals: [HeedGoal], qualities: [String: GoalQuality], waiting: [String: [String]],
        blocked: [String: String] = [:], spawns: [String: [GoalHeldSpawn]] = [:], swarms: [GoalSwarm] = [],
        boards: [SwarmBoard] = [], now: Date
    ) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for goal in goals where goal.status != .archived {
            for board in boards where board.swarm.goal == goal.id && board.swarm.status.active {
                items += swarmItems(board, goal: goal)
            }
            if let swarm = swarms.last(where: { $0.goal == goal.id && $0.status == .paused }), let limit = swarm.held {
                let more = swarm.settings.limits.raised(limit)
                let offer = limit == .hours ? "\(String(format: "%g", more.hours)) h"
                    : "$\(String(format: "%g", more.dollars))"
                items.append(AttentionItem(
                    id: "goal:\(goal.id):swarm", kind: .goal, repo: nil, number: nil,
                    title: "\(goal.title): swarm \(swarm.number) paused at \(limit.text(swarm.settings.limits)) "
                        + "(y: raise it to \(offer), n: keep it paused)",
                    url: nil, reasons: [.swarmAsk], updatedAt: swarm.workers.last?.startedAt ?? swarm.startedAt
                ))
            }
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

    /// A swarm's questions that wait for you (each its own item, so `1…9` answer the one under the cursor), and the
    /// PRs heed could not move to their new base (one item per swarm).
    static func swarmItems(_ board: SwarmBoard, goal: HeedGoal) -> [AttentionItem] {
        var items: [AttentionItem] = []
        let numbers = SwarmPlan.numbers(board.tasks)
        for question in board.openQuestions {
            let position = SwarmLadder.position(question.row, rows: board.steering)
            guard position.step == .you, let id = question.row.id else { continue }
            let asker = question.row.from.flatMap(SwarmAddress.init(raw:))?.label(numbers)
                ?? (question.row.actor == .lead ? "the lead" : "an agent")
            items.append(AttentionItem(
                id: "goal:\(goal.id):ask:\(id)", kind: .goal, repo: nil, number: nil,
                title: "\(goal.title): \(asker) asks: \(question.row.text)", url: nil, reasons: [.swarmAsk],
                updatedAt: position.since
            ))
        }
        let failures = SwarmSteering.retargetFailures(board.steering)
        if let last = failures.last {
            let what = failures.count == 1 ? last.text.replacingOccurrences(
                of: "Could not move",
                with: "could not move"
            )
                : "\(failures.count) PRs could not move to their new base"
            items.append(AttentionItem(
                id: "goal:\(goal.id):retarget", kind: .goal, repo: nil, number: nil,
                title: "\(goal.title): swarm \(board.swarm.number) \(what) (y: try again, n: leave it)", url: nil,
                reasons: [.swarmAsk], updatedAt: last.at
            ))
        }
        return items
    }

    /// The swarm question an Attention item is (`goal:<goal>:ask:<row>`).
    public static func question(of item: AttentionItem) -> (goal: String, question: Int64)? {
        guard item.kind == .goal, item.reasons.contains(.swarmAsk) else { return nil }
        let parts = item.id.split(separator: ":")
        guard parts.count == 4, parts[0] == "goal", parts[2] == "ask", let id = Int64(parts[3]) else { return nil }
        return (String(parts[1]), id)
    }

    /// Whether an Attention item is a swarm's PRs heed could not move.
    public static func isRetarget(_ item: AttentionItem) -> Bool {
        item.kind == .goal && item.id.hasPrefix("goal:") && item.id.hasSuffix(":retarget")
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
