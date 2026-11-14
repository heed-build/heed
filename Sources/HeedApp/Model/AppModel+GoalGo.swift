import Foundation
import HeedCore

/// Steps 5 and 6 of the wizard: How careful (a level, `1 2 3`, its details under `Q`) and Go (five rows, `j k` and
/// `h l` or a number, `⌘↩` starts, `S` saves for later). The pure parts are HeedCore's (`CarePlan`, `CareSuggestion`,
/// `GoChoices`, `GoForecast`, `GoLaunch`, `GoalOps.go`); this keeps the choices on the wizard and starts the swarm.
extension AppModel {
    func performGo(_ command: CommandInvocation) -> Bool {
        let word = command.arguments.first ?? ""
        switch command.name {
        case "careful.pick": pickCare(word)
        case "go.row": moveGoRow(Int(word) ?? 1)
        case "go.pick": pickGo(Int(word) ?? 1)
        case "go.step": stepGo(Int(word) ?? 1)
        case "go.start": startGoal()
        case "go.save": saveGoalForLater()
        default: return false
        }
        updateScope()
        return true
    }

    // MARK: How careful

    /// What is riding on the goal, as its quality record has it (nil: heed has not worked it out).
    func goalProfile(_ goal: String) -> GoalProfile? {
        if isFixture, goal == SplitFixtures.complexID { return SplitFixtures.profile }
        return goals.qualities[goal]?.profile?.profile
    }

    func careSuggestion(_ goal: String) -> CareSuggestion {
        let parts = goals.wizard.wizard(of: goal)?.split?.active ?? []
        var repos: [String] = []
        for name in parts.compactMap(\.repoName) where !repos.contains(name) {
            repos.append(name)
        }
        return CareSuggestion.of(profile: goalProfile(goal), parts: parts.count, repos: repos)
    }

    /// The level that applies: the one you picked, else heed's suggestion.
    func careLevel(_ goal: String) -> CareLevel {
        goals.wizard.wizard(of: goal)?.careful ?? careSuggestion(goal).level
    }

    func carePlan(_ goal: String) -> CarePlan {
        CarePlan.of(careLevel(goal), profile: goalProfile(goal), table: config.goals.bars)
    }

    /// `careful.pick <1|2|3>`.
    func pickCare(_ word: String) {
        guard let goal = goals.wizard.open, let level = CareLevel(word: word) else { return }
        change(goal) { $0.careful = level }
    }

    // MARK: Go

    /// The choices as set, else the defaults for the split.
    func goChoices(_ goal: String) -> GoChoices {
        if let choices = goals.wizard.wizard(of: goal)?.go { return choices }
        guard let split = goals.wizard.wizard(of: goal)?.split else { return GoChoices() }
        let stats = SplitStats(draft: split, schedule: SplitSchedule.make(split.parts), fleet: goals.wizard.fleet)
        return GoChoices.defaults(for: split, extra: stats.extra)
    }

    func goForecast(_ goal: String) -> GoForecast? {
        guard let split = goals.wizard.wizard(of: goal)?.split, split.drafted else { return nil }
        return GoForecast.of(
            draft: split, choices: goChoices(goal), care: carePlan(goal), fleet: goals.wizard.fleet,
            now: goStartedAt(goal) ?? Clock.now
        )
    }

    /// When the swarm Go started began running; nil before Go.
    func goStartedAt(_ goal: String) -> Date? {
        guard let id = goals.wizard.wizard(of: goal)?.swarm else { return nil }
        return goals.snapshot.swarms.first { $0.id == id }?.runningAt
    }

    private func moveGoRow(_ delta: Int) {
        let rows = GoChoices.Row.allCases.count
        goals.wizard.goRow = min(max(goals.wizard.goRow + delta, 0), rows - 1)
    }

    private var goRow: GoChoices
        .Row { GoChoices.Row.allCases[min(goals.wizard.goRow, GoChoices.Row.allCases.count - 1)] }

    /// `go.pick <n>`: option n on the row under the cursor.
    private func pickGo(_ number: Int) {
        guard let goal = goals.wizard.open else { return }
        var choices = goChoices(goal)
        choices.pick(goRow, number - 1)
        change(goal) { $0.go = choices }
    }

    /// `go.step <1|-1>`: the next or previous option on the row.
    private func stepGo(_ delta: Int) {
        guard let goal = goals.wizard.open else { return }
        var choices = goChoices(goal)
        choices.step(goRow, by: delta)
        change(goal) { $0.go = choices }
    }

    /// `S`: the wizard keeps Go's choices and its place; the goal waits in the list until `↩` comes back.
    private func saveGoalForLater() {
        guard let goal = goals.wizard.open else { return }
        let choices = goChoices(goal)
        change(goal) { $0.go = choices }
        leaveWizard()
        say("saved: the goal waits at Go; ↩ on it, then ⌘↩ starts it")
    }

