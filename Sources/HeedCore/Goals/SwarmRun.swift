import Foundation

/// A limit a swarm can reach: its hours of wall time or its dollars. Reaching one pauses spawning and asks you.
/// (Its agents at once are a cap, not a limit: a task waits for a free slot, nothing pauses.)
public enum SwarmLimit: String, Hashable, Sendable, Codable, CaseIterable {
    case hours, dollars

    /// `its 4 h limit`, `its $40 limit`.
    public func text(_ limits: SwarmSettings.Limits) -> String {
        switch self {
        case .hours: "its \(String(format: "%g", limits.hours)) h limit"
        case .dollars: "its $\(String(format: "%g", limits.dollars)) limit"
        }
    }
}

/// A worker on a swarm task: the task's agent in a tab of a session on the goal (the lead's), in a worktree of its own
/// on the task's branch, made from the base heed chose. Kept on the run (`GoalSwarm.workers`) when it ends, so the
/// run's hours, spend and history survive a restart.
public struct SwarmWorker: Hashable, Sendable, Codable, Identifiable {
    public enum Outcome: Hashable, Sendable, Codable {
        /// Its agent finished its turn (or exited).
        case turnOver
        /// You stopped it: the task paused, its tab closed, the swarm stopped, the task dropped.
        case stopped
        /// Its task went to another agent.
        case handedOff(String)
        /// heed quit while it worked.
        case interrupted
        /// It could not start, or its setup failed: why.
        case failed(String)

        public var text: String {
            switch self {
            case .turnOver: "its turn is over"
            case .stopped: "stopped"
            case let .handedOff(agent): "handed to \(agent)"
            case .interrupted: "interrupted"
            case let .failed(reason): "failed: \(reason)"
            }
        }
    }

    /// Unique per start.
    public var id: String
    /// The task's item id.
    public var task: String
    public var owner: GoalItem.Owner
    /// The session whose tab it runs in.
    public var host: String
    /// `org/name`.
    public var repo: String
    public var branch: String
    /// What its branch was made from: the default branch, or the branch of its blocker's open PR.
    public var base: String
    /// The task it stacks on (whose PR's branch `base` is); nil from the default branch.
    public var stackedOn: String?
    public var worktree: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome?
    /// What its agent cost, reported or estimated, once known.
    public var costUSD: Double?

    public init(
        id: String, task: String, owner: GoalItem.Owner, host: String, repo: String, branch: String, base: String,
        stackedOn: String? = nil, worktree: String, startedAt: Date, endedAt: Date? = nil, outcome: Outcome? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.host = host
        self.repo = repo
        self.branch = branch
        self.base = base
        self.stackedOn = stackedOn
        self.worktree = worktree
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.costUSD = costUSD
    }

    public var isLive: Bool { endedAt == nil }
}

/// What heed knows about one task (or an item a task waits for) right now: its PR, its worker, whether you paused it,
/// how much of its done-when has evidence. Built by `SwarmFacts.build`; the scheduler reads only these.
public struct SwarmTaskFacts: Hashable, Sendable {
    public enum PR: Hashable, Sendable {
        case none
        case open(number: Int, branch: String, checks: Checks)
        case merged(number: Int)
        case closed(number: Int)

        public enum Checks: String, Hashable, Sendable {
            case draft, running, passing, failing
        }

        /// `#12`.
        public var label: String? {
            switch self {
            case .none: nil
            case let .open(number, _, _), let .merged(number), let .closed(number): "#\(number)"
            }
        }
    }

    public var pr: PR
    /// Its worker at work now.
    public var worker: SwarmWorker?
    /// What that worker's agent is doing (working, asking, blocked, limited), when known.
    public var workerState: AgentState?
    /// A worker ran and ended without a PR, and nothing resumed the task since: why it ended.
    public var stalled: SwarmWorker.Outcome?
    /// You paused it.
    public var paused: Bool
    /// Its done-when lines with evidence, of `criteriaTotal`.
    public var criteriaMet: Int
    public var criteriaTotal: Int

