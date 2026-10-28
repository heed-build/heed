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

    var settings: SwarmSettings {
        SwarmSettings(repos: repos, lead: lead, workers: workers, limits: limits, autonomy: autonomy)
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

    var selectedTask: SwarmTask? {
        let tasks = planTasks
        return tasks.indices.contains(taskCursor) ? tasks[taskCursor] : nil
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

    /// ⇥ in the plan pane: the goals, the tasks, the versions, in turn (past what is empty).
    func togglePlanFocus() {
        let order: [Focus] = [.goals, .tasks, .versions]
        let start = order.firstIndex(of: focus) ?? 0
        for step in 1 ... order.count {
            let next = order[(start + step) % order.count]
            switch next {
            case .tasks where planTasks.isEmpty, .versions where (board?.versions ?? []).isEmpty: continue
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
        if id.hasPrefix("task:") {
            let task = String(id.dropFirst(5))
            if let goal = task.split(separator: "/").first.map(String.init), selected?.id != goal { point(to: goal) }
            if let index = planTasks.firstIndex(where: { $0.id == task }) {
                focus = .tasks
                taskCursor = index
            }
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
    }
}