    /// `⌘↩` on Go: the level on the goal, the swarm started on the split (approved, running), its lead started, and
    /// the goal's page. Workers start on the next tick, as helpers or in the lead's session per Who works.
    func startGoal() {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.wizard(of: goal) else { return }
        guard let split = wizard.split, split.drafted, !split.active.isEmpty else {
            return say("nothing to start: Split has no parts yet")
        }
        if let swarm = wizard.swarm { return say("it started already: \(swarm)") }
        let care = carePlan(goal)
        let choices = goChoices(goal)
        let launch = GoLaunch.of(
            draft: split, choices: choices, care: care, repos: goalRepoSlugs(goal),
            defaultAgent: settings.defaultAgent
        )
        let table = config.goals.bars
        let now = Clock.now
        busy(goal, "starting \(split.active.count) parts")
        goals.run { ops in
            try await ops.go(goal: goal, launch: launch, care: care, now: now, table: table)
        } done: { [weak self] result in
            guard let self else { return }
            busy(goal, nil)
            switch result {
            case let .success(swarm):
                var done = wizard
                done.careful = care.level
                done.go = choices
                done.complete(.careful)
                done.complete(.go)
                done.swarm = swarm.id
                goals.wizard.set(done)
                goals.wizard.open = nil
                goals.wizard.resetCursors()
                goals.point(to: goal)
                goals.show(.overview)
                updateScope()
                observeTutorNow()
                startLead(swarm)
                tickSwarms()
                let forecast = GoForecast.of(
                    draft: split, choices: choices, care: care, fleet: goals.wizard.fleet, now: now
                )
                say("started: \(forecast.startNow) part\(forecast.startNow == 1 ? "" : "s") now, "
                    + "\(forecast.hoursText); what needs you lands in Attention and gy")
            case let .failure(error): failed(goal, error)
            }
        }
    }
}

// MARK: The goals list

extension AppModel {
    /// A goal with a page's row in the list, from the page: its agents and its swarm, its parts and criteria, and the
    /// page's one next step. Nil: the row as any goal's.
    struct PageRow {
        var subline: String
        var progress: String
        var next: GoalNextStep?
    }

    func pageRow(_ goal: HeedGoal) -> PageRow? {
        guard goals.wizard.wizard(of: goal.id)?.swarm != nil, let page = goalPage(goal.id) else { return nil }
        let agents = Set(page.draft.active.compactMap(\.agent)).count
        let swarm = goals.snapshot.activeSwarm(of: goal.id)
        var subline = ["\(agents) agent\(agents == 1 ? "" : "s")"]
        if let swarm { subline.append("swarm \(swarm.status.rawValue)") }
        subline.append("v\(goal.version)")
        let progress = goals.progress(of: goal)
        let criteria = progress.criteria.isEmpty ? "no criteria"
            : "\(progress.criteriaMet)/\(progress.criteria.count) criteria"
        return PageRow(
            subline: subline.joined(separator: " · "), progress: "\(page.done)/\(page.total) parts · \(criteria)",
            next: page.next
        )
    }
}

// MARK: Workers as helpers

extension AppModel {
    /// A swarm worker as a helper (`SwarmSettings.helpers`): the helper starts in the worktree the swarm made, and the
    /// worker is recorded as any other, its "pane" the helper (`helper:<id>`), so the goal's page and the scheduler
    /// read it the same way. Its PR is found by its branch when it opens one.
    func startWorkerHelper(
        swarm: GoalSwarm, goal: HeedGoal, task: SwarmTask, number: String, owner: GoalItem.Owner, record: RepoRecord,
        branch: String, base: String, stackedOn: String?, worktree: String, setup: [String], session: String?,
        prompt: String, now: Date
    ) async {
        let id = UUID().uuidString.lowercased()
        let started = await startPartHelper(
            agent: owner.agent, record: record, title: "\(number) \(task.title)", branch: branch, worktree: worktree,
            setup: setup, sessionID: session, worker: id, prompt: prompt
        )
        let worker = SwarmWorker(
            id: id, task: task.id, owner: owner, host: session ?? swarm.lead ?? "", repo: record.repo.slug,
            branch: branch, base: base, stackedOn: stackedOn, worktree: worktree, startedAt: now
        )
        switch started {
        case let .failure(error):
            _ = await goalOp { ops in
                try await ops.startWorker(swarm: swarm.id, worker, text: "\(number) \(task.title): no helper", now: now)
                return try await ops.endWorker(
                    swarm: swarm.id, worker: id, outcome: .failed(error.text), cost: nil, now: now
                )
            }
            say("swarm \(swarm.number): \(task.title) did not start: \(error.text)")
        case let .success(helper):
            let pane = "helper:\(helper)"
            liveWorkers[id] = LiveWorker(
                id: id, swarm: swarm.id, goal: goal.id, task: task.id, sessionID: session ?? "", tabID: "",
                paneID: pane, agent: owner.agent, worktree: worktree, startedAt: now
            )
            runStates[pane] = .working
            let text = "\(number) \(task.title): \(owner.label) as a helper, from \(base)"
            _ = await goalOp { try await $0.startWorker(swarm: swarm.id, worker, text: text, now: now) }
            say("swarm \(swarm.number): \(text)")
        }
    }
}