    public init(
        pr: PR = .none, worker: SwarmWorker? = nil, workerState: AgentState? = nil,
        stalled: SwarmWorker.Outcome? = nil, paused: Bool = false, criteriaMet: Int = 0, criteriaTotal: Int = 0
    ) {
        self.pr = pr
        self.worker = worker
        self.workerState = workerState
        self.stalled = stalled
        self.paused = paused
        self.criteriaMet = criteriaMet
        self.criteriaTotal = criteriaTotal
    }

    /// Done: every done-when line has evidence and no PR of it is still open; with no done-when, its PR merged.
    public var done: Bool {
        if case .open = pr { return false }
        if criteriaTotal > 0 { return criteriaMet >= criteriaTotal }
        if case .merged = pr { return true }
        return false
    }

    public var merged: Bool { if case .merged = pr { true } else { false } }
}

/// Where a task stands in a running swarm, as the plan pane shows it, with a few words of why.
public struct SwarmTaskStatus: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, CaseIterable {
        /// What it waits for has no PR yet.
        case waiting
        /// It could start: its blockers are merged, or one has a PR open to stack on. Held only by limits.
        case ready
        case working
        /// You paused it.
        case paused
        /// Its worker ended without a PR: it waits for you (resume it, swap its agent).
        case stalled
        /// Its PR is open (a draft, checks running or failing).
        case pr
        /// Its PR is open and its checks pass.
        case green
        /// Its PR merged; its done-when has no evidence yet.
        case merged
        case done

        /// Whether it has landed work: a PR or more.
        public var landed: Bool { [.pr, .green, .merged, .done].contains(self) }
    }

    public var state: State
    /// Why, in a few words: `after 1.2 (no PR yet)`, `3 of 3 agents at work`, `CI failing`.
    public var reason: String?
    /// For a task that starts (or would): the branch it starts from, and the task it stacks on.
    public var base: String?
    public var stackedOn: String?

    public init(_ state: State, _ reason: String? = nil, base: String? = nil, stackedOn: String? = nil) {
        self.state = state
        self.reason = reason
        self.base = base
        self.stackedOn = stackedOn
    }
}

/// The facts the scheduler reads, from what heed has: the goal's items and evidence, the run's workers and steering,
/// the PRs gh knows, and the live workers' states.
public enum SwarmFacts {
    /// Facts for every task of `tasks` and every item they wait for. `states`: live worker id → its agent's state.
    public static func build(
        swarm: GoalSwarm, tasks: [SwarmTask], items: [GoalItem], evidence: [GoalEvidence], steering: [SwarmSteer],
        pulls: [PullRequest], states: [String: AgentState] = [:]
    ) -> [String: SwarmTaskFacts] {
        let paused = SwarmSteering.pausedTasks(steering)
        let resumed = SwarmSteering.resumedAt(steering)
        let byItem = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = tasks.map(\.id)
        for blocker in tasks.flatMap(\.after) where !ids.contains(blocker) {
            ids.append(blocker)
        }
        var facts: [String: SwarmTaskFacts] = [:]
        for id in ids {
            let task = tasks.first { $0.id == id }
            let item = byItem[id]
            let doneWhen = task?.doneWhen ?? item?.doneWhen ?? []
            let mine = evidence.filter { $0.item == id }
            let met = doneWhen.count { line in
                mine.contains { $0.kind == .criterion && $0.state == .done && GoalEdits.same($0.text, line) }
            }
            let branch = item.map { SwarmWork.branch(goal: $0.goal, slug: $0.slug) }
                ?? SwarmWork.branch(goal: swarm.goal, slug: SwarmPlan.short(id))
            var pr = pullFacts(
                branches: Set([branch] + swarm.workers.filter { $0.task == id }.map(\.branch)
                    + (item?.linked(.branch) ?? [])),
                refs: Set(item?.linked(.pr) ?? []), repos: Set(swarm.settings.repos), pulls: pulls
            )
            // An item merged before the swarm (or by hand) with no PR heed knows: its evidence says so.
            if case .none = pr, mine.contains(where: { $0.kind == .merged && $0.state == .done }) {
                pr = .merged(number: 0)
            }
            let live = swarm.workers.last { $0.task == id && $0.isLive }
            var stalled: SwarmWorker.Outcome?
            if live == nil, case .none = pr, let last = swarm.workers.last(where: { $0.task == id }),
               let ended = last.endedAt, ended > (resumed[id] ?? .distantPast)
            {
                stalled = last.outcome ?? .turnOver
            }
            facts[id] = SwarmTaskFacts(
                pr: pr, worker: live, workerState: live.flatMap { states[$0.id] }, stalled: stalled,
                paused: paused.contains(id), criteriaMet: met, criteriaTotal: doneWhen.count
            )
        }
        return facts
    }

