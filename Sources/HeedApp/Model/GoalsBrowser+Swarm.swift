import Foundation
import HeedCore

/// The new swarm form: what the goal is (a new one, or the goal under the cursor), where it works, who leads and who
/// works, its limits and how much you are asked.
struct SwarmForm: Equatable {
    /// The goal it swarms; nil makes a new goal from `title` and `statement`.
    var goal: String?
    var title = ""
    var statement = ""
    /// A session the new goal is made from, which goes on it.
    var session: String?
    /// `org/name`, in the order picked; the lead starts in the first.
    var repos: [String] = []
    var lead = GoalItem.Owner(agent: "claude")
    var workers: [SwarmSettings.Worker] = []
    var limits = SwarmSettings.Limits()
    var autonomy = SwarmSettings.Autonomy.planChanges
    /// When a worker counts as stuck.
    var stuck = SwarmStuck.Settings.defaults
    /// Get it merged for its PRs.
    var merge = SwarmSettings.Merge.repo
    /// Where it runs: a host, or nil for this Mac (`swarm.host`).
    var host: String?
    /// A repo typed into the repo field (`owner/name`, a GitHub URL, a path), checked as you type (`RepoEntry`); ↩ or
    /// ⌘↩ adds it once it is fine.
    var repoEntry = ""
    /// ⌘↩ was pressed: what is missing shows under its field from now on.
    var tried = false
    /// Cloning the picked repos that are not where it runs yet, or why that failed: shown under the repos.
    var cloneNote: FieldNote?
    /// Why the last `swarm.host` could not be read, shown under Where.
    var hostProblem: String?

    var location: Location { host.map(Location.host) ?? .local }

    var settings: SwarmSettings {
        SwarmSettings(
            repos: repos, lead: lead, workers: workers, limits: limits, autonomy: autonomy, stuck: stuck,
            merge: merge, host: host
        )
    }
}

/// What is being typed in the plan pane: a task's fields (an edit, or a new one), feedback to re-plan, an answer to
/// the lead, or why not.
struct PlanDraft: Equatable {
    enum Kind: Equatable {
        case edit(String)
        /// A new task, after the task at this index of the outline (-1: first).
        case add(after: Int)
        case replan
        case answer(Int64)
        case reject
    }

    var kind: Kind
    var fields = SwarmTaskForm()
    /// Feedback, an answer, a reason.
    var text = ""
    /// ⌘↩ was pressed: what is missing shows under its field from now on.
    var tried = false

    var isTask: Bool {
        switch kind {
        case .edit, .add: true
        default: false
        }
    }

    init(kind: Kind) { self.kind = kind }

    init(editing task: SwarmTask, in tasks: [SwarmTask]) {
        kind = .edit(task.id)
        fields = SwarmTaskForm(task, in: tasks)
    }
}

/// The plan pane's state on `GoalsBrowser`: the selected goal's swarm board, the cursors on its tasks and versions.
extension GoalsBrowser {
    /// The current plan's tasks, in outline order.
    var planTasks: [SwarmTask] { SwarmPlan.grouped(board?.tasks ?? []) }

    /// The tasks as the outline shows them, which the cursor moves over: by phase, or in merge order
    /// (`swarm.order`).
    var shownTasks: [SwarmTask] {
        let tasks = planTasks
        guard byMergeOrder else { return tasks }
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SwarmLanding.order(tasks).compactMap { byID[$0] }
    }

    /// The task a task command acts on: the plan's cursor, the agents pane's worker, or the map's card.
    var selectedTask: SwarmTask? {
        switch pane {
        case .agents: return selectedAgentTask
        case .map: return mapCursor.flatMap { id in planTasks.first { $0.id == id } }
        default:
            let tasks = shownTasks
            return tasks.indices.contains(taskCursor) ? tasks[taskCursor] : nil
        }
    }

    /// `swarm.order`: by phase or in merge order, the cursor staying on its task.
    func toggleOrder() {
        let id = selectedTask?.id
        byMergeOrder.toggle()
        if let id, let index = shownTasks.firstIndex(where: { $0.id == id }) { taskCursor = index }
    }

    /// The cursor on a task by id, wherever the outline shows it.
    func pointTask(_ id: String) {
        if let index = shownTasks.firstIndex(where: { $0.id == id }) { setTaskCursor(index) }
    }

    var selectedPlanVersion: SwarmPlanVersion? {
        let versions = board?.versions ?? []
        return versions.indices.contains(versionCursor) ? versions[versionCursor] : versions.first
    }

    /// The selected goal's swarm that is still going.
    var activeSwarm: GoalSwarm? { selected.flatMap { snapshot.activeSwarm(of: $0.id) } }

    func setTaskCursor(_ index: Int) {
        let count = planTasks.count
        guard count > 0 else { return }
        taskCursor = min(max(index, 0), count - 1)
    }

    func setVersionCursor(_ index: Int) {
        let count = board?.versions.count ?? 0
        guard count > 0 else { return }
        let next = min(max(index, 0), count - 1)
        if next != versionCursor { fullDiff = false }
        versionCursor = next
    }

    /// The steering log as the plan pane lists it: newest first, only `logActor`'s rows when one is picked.
    var shownSteering: [SwarmSteer] {
        let rows = (board?.steering ?? []).reversed()
        guard let logActor else { return Array(rows) }
        return rows.filter { $0.actor == logActor }
    }

    var selectedSteer: SwarmSteer? {
        let rows = shownSteering
        return focus == .steering && rows.indices.contains(steeringCursor) ? rows[steeringCursor] : nil
    }

    func setSteeringCursor(_ index: Int) {
        let count = shownSteering.count
        guard count > 0 else { return }
        steeringCursor = min(max(index, 0), count - 1)
    }

