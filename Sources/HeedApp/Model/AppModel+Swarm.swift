import Foundation
import HeedCore

/// Swarms: a goal in swarm mode. The new swarm form, the lead's session (Start work's machinery, on the goal with
/// origin swarm), and every act in the plan pane, each through `GoalOps` and each a steering row. Workers on the
/// approved plan start in `AppModel+SwarmRun`.
extension AppModel {
    // MARK: Moving

    /// `goal.swarm`: the goal's swarm, its plan and steering; again: the overview.
    func toggleGoalPlan() {
        if view != .goals {
            view = .goals
            if goals.pane != .plan { goals.togglePlan() }
        } else {
            goals.togglePlan()
        }
        endGoalEditing()
    }

    // MARK: The form

    /// `swarm.new`: the new swarm form, for a new goal (words: its title).
    func newSwarm(_ words: [String], from target: CommandTarget? = nil) {
        var session: Session?
        if case let .session(id) = target { session = sessions.first { $0.id == id } } else if view == .sessions {
            session = currentSession
        }
        var form = defaultSwarmForm(goal: nil, repos: session?.repos.map(\.slug) ?? [])
        form.title = words.isEmpty ? session?.title ?? "" : words.joined(separator: " ")
        form.statement = session.map { GoalsBrowser.firstParagraph($0.prompt) } ?? ""
        form.session = session?.id
        openSwarmForm(form)
    }

    /// `swarm.start`: swarm the goal under the cursor; the form first.
    func startSwarmOnGoal() {
        guard let goal = goals.selected else { return say("no goal here: n makes one, :swarm.new a swarm") }
        if let active = goals.snapshot.activeSwarm(of: goal.id) {
            return say("\(goal.title) has swarm \(active.number) going (\(active.stateLine)): :swarm.stop first")
        }
        // Where its sessions work, this Mac's repos first.
        let onGoal = goals.snapshot.links(of: goal.id).compactMap { link in
            (sessions + history.map(\.session)).first { $0.id == link.target }
        }
        var slugs: [String] = []
        for slug in onGoal.flatMap(\.repos).map(\.slug) where !slugs.contains(slug) {
            slugs.append(slug)
        }
        var form = defaultSwarmForm(goal: goal.id, repos: slugs)
        form.title = goal.title
        form.statement = goals.snapshot.docs[goal.id]?.goal ?? ""
        openSwarmForm(form)
    }

    private func defaultSwarmForm(goal: String?, repos slugs: [String]) -> SwarmForm {
        let agent = settings.defaultAgent
        var form = SwarmForm(goal: goal)
        form.repos = Array(slugs.filter { slug in repos.contains { $0.repo.slug == slug } }.prefix(3))
        form.lead = GoalItem.Owner(agent: agent)
        form.workers = [SwarmSettings.Worker(agent: agent, count: 2)]
        return form
    }

    private func openSwarmForm(_ form: SwarmForm) {
        goals.form = nil
        goals.swarmForm = form
        textInputActive = true
    }

    func cancelSwarmForm() {
        goals.swarmForm = nil
        textInputActive = false
    }

    /// The agents a picker cycles through.
    var swarmAgents: [String] { settings.agents.map(\.name) }

    /// The repos the form offers: this Mac's, picked first.
    var swarmRepoChoices: [String] {
        let local = repos.filter(\.location.isLocal).map(\.repo.slug)
        let picked = goals.swarmForm?.repos ?? []
        return picked + local.filter { !picked.contains($0) }.sorted()
    }

    /// The form's ⌘↩: the goal (made first when new), the run, then its lead.
    func submitSwarmForm() {
        guard let form = goals.swarmForm else { return }
        if form.goal == nil,
           form.title.trimmingCharacters(in: .whitespacesAndNewlines)
           .isEmpty { return say("a swarm's goal needs a title") }
        guard !form.repos.isEmpty || isFixture || tutor != nil else {
            return say("pick a repo for the lead to start in")
        }
        goals.swarmForm = nil
        textInputActive = false
        let session = form.session.flatMap { id in sessions.first { $0.id == id } }
        let now = Clock.now
        goals.run { ops in
            var goalID = form.goal
            if goalID == nil {
                let goal = try await ops.create(title: form.title, statement: form.statement, now: now)
                if let session {
                    try await ops.attach(GoalLink(
                        goal: goal.id, kind: GoalLink.kind(of: session), target: session.id, at: now
                    ))
                }
                goalID = goal.id
            }
            return try await ops.startSwarm(goal: goalID ?? "", settings: form.settings, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(swarm):
                view = .goals
                goals.point(to: swarm.goal)
                if goals.pane != .plan { goals.togglePlan() }
                startLead(swarm)
            case let .failure(error): say("no swarm started: \(error)")
            }
        }
    }