    /// The task's PR among `pulls`: on one of its branches (in the swarm's repos, when it names any) or linked to its
    /// item. An open one first, then merged, then closed; the newest of each.
    static func pullFacts(
        branches: Set<String>, refs: Set<String>, repos: Set<String>, pulls: [PullRequest]
    ) -> SwarmTaskFacts.PR {
        let mine = pulls.filter { pull in
            refs.contains(pull.ref.description)
                || branches.contains(pull.headBranch) && (repos.isEmpty || repos.contains(pull.ref.repo.slug))
        }
        let rank: (PullRequest) -> Int = { $0.state == .open ? 0 : $0.state == .merged ? 1 : 2 }
        guard let pull = mine.min(by: { (rank($0), -$0.ref.number) < (rank($1), -$1.ref.number) }) else {
            return .none
        }
        switch pull.state {
        case .merged: return .merged(number: pull.ref.number)
        case .closed: return .closed(number: pull.ref.number)
        case .open:
            let checks: SwarmTaskFacts.PR.Checks = if pull.isDraft {
                .draft
            } else if pull.checks.failed > 0 {
                .failing
            } else if pull.checks.pending > 0 || pull.checks.passed == 0 {
                .running
            } else {
                .passing
            }
            return .open(number: pull.ref.number, branch: pull.headBranch, checks: checks)
        }
    }
}

/// Which tasks start now, and where every task stands: blockers merged (or one open PR to stack on), within the run's
/// limits, not paused, its agent not rate limited.
public enum SwarmScheduler {
    /// What the run has used: workers at work, dollars spent, hours since it started running, and the agents rate
    /// limited now (with when their limit lifts, nil when unknown).
    public struct Usage: Hashable, Sendable {
        public var live: Int
        public var dollars: Double
        public var elapsed: TimeInterval
        public var limited: [String: Date?]

        public init(live: Int = 0, dollars: Double = 0, elapsed: TimeInterval = 0, limited: [String: Date?] = [:]) {
            self.live = live
            self.dollars = dollars
            self.elapsed = elapsed
            self.limited = limited
        }

        /// A run's usage from its record: its live workers, their costs, its hours since `runningAt`.
        public static func of(_ swarm: GoalSwarm, limited: [String: Date?], now: Date) -> Usage {
            Usage(
                live: swarm.liveWorkers.count, dollars: swarm.workers.compactMap(\.costUSD).reduce(0, +),
                elapsed: swarm.runningAt.map { max(0, now.timeIntervalSince($0)) } ?? 0, limited: limited
            )
        }
    }

    /// A task to start now, from `base` (stacked on `stackedOn`'s PR when set).
    public struct Start: Hashable, Sendable {
        public var task: String
        public var base: String
        public var stackedOn: String?

        public init(task: String, base: String, stackedOn: String? = nil) {
            self.task = task
            self.base = base
            self.stackedOn = stackedOn
        }
    }

