import Foundation

/// A swarm PR that needs its branch reworked (a merge conflict with its base, or a rebase after the PR it stacked on
/// merged) goes back to the task's own worker: the same agent and model, in the worktree it kept, told what changed.
/// When that worker cannot take it (its agent is not set up or is rate limited, its worktree is gone, the swarm is
/// not running) a get it merged run does it instead, as for any PR. Pure: the app starts the worker or the run, and
/// writes a `handback` steering row either way.
public enum SwarmHandback {
    /// The queued items a worker takes back: a conflict or a rebase. Without one, the PR's feedback goes to a get it
    /// green run as usual.
    public static func needs(_ items: [FeedbackItem]) -> [FeedbackItem] {
        items.filter { item in
            guard item.status == .queued else { return false }
            switch item.kind {
            case .conflict, .rebase: return true
            case .review, .check, .note: return false
            }
        }
    }

    public enum Route: Hashable, Sendable {
        /// The task's last worker starts again on it: its owner, its worktree, its branch and base.
        case worker(SwarmWorker)
        /// Its worker is at work on the task now: the items wait for its turn to end.
        case wait(String)
        /// A get it merged run takes it: why the worker could not.
        case pilot(String)
    }

    /// Where a task's conflict or rebase goes. `agents`: the agents set up on this Mac; `limited`: agent → when its
    /// rate limit lifts (nil: unknown, still limited); `worktreeExists`: the last worker's worktree is still there.
    public static func route(
        task: String, swarm: GoalSwarm, agents: Set<String>, limited: [String: Date?], worktreeExists: Bool,
        now: Date
    ) -> Route {
        switch swarm.status {
        case .stopped: return .pilot("the swarm is stopped")
        case .paused: return .pilot("the swarm is paused")
        case .done: return .pilot("the swarm is done")
        case .planning, .running, .landing: break
        }
        guard let worker = swarm.lastWorker(on: task) else { return .pilot("no worker ran the task") }
        if worker.isLive { return .wait("its worker is at work on it") }
        let agent = worker.owner.agent
        guard agents.contains(agent) else { return .pilot("its agent \(agent) is not set up here") }
        if let resets = limited[agent], resets.map({ $0 > now }) ?? true {
            return .pilot("\(agent) is rate limited" + (resets.map { " until \(AgentUsage.clock($0))" } ?? ""))
        }
        guard !worker.worktree.isEmpty, worktreeExists else { return .pilot("its worktree is gone") }
        return .worker(worker)
    }

    /// `#415 conflicts with main`, `#415 rebases onto main (#412 merged)`: what went back, in a few words.
    public static func what(_ items: [FeedbackItem], pr: Int) -> String {
        let rebase = items.lazy.compactMap { item -> (String, Int)? in
            if case let .rebase(onto, parent, _) = item.kind { (onto, parent) } else { nil }
        }.first
        if let (onto, parent) = rebase { return "#\(pr) rebases onto \(onto) (#\(parent) merged)" }
        let conflict = items.lazy.compactMap { item -> (String, Bool)? in
            if case let .conflict(base, behind) = item.kind { (base, behind) } else { nil }
        }.first
        if let (base, behind) = conflict { return "#\(pr) \(behind ? "is behind" : "conflicts with") \(base)" }
        return "#\(pr) needs its branch reworked"
    }
}

public extension Handoff {
    /// A swarm worker taken back to its task's PR: its task, its PR and branch, what the PR needs now (`items`, the
    /// pipeline's queued items, a conflict or a rebase among them), and that it pushes to its branch only. Short: the
    /// worktree it kept holds the rest.
    static func swarmReturn(
        task: SwarmTask, number: String, swarm: GoalSwarm, pr: PullRef, branch: String, base: String,
        items: [FeedbackItem], instructions: String = ""
    ) -> String {
        var lines = [
            "You are back on swarm \(swarm.number)'s task \(number) \(task.title) (item \(task.id)), in the worktree "
                + "you worked in, on the branch \(branch). Your pull request \(pr.url) goes against \(base).",
            "",
            "It needs you again:",
        ]
        lines += items.map { "- " + $0.promptLine }
        lines += [
            "",
            "Fetch first (git fetch origin): the pull request may have moved since you left. Run the tests after "
                + "resolving anything. Push to \(branch) only (git push --force-with-lease after a rebase), never "
                + "to \(base), and never merge. Then stop: heed sees the push.",
        ]
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines += ["", extra] }
        return lines.joined(separator: "\n")
    }
}

public extension SwarmLanding {
    /// The merge-order rows a run's PRs wear on every row they show on: all of an active run's; a done run's while
    /// its PR is still open as heed last saw it (`isOpen`), so a label stays until its PR merged or closed. A stopped
    /// run's PRs wear none.
    static func labelled(_ rows: [Row], status: GoalSwarm.Status, isOpen: (Row) -> Bool) -> [Row] {
        if status.active { return rows }
        guard status == .done else { return [] }
        return rows.filter { $0.pr != nil && isOpen($0) }
    }
}