    /// The cursor on a steering row by id, showing everyone's rows when the filter hides it.
    func pointSteer(_ id: Int64) {
        if !shownSteering.contains(where: { $0.id == id }) { logActor = nil }
        guard let index = shownSteering.firstIndex(where: { $0.id == id }) else { return }
        focus = .steering
        steeringCursor = index
    }

    /// ⇥ in the plan pane: the goals, the tasks, the versions, the steering log, in turn (past what is empty).
    func togglePlanFocus() {
        let order: [Focus] = [.goals, .tasks, .versions, .steering]
        let start = order.firstIndex(of: focus) ?? 0
        for step in 1 ... order.count {
            let next = order[(start + step) % order.count]
            switch next {
            case .tasks where planTasks.isEmpty, .versions where (board?.versions ?? []).isEmpty,
                 .steering where shownSteering.isEmpty: continue
            default:
                focus = next
                return
            }
        }
    }

    /// `goal.swarm`: the plan pane, or back to the overview.
    func togglePlan() {
        show(pane == .plan ? .overview : .plan)
        draft = nil
        planDraft = nil
        if pane == .plan, focus == .goals, !planTasks.isEmpty { focus = .tasks }
    }

    /// The cursor on a task (`task:<id>`) or a plan version (`planv:<n>`); true when the id was one.
    func pointPlan(to id: String) -> Bool {
        if id.hasPrefix("rule:") { return true }
        if id.hasPrefix("task:") {
            let task = String(id.dropFirst(5))
            if let goal = task.split(separator: "/").first.map(String.init), selected?.id != goal { point(to: goal) }
            if pane == .agents, let index = agentTasks.firstIndex(where: { $0.id == task }) {
                focus = .agents
                agentCursor = index
                return true
            }
            if pane == .map {
                mapCursor = task
                return true
            }
            if let index = shownTasks.firstIndex(where: { $0.id == task }) {
                focus = .tasks
                taskCursor = index
            }
            return true
        }
        if id.hasPrefix("steer:"), let row = Int64(id.dropFirst(6)) {
            pointSteer(row)
            return true
        }
        if id.hasPrefix("planv:"), let number = Int(id.dropFirst(6)) {
            if let index = board?.versions.firstIndex(where: { $0.number == number }) {
                focus = .versions
                setVersionCursor(index)
            }
            return true
        }
        return false
    }

    /// The selected goal's board from what was last read (and fresh from the store after).
    func selectBoard() {
        guard let goal = selected else {
            if board != nil { board = nil }
            return
        }
        let swarm = snapshot.activeSwarm(of: goal.id) ?? snapshot.swarms(of: goal.id).first
        let fresh = swarm.flatMap { boards[$0.id] }.map { cached in
            var cached = cached
            cached.swarm = swarm ?? cached.swarm
            return cached
        }
        if fresh != board {
            let changedRun = fresh?.swarm.id != board?.swarm.id
            board = fresh
            if changedRun {
                taskCursor = 0
                versionCursor = 0
                steeringCursor = 0
                fullDiff = false
                planDraft = nil
            }
            clampPlanCursors()
        }
        Task { await reloadBoard() }
    }

    /// Reads the selected goal's swarm board again.
    func reloadBoard() async {
        guard let ops, let goal = selected,
              let swarm = snapshot.activeSwarm(of: goal.id) ?? snapshot.swarms(of: goal.id).first,
              let fresh = try? await ops.board(of: swarm.id)
        else { return }
        boards[swarm.id] = fresh
        guard selected?.id == goal.id, fresh != board else { return }
        let changedRun = fresh.swarm.id != board?.swarm.id
        let previous = board?.swarm.plan
        board = fresh
        if changedRun { taskCursor = 0 }
        // A new version: the cursor on it, so its diff shows.
        if changedRun || previous != fresh.swarm.plan { versionCursor = 0 }
        clampPlanCursors()
    }

    private func clampPlanCursors() {
        taskCursor = min(taskCursor, max(planTasks.count - 1, 0))
        versionCursor = min(versionCursor, max((board?.versions.count ?? 0) - 1, 0))
        if focus == .tasks, planTasks.isEmpty { focus = .goals }
        if focus == .versions, (board?.versions ?? []).isEmpty { focus = .goals }
        steeringCursor = min(steeringCursor, max(shownSteering.count - 1, 0))
        if focus == .steering, shownSteering.isEmpty { focus = .goals }
    }

    /// The fake world's anchors run once its workers are going, laid over the approved one: at once for what is drawn,
    /// and into the in-memory store once the fake world is in it.
    func loadRunningFixture(_ variant: SwarmFixtures.Running) -> SwarmFixtures.RunningWorld {
        var world = SwarmFixtures.running(variant)
        var fresh = snapshot
        fresh.swarms = fresh.swarms.filter { $0.id != world.swarm.id } + [world.swarm]
        fresh.evidence += world.evidence
        apply(fresh)
        fixturePulls = world.pulls
        if var board = boards[world.swarm.id] {
            // Ids as the store will give them; the rows' references back into the world resolved with them.
            world.steering = SwarmFixtures.number(
                world.steering,
                from: (board.steering.compactMap(\.id).max() ?? 0) + 1
            )
            board.steering += world.steering
            board.swarm = world.swarm
            boards[world.swarm.id] = board
        }
        selectBoard()
        if let ops {
            let load = fixtureLoad
            Task {
                await load?.value
                try? await ops.adopt(running: world)
                if let snapshot = try? await ops.snapshot() { apply(snapshot) }
                await reloadBoard()
            }
        }
        return world
    }
}