    public struct Schedule: Hashable, Sendable {
        public var states: [String: SwarmTaskStatus]
        public var starts: [Start]
        /// A limit the run reached: it pauses and asks you.
        public var limit: SwarmLimit?
    }

    /// Where a task would start from: the default branch when everything it waits for is merged (or done); the
    /// branch of the one blocker whose PR is open, when that is all that is left; otherwise it waits, and says for
    /// what. Two blockers with open PRs cannot both be stacked on: it waits until one merges.
    public enum Base: Hashable, Sendable {
        case start(base: String, stackedOn: String?)
        case wait(String)
    }

    public static func base(
        _ task: SwarmTask, facts: [String: SwarmTaskFacts], numbers: [String: String], defaultBranch: String
    ) -> Base {
        var open: [(id: String, branch: String)] = []
        var missing: [String] = []
        var closed: [String] = []
        for blocker in task.after {
            let fact = facts[blocker] ?? SwarmTaskFacts()
            if fact.done || fact.merged { continue }
            let name = numbers[blocker] ?? SwarmPlan.short(blocker)
            switch fact.pr {
            case let .open(_, branch, _): open.append((blocker, branch))
            case .closed: closed.append(name)
            case .none, .merged: missing.append(name)
            }
        }
        if !closed.isEmpty { return .wait("after \(closed.joined(separator: ", ")) (its PR closed unmerged)") }
        if !missing.isEmpty { return .wait("after \(missing.joined(separator: ", ")) (no PR yet)") }
        if open.count > 1 {
            let names = open.map { numbers[$0.id] ?? SwarmPlan.short($0.id) }.joined(separator: " and ")
            return .wait("after \(names): two open PRs, it starts when one merges")
        }
        if let one = open.first { return .start(base: one.branch, stackedOn: one.id) }
        return .start(base: defaultBranch, stackedOn: nil)
    }

    /// The tasks that start now (in plan order, up to the free slots) and every task's state. Nothing starts while the
    /// run is not approved, paused or over, or once it reached a limit. `tasks` is the approved plan's outline.
    public static func schedule(
        _ swarm: GoalSwarm, tasks: [SwarmTask], facts: [String: SwarmTaskFacts], usage: Usage, defaultBranch: String,
        now: Date
    ) -> Schedule {
        let numbers = SwarmPlan.numbers(tasks)
        let limits = swarm.settings.limits
        let limit: SwarmLimit? = if !swarm.startsWorkers {
            nil
        } else if usage.elapsed >= limits.hours * 3600 {
            .hours
        } else if usage.dollars >= limits.dollars {
            .dollars
        } else {
            nil
        }
        var states: [String: SwarmTaskStatus] = [:]
        var starts: [Start] = []
        for task in tasks {
            let fact = facts[task.id] ?? SwarmTaskFacts()
            if fact.done {
                states[task.id] = SwarmTaskStatus(.done, fact.pr.label.map { "\($0) merged" })
                continue
            }
            switch fact.pr {
            case let .merged(number):
                states[task.id] = SwarmTaskStatus(
                    .merged, (number > 0 ? "#\(number) merged · " : "")
                        + "done when \(fact.criteriaMet) of \(fact.criteriaTotal)"
                )
                continue
            case let .open(number, _, checks):
                states[task.id] = checks == .passing ? SwarmTaskStatus(.green, "#\(number) green")
                    : SwarmTaskStatus(.pr, "#\(number) " + (checks == .draft ? "draft" : checks == .failing
                            ? "CI failing" : "CI running"))
                continue
            case .closed, .none: break
            }
            if let worker = fact.worker {
                let doing = fact.workerState.flatMap { state -> String? in
                    switch state {
                    case .asking: "asking"
                    case .blocked: "blocked"
                    case .limited: "rate limited"
                    default: nil
                    }
                }
                states[task.id] = SwarmTaskStatus(
                    .working, doing ?? worker.owner.label, base: worker.base, stackedOn: worker.stackedOn
                )
                continue
            }
            if fact.paused {
                states[task.id] = SwarmTaskStatus(.paused, "paused by you")
                continue
            }
            if case let .closed(number) = fact.pr {
                states[task.id] = SwarmTaskStatus(.stalled, "#\(number) closed without merging")
                continue
            }
            if let ended = fact.stalled {
                states[task.id] = SwarmTaskStatus(.stalled, "its worker ended without a PR (\(ended.text))")
                continue
            }
            switch base(task, facts: facts, numbers: numbers, defaultBranch: defaultBranch) {
            case let .wait(reason):
                states[task.id] = SwarmTaskStatus(.waiting, reason)
            case let .start(base, stackedOn):
                let agent = task.owner?.agent ?? swarm.settings.team.first ?? swarm.settings.lead.agent
                let held: String? = if !swarm.startsWorkers {
                    swarm.status == .planning ? "the plan is not approved" : "the swarm is \(swarm.status.rawValue)"
                } else if let limit {
                    "the swarm reached \(limit.text(limits))"
                } else if let resets = usage.limited[agent], resets.map({ $0 > now }) ?? true {
                    "\(agent) is rate limited" + (resets.map { " until \(AgentUsage.clock($0))" } ?? "")
                } else if usage.live + starts.count >= limits.agents {
                    "\(limits.agents) of \(limits.agents) agents at work"
                } else {
                    nil
                }
                if held == nil { starts.append(Start(task: task.id, base: base, stackedOn: stackedOn)) }
                states[task.id] = SwarmTaskStatus(.ready, held, base: base, stackedOn: stackedOn)
            }
        }
        return Schedule(states: states, starts: starts, limit: limit)
    }