    /// The lead: a session as Start work makes one, in the swarm's first repo, on the goal (origin swarm) before its
    /// agent starts, so it launches with the goal and the `heed-goal` skill; told to draft the plan. Off screen.
    func startLead(_ swarm: GoalSwarm) {
        guard let goal = goals.snapshot.goal(swarm.goal) else { return }
        if isFixture || tutor != nil {
            return say("swarm \(swarm.number) on \(goal.title) is planning: in the fake world no lead starts")
        }
        let settings = swarm.settings
        guard let agent = self.settings.agent(settings.lead.agent) else {
            return say("no agent \(settings.lead.agent): the swarm waits for a lead (:swarm.stop ends it)")
        }
        let records = settings.repos.compactMap { slug in
            repos.first { $0.repo.slug == slug && $0.location.isLocal }
        }
        guard let first = records.first else {
            return say("none of the swarm's repos is on this Mac: no lead started")
        }
        let doc = Paths.tilde(goals.files.doc(goal.id).path)
        var plan = StartWorkPlan(
            prompt: SwarmLead.prompt(goal: goal.title, doc: doc, swarm: swarm), repos: [first],
            name: StartWork.branchName(
                for: "swarm \(swarm.number) lead \(goal.title)",
                prefixes: self.settings.prefixes
            ),
            agent: agent, integration: integration
        )
        plan.model = settings.lead.model
        let id = plan.sessionID
        let now = Clock.now
        let link = GoalLink(
            goal: goal.id, kind: .session, target: id, origin: .swarm,
            reason: "the lead of swarm \(swarm.number)", at: now
        )
        Task {
            let attached: Bool = await withCheckedContinuation { continuation in
                goals.run { ops in
                    try await ops.attach(link)
                    return true
                } done: { continuation.resume(returning: (try? $0.get()) == true) }
            }
            guard attached else { return say("the lead could not go on \(goal.title)") }
            applyGoalPointers()
            plan.signOff = self.settings.signOffArguments(agent: agent, repo: first.repo, session: id)
            let changes: [DomainChange]
            do {
                changes = try await StartWork.execute(plan, settings: self.settings, hosts: config.hosts)
            } catch {
                goals.run { ops in try await ops.detach(kind: .session, target: id) }
                return say("the lead did not start: \(error)")
            }
            guard case let .sessionUpserted(session)? = changes.first(where: {
                if case .sessionUpserted = $0 { true } else { false }
            }) else { return say("the lead did not start") }
            var panes: [PaneSpec] = []
            for case let .layoutChanged(_, layout) in changes {
                for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                    TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    panes.append(pane)
                }
            }
            commit(changes)
            for pane in panes {
                TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
            }
            goals.run { ops in try await ops.setLead(swarm: swarm.id, session: session.id, now: Clock.now) }
            say("\(settings.lead.label) leads swarm \(swarm.number) on \(goal.title): its plan shows here")
        }
    }

    /// Tells the lead, in its pane, that there is something to read: only when it is idle and you have not typed
    /// there (`Delivery`). Otherwise it reads it in `heed goal plan show` when it next looks.
    private func nudgeLead(_ board: SwarmBoard, _ text: String) {
        guard let id = board.swarm.lead, let session = sessions.first(where: { $0.id == id }),
              let layout = layouts[id], let (_, paneID) = agentPane(in: layout),
              TerminalSurfaces.shared.hasTerminal(paneID: paneID),
              Delivery.verdict(state: session.state.state, lastTyped: lastTyped[id]) == .deliver
        else { return }
        TerminalSurfaces.shared.typeLine(text + " Run heed goal plan show.", paneID: paneID)
        var told = session
        told.record("told the lead: \(text)")
        commit(.sessionUpserted(told))
    }

    // MARK: The plan

    /// The swarm the plan pane acts on: the selected goal's active one.
    private var planSwarm: SwarmBoard? {
        guard view == .goals, let board = goals.board, board.swarm.status.active else { return nil }
        return board
    }

    private func needSwarm() -> SwarmBoard? {
        if let board = planSwarm { return board }
        say(goals.selected.map { "\($0.title) has no swarm going: :swarm.start swarms it" } ?? "no goal here")
        return nil
    }

    /// Runs a plan operation, then says how it went.
    private func planOp<T: Sendable>(
        _ operation: @escaping @Sendable (GoalOps) async throws -> T, said: @escaping @MainActor (T) -> String
    ) {
        goals.run(operation) { [weak self] result in
            switch result {
            case let .success(value): self?.say(said(value))
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `swarm.approve`: the change waiting for you, else the plan. Its tasks become the goal's items, and workers
    /// start on the ones that are ready.
    func approvePlan() {
        guard let board = needSwarm() else { return }
        let id = board.swarm.id
        let now = Clock.now
        planOp {
            try await $0.approvePlan(swarm: id, now: now)
        } said: { [weak self] version in
            self?.tickSwarms()
            return "approved plan v\(version.number): \(version.tasks.count) tasks on the board; workers start as "
                + "their tasks are ready"
        }
    }

    /// `swarm.accept`: yes to the change waiting for you, as `y` takes one in GOAL.md. `swarm.approve` takes it too.
    func acceptPlanChange() {
        guard let board = needSwarm() else { return }
        guard board.pending != nil else { return say("no change waits for you") }
        approvePlan()
    }

    /// `swarm.reject`: no to the change waiting for you (with words: why).
    func rejectPlanChange(_ words: [String]) {
        guard let board = needSwarm() else { return }
        guard board.pending != nil else { return say("no change waits for you") }
        guard !words.isEmpty else { return beginPlanDraft(PlanDraft(kind: .reject)) }
        reject(board, why: words.joined(separator: " "))
    }

    private func reject(_ board: SwarmBoard, why: String) {
        let id = board.swarm.id
        let now = Clock.now
        planOp {
            try await $0.rejectChange(swarm: id, reason: why, now: now)
        } said: { _ in
            why.isEmpty ? "said no" : "said no: the lead hears why"
        }
        nudgeLead(board, "The owner said no to your plan change" + (why.isEmpty ? "." : ": \(why)."))
    }

    /// `swarm.task.edit`: the task under the cursor in the editor.
    func editPlanTask() {
        guard needSwarm() != nil else { return }
        guard let task = goals.selectedTask else { return say("no task here: a adds one") }
        beginPlanDraft(PlanDraft(editing: task, in: goals.planTasks))
    }

    /// `swarm.task.add`: a task after the one under the cursor, in its phase (words: its title, added at once).
    func addPlanTask(_ words: [String]) {
        guard let board = needSwarm() else { return }
        let tasks = goals.planTasks
        let at = goals.selectedTask.flatMap { task in tasks.firstIndex { $0.id == task.id } } ?? tasks.count - 1
        var draft = PlanDraft(kind: .add(after: tasks.isEmpty ? -1 : at))
        draft.fields.phase = goals.selectedTask?.phase ?? tasks.last?.phase ?? "Plan"
        draft.fields.owner = board.swarm.settings.team.first ?? ""
        guard words.isEmpty else {
            draft.fields.title = words.joined(separator: " ")
            return savePlanDraft(draft)
        }
        beginPlanDraft(draft)
    }

    /// `swarm.task.move <1|-1>`: the task under the cursor down or up (past its phase's edge, into the next).
    func movePlanTask(_ word: String?) {
        guard let board = needSwarm() else { return }
        let delta = Int(word ?? "") ?? 1
        guard let task = goals.selectedTask else { return say("no task here") }
        if goals.byMergeOrder {
            return say(
                "the merge order follows what each task waits for: \(keyText(for: "swarm.order", in: "goalplan")) "
                    + "shows the plan by phase, where tasks move"
            )
        }
        guard let moved = SwarmPlan.move(goals.planTasks, at: goals.taskCursor, by: delta < 0 ? -1 : 1) else {
            return say("\(task.title) is as far \(delta < 0 ? "up" : "down") as it goes")
        }
        let number = SwarmPlan.numbers(moved)[task.id] ?? ""
        changePlan(board, moved, kind: .move, text: "moved \(task.title) to \(number)", follow: task.id)
    }

    /// `swarm.task.drop`: the task under the cursor out of the plan (nothing waits for it any more).
    func dropPlanTask() {
        guard let board = needSwarm() else { return }
        guard let task = goals.selectedTask else { return say("no task here") }
        let number = SwarmPlan.numbers(board.tasks)[task.id] ?? ""
        // Its worker stops with it; its worktree and branch stay.
        if let live = liveWorker(on: task.id) { endWorker(live.id, .stopped, then: {}) }
        changePlan(
            board, SwarmPlan.drop(goals.planTasks, id: task.id), kind: .drop, text: "dropped \(number) \(task.title)",
            follow: nil
        )
    }

    /// `swarm.replan`: feedback for the lead, which answers with a new version.
    func replanSwarm(_ words: [String]) {
        guard let board = needSwarm() else { return }
        guard !words.isEmpty else { return beginPlanDraft(PlanDraft(kind: .replan)) }
        let id = board.swarm.id
        let feedback = words.joined(separator: " ")
        let now = Clock.now
        planOp {
            try await $0.replan(swarm: id, feedback: feedback, now: now)
        } said: { _ in
            "asked the lead to re-plan"
        }
        nudgeLead(board, "The owner asks you to re-plan: \(feedback)")
    }

    /// `swarm.answer [text]`: an answer to the lead's first open question (or the one clicked).
    func answerLead(_ words: [String], question: Int64? = nil) {
        guard let board = needSwarm() else { return }
        guard let asked = question ?? board.openQuestions.first?.id ?? board.questions.last?.id else {
            return say("the lead has asked nothing")
        }
        guard !words.isEmpty else {
            var draft = PlanDraft(kind: .answer(asked))
            draft.text = board.questions.first { $0.id == asked }?.answer?.text ?? ""
            return beginPlanDraft(draft)
        }
        let id = board.swarm.id
        let text = words.joined(separator: " ")
        let now = Clock.now
        planOp {
            try await $0.answer(swarm: id, question: asked, text: text, now: now)
        } said: { _ in
            "answered the lead"
        }
        nudgeLead(board, "The owner answered your question: \(text)")
    }

    /// `swarm.answer.option <n>`: the lead's first open question answered with its option n, as clicking it does.
    func answerLeadOption(_ word: String?) {
        guard let board = needSwarm() else { return }
        guard let question = board.openQuestions.first else { return say("the lead asks nothing open") }
        let options = question.row.options
        guard let number = Int(word ?? ""), options.indices.contains(number - 1) else {
            return say(options.isEmpty ? "the question has no options: \(keyText(for: "swarm.answer", in: "goalplan")) "
                + "types an answer" : "the question has \(options.count) option\(options.count == 1 ? "" : "s")")
        }
        answerLead([options[number - 1]], question: question.id)
    }

    /// `swarm.diff`: the version under the cursor's whole diff, or its first lines.
    func togglePlanDiff() {
        guard view == .goals, goals.board != nil else { return say("no swarm here") }
        if goals.pane != .plan { goals.togglePlan() }
        goals.fullDiff.toggle()
    }

    /// `swarm.restore [n]`: a version current again, as a new one.
    func restorePlan(_ words: [String]) {
        guard let board = needSwarm() else { return }
        let number = words.first.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) }
            ?? goals.selectedPlanVersion?.number
        guard let number else { return say("no version to restore") }
        guard number != board.swarm.plan else { return say("v\(number) is the plan now: pick an older one") }
        let id = board.swarm.id
        let now = Clock.now
        planOp {
            try await $0.restorePlan(swarm: id, version: number, now: now)
        } said: { version in
            version.map { "v\(number) restored as v\($0.number)" } ?? "v\(number) is what the plan says now"
        }
    }

    /// `swarm.stop`: the goal's swarm ends; its workers' tabs close (their worktrees and branches stay until you
    /// clean them up), its plan and steering stay readable, the goal carries on.
    func stopSwarm() {
        guard let goal = goals.selected else { return say("no goal here") }
        guard let swarm = goals.snapshot.activeSwarm(of: goal.id)
        else { return say("\(goal.title) has no swarm going") }
        let workers = liveWorkers.values.count { $0.swarm == swarm.id }
        stopSwarmWorkers(swarm) { [weak self] result in
            switch result {
            case .success:
                self?.say(
                    "swarm \(swarm.number) on \(goal.title) stopped"
                        + (workers == 0 ? "" : ", \(workers) worker\(workers == 1 ? "" : "s") with it (worktrees kept)")
                        + ": its plan and steering stay here"
                )
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    private func changePlan(
        _ board: SwarmBoard, _ tasks: [SwarmTask], kind: SwarmSteer.Kind, text: String, follow: String?
    ) {
        let id = board.swarm.id
        let now = Clock.now
        goals.run { ops in
            try await ops.changePlan(swarm: id, tasks: tasks, kind: kind, text: text, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(version):
                if let follow { goals.pointTask(follow) }
                say(version.map { "plan v\($0.number): \(text)" } ?? "no change")
            case let .failure(error): say("\(error)")
            }
        }
    }

    // MARK: Typing

    private func beginPlanDraft(_ draft: PlanDraft) {
        if goals.pane != .plan { goals.togglePlan() }
        goals.planDraft = draft
        textInputActive = true
    }

    func cancelPlanDraft() {
        goals.planDraft = nil
        textInputActive = false
    }

    /// ⌘↩ or Save in the plan pane's editor.
    func submitPlanDraft() {
        guard let draft = goals.planDraft else { return }
        savePlanDraft(draft)
    }

    private func savePlanDraft(_ draft: PlanDraft) {
        guard let board = planSwarm, let goal = goals.selected else { return cancelPlanDraft() }
        let words = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.kind {
        case .replan:
            guard !words.isEmpty else { return say("say what the lead should change") }
            cancelPlanDraft()
            replanSwarm([words])
        case let .answer(question):
            guard !words.isEmpty else { return say("type the answer") }
            cancelPlanDraft()
            answerLead([words], question: question)
        case .reject:
            cancelPlanDraft()
            reject(board, why: words)
        case let .edit(taskID):
            var tasks = goals.planTasks
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return cancelPlanDraft() }
            switch draft.fields.task(id: taskID, in: tasks) {
            case let .failure(error): return say(error.text)
            case let .success(task):
                cancelPlanDraft()
                tasks[index] = task
                changePlan(board, tasks, kind: .edit, text: "edited \(task.title)", follow: taskID)
            }
        case let .add(after):
            var tasks = goals.planTasks
            let taken = Set(tasks.map(\.slug) + goals.items.map(\.slug))
            let id = "\(goal.id)/\(GoalSlug.make(draft.fields.title, taken: taken))"
            switch draft.fields.task(id: id, in: tasks) {
            case let .failure(error): return say(error.text)
            case let .success(task):
                cancelPlanDraft()
                tasks.insert(task, at: min(after + 1, tasks.count))
                changePlan(board, tasks, kind: .add, text: "added \(task.title)", follow: id)
            }
        }
    }

    /// Keys while the swarm form or the plan pane's editor has the keyboard: ⌘↩ saves, ⎋ leaves.
    func answerSwarmText(_ stroke: KeyStroke) -> Bool {
        if goals.swarmForm != nil {
            switch stroke {
            case .escape: cancelSwarmForm()
            case KeyStroke("CR", .command), KeyStroke("s", .command): submitSwarmForm()
            default: return false
            }
            return true
        }
        if goals.planDraft != nil {
            switch stroke {
            case .escape: cancelPlanDraft()
            case KeyStroke("CR", .command), KeyStroke("s", .command): submitPlanDraft()
            default: return false
            }
            return true
        }
        return false
    }

    // MARK: Mouse

    func clickPlanTask(_ index: Int, edit: Bool = false) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.tasks)
        goals.setTaskCursor(index)
        if edit { editPlanTask() }
    }

    /// A click on a task in the merge order: the cursor on it in the outline.
    func clickPlanTaskID(_ id: String) {
        guard let index = goals.shownTasks.firstIndex(where: { $0.id == id }) else { return }
        clickPlanTask(index)
    }

    func clickPlanVersion(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.versions)
        goals.setVersionCursor(index)
    }

    func planTaskMenu(_ index: Int) -> [MenuEntry] {
        let tasks = goals.shownTasks
        guard tasks.indices.contains(index), let board = goals.board else { return [] }
        let task = tasks[index]
        let state = swarmSchedule(board)?.states[task.id]?.state
        return ContextMenus.swarmTask(
            id: task.id, title: task.title, first: index == 0, last: index == tasks.count - 1,
            active: board.swarm.status.active, running: board.swarm.approved != nil,
            paused: state == .paused || state == .stalled, working: liveWorker(on: task.id) != nil,
            owner: task.owner?.agent, agents: swarmAgents,
            stacked: board.swarm.lastWorker(on: task.id)?.stackedOn != nil
        )
    }

    func planVersionMenu(_ index: Int) -> [MenuEntry] {
        guard let board = goals.board, board.versions.indices.contains(index) else { return [] }
        let version = board.versions[index]
        return ContextMenus.swarmVersion(
            number: version.number, current: version.number == board.swarm.plan, active: board.swarm.status.active
        )
    }
}