    /// The run's next status from its schedule, if it changes: a limit reached pauses it (until you raise the limit);
    /// approved and planning, it runs once a worker starts; it lands once every task has its PR (or is done), and runs
    /// again if one loses it. Paused by you, it stays paused; stopped and done never change here.
    public static func status(_ swarm: GoalSwarm, schedule: Schedule, tasks: [SwarmTask]) -> GoalSwarm.Status? {
        guard swarm.startsWorkers else { return nil }
        if schedule.limit != nil { return .paused }
        let landed = !tasks.isEmpty && tasks.allSatisfy { schedule.states[$0.id]?.state.landed == true }
        switch swarm.status {
        case .planning:
            if landed { return .landing }
            return schedule.starts.isEmpty ? nil : .running
        case .running: return landed ? .landing : nil
        case .landing: return landed ? nil : .running
        case .paused, .done, .stopped: return nil
        }
    }
}

/// How far a run is: tasks done of all, agents at work of its cap.
public struct SwarmProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int
    public var live: Int
    public var max: Int

    public init(swarm: GoalSwarm, tasks: [SwarmTask], states: [String: SwarmTaskStatus]) {
        total = tasks.count
        done = tasks.count { states[$0.id]?.state == .done }
        live = swarm.liveWorkers.count
        max = swarm.settings.limits.agents
    }

    /// `2 of 5 done`.
    public var tasksLine: String { "\(done) of \(total) done" }
    /// `3 live · max 4`.
    public var agentsLine: String { "\(live) live · max \(max)" }
}

/// A worker's branch, worktree and first prompt.
public enum SwarmWork {
    /// `swarm/<goal>/<task slug>`: outside `heed/`, which the sweep removes, since it carries the task's PR.
    public static func branch(goal: String, slug: String) -> String { "swarm/\(goal)/\(slug)" }

    public static func branch(of task: SwarmTask, goal: String) -> String { branch(goal: goal, slug: task.slug) }

    /// `<root>/heed/<repo>/swarm-<goal>-<task slug>`, beside the runs'.
    public static func worktreePath(root: String, repo: Repo, goal: String, slug: String) -> String {
        "\(root)/heed/\(repo.name)/swarm-\(goal)-\(slug)"
    }

    /// The tab's title: `swarm 1.2`.
    public static func title(number: String) -> String { "swarm \(number)" }

    /// What a worker starts on: its task and how we know it is done, where it is, the base its PR goes against (said
    /// twice when it stacks, since that is the one thing a worker would get wrong), and how to report. `handoff`: the
    /// agent it takes over from.
    public static func prompt(
        task: SwarmTask, number: String, swarm: GoalSwarm, goal title: String, doc path: String, branch: String,
        base: String, stackedOn: (number: String, title: String)?, numbers: [String: String], handoff: String? = nil
    ) -> String {
        var lines: [String] = []
        if let handoff {
            lines += [
                "You take over this task from \(handoff), in its worktree. Check git status, git log \(base)..HEAD and "
                    + "the diff to see what is already done, then carry on.",
                "",
            ]
        }
        lines += [
            "You are a worker in swarm \(swarm.number) on the goal \(title). Its GOAL.md is \(path).",
            "",
            "Your task: \(number) \(task.title) (item \(task.id)).",
        ]
        if !task.doneWhen.isEmpty {
            lines += ["", "It is done when:"]
            lines += task.doneWhen.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        if !task.after.isEmpty {
            lines += [
                "",
                "It comes after " + task.after.map { numbers[$0] ?? SwarmPlan.short($0) }.joined(separator: ", ")
                    + ".",
            ]
        }
        lines += ["", "You are in a worktree of your own on the branch \(branch), made from \(base)."]
        if let stackedOn {
            lines.append(
                "\(base) is the branch of \(stackedOn.number) \(stackedOn.title), whose pull request is open and not "
                    + "merged: your work stacks on it, so your pull request goes against \(base), not the default "
                    + "branch."
            )
        }
        lines += [
            "",
            "Work only on this task; other agents work on the others in worktrees of their own. Commit as you go. "
                + "When it is done:",
            "1. git push -u origin \(branch)",
            "2. gh pr create --base \(base) --head \(branch) --fill",
            "3. heed goal link pr <its URL> --item \(task.id)",
        ]
        if !task.doneWhen.isEmpty {
            lines.append(
                "4. For each done-when line the work shows: heed goal criterion check <n> --item \(task.id) "
                    + "--evidence <what shows it>"
            )
        }
        lines += [
            "",
            "Never merge, and never push to \(base). What you cannot decide from the goal and the code, ask: heed goal "
                + "ask <question> --option <a> --option <b>. Then stop: heed sees your pull request.",
        ]
        return lines.joined(separator: "\n")
    }
}

public extension SwarmSteering {
    /// The tasks paused now: the newest pause or resume row about each (`task:<id>`) is a pause.
    static func pausedTasks(_ rows: [SwarmSteer]) -> Set<String> {
        var paused: Set<String> = []
        for row in rows where row.kind == .pause || row.kind == .resume {
            guard let task = taskRef(row) else { continue }
            if row.kind == .pause { paused.insert(task) } else { paused.remove(task) }
        }
        return paused
    }

    /// When each task was last resumed: a worker that ended before that does not hold it back any more.
    static func resumedAt(_ rows: [SwarmSteer]) -> [String: Date] {
        var resumed: [String: Date] = [:]
        for row in rows where row.kind == .resume {
            if let task = taskRef(row) { resumed[task] = row.at }
        }
        return resumed
    }

    /// The task a row is about (`task:<id>` in its ref).
    static func taskRef(_ row: SwarmSteer) -> String? {
        guard let ref = row.ref, ref.hasPrefix("task:") else { return nil }
        return String(ref.dropFirst(5))
    }
}

/// A task dropped from an approved plan stays on the goal: a swarm item whose phase was cleared. On the board it keeps
/// the column its evidence gives it and wears DROPPED; the swarm no longer counts it, starts it or waits for it. An
/// item the swarm took in (the goal had it before) goes back to being an ordinary item.
public enum SwarmDropped {
    public static func isDropped(_ item: GoalItem) -> Bool { item.source == .swarm && item.phase == nil }
}
