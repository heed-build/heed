import Foundation
import HeedCore

/// Evaluations: evaluators (reviewers whose run is a stranger walk) walk the goal's task in a fresh shallow clone, from
/// the README and the CLI only, and keep a friction log. Their walks are recorded as their reviews, through `GoalOps`,
/// so they share the reviewers' budget, scores, items and evidence. The pure parts are in HeedCore (`EvaluationLens`,
/// `EvaluationWalk`, `EvaluationPlanner`, `EvaluationTriggers`, `EvaluationRun`).
extension AppModel {
    // MARK: The pane

    /// `goal.evaluations`: the Evaluations pane, or back to the overview.
    func toggleGoalEvaluations() {
        endGoalEditing()
        if view != .goals {
            view = .goals
            if goals.pane != .evaluations { goals.toggleEvaluations() }
            return
        }
        goals.toggleEvaluations()
    }

    func clickFriction(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.friction)
        goals.setCursor(index)
    }

    func clickLens(_ lens: EvaluationLens) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.pickLens(lens)
    }

    func frictionMenu(_ index: Int) -> [MenuEntry] {
        let rows = goals.friction
        guard let goal = goals.selected, let evaluator = goals.selectedEvaluation?.evaluator,
              rows.indices.contains(index)
        else { return [] }
        let row = rows[index]
        return ContextMenus.friction(
            goal: goal.id, reviewer: evaluator.id, id: row.id, text: row.friction.finding,
            accepted: row.state == .acceptedRisk, fixed: row.state == .fixed
        )
    }

    func lensMenu(_ lens: EvaluationLens) -> [MenuEntry] {
        guard let goal = goals.selected else { return [] }
        let evaluation = goals.evaluations.first { $0.lens == lens }
        return ContextMenus.evaluation(
            goal: goal.id, lens: lens.rawValue, title: lens.title, walking: evaluation?.evaluator?.running ?? false
        )
    }

    /// The evaluator and friction entry a command acts on: a right-click's row (`goal/evaluator[/entry]`), else the
    /// picked lens's and the cursor's.
    private var evalSubject: (goal: HeedGoal, evaluator: ReviewerState?, row: Evaluation.Row?, lens: EvaluationLens)? {
        if case let .row(view: "goals", id: id) = commandTarget {
            let parts = id.split(separator: "/").map(String.init)
            if parts.count >= 2, let goal = goals.snapshot.goal(parts[0]),
               let quality = goals.qualities[goal.id], let evaluator = quality.reviewer(parts[1]),
               let lens = evaluator.config.walk
            {
                let rows = Evaluation.all(quality).first { $0.lens == lens }?.rows ?? []
                let row = parts.count > 2 ? rows.first { $0.id == parts[2] } : nil
                return (goal, evaluator, row, lens)
            }
        }
        guard view == .goals, goals.pane == .evaluations, let goal = goals.selected else { return nil }
        return (
            goal,
            goals.selectedEvaluation?.evaluator,
            goals.focus == .friction ? goals.selectedFriction : nil,
            goals.evalLens
        )
    }

    // MARK: Actions

    /// `eval.lens <1|-1|lens>`: the lens picker.
    func pickEvaluationLens(_ words: [String]) {
        guard let word = words.first else { return goals.stepLens(1) }
        if let delta = Int(word) { return goals.stepLens(delta) }
        guard let lens = EvaluationLens(rawValue: word) else {
            return say("no lens \(word): " + EvaluationLens.allCases.map(\.rawValue).joined(separator: ", "))
        }
        goals.pickLens(lens)
    }

    /// `eval.accept`: accept the friction under the cursor (it costs a quarter of its weight), or open it again.
    func acceptFriction() {
        guard let subject = evalSubject, let evaluator = subject.evaluator, let row = subject.row else {
            return say("no friction here: X opens Evaluations, ⇥ moves to the friction log")
        }
        guard let objection = row.objection, objection.state != .fixed else {
            return say("that one is fixed: the last walk did not meet it")
        }
        let state: Objection.State = objection.state == .acceptedRisk ? .open : .acceptedRisk
        let now = Clock.now
        let table = config.goals.bars
        goals.run { ops in
            try await ops.setObjection(
                goal: subject.goal.id, reviewer: evaluator.id, objection: objection.id, state, now: now, table: table
            )
        } done: { [weak self] result in
            switch result {
            case let .success(quality):
                let score = quality.reviewer(evaluator.id)?.score.map { GoalBarTable.number($0.value) } ?? "–"
                self?.say((state == .acceptedRisk ? "accepted" : "open again") + ": \(evaluator.config.title) now "
                    + score)
                self?.checkDone(subject.goal.id, quality: quality)
                self?.observeTutorNow()
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `eval.fix`: Start work with the friction filled in, the goal named; a HIGH one's item takes the session.
    func fixFriction() {
        guard let subject = evalSubject, let evaluator = subject.evaluator, let row = subject.row else {
            return say("no friction here: X opens Evaluations, ⇥ moves to the friction log")
        }
        let friction = row.friction
        var lines = [
            "Fix this friction a stranger met walking \(subject.lens.title) for the goal \"\(subject.goal.title)\" "
                + "(its GOAL.md: \(Paths.tilde(goals.files.doc(subject.goal.id).path))):",
            "",
            "[\(friction.severity.rawValue)] " + (friction.place.isEmpty ? "" : friction.place + ": ")
                + friction.finding,
        ]
        if let suggestion = friction.suggestion { lines.append("What would have helped: \(suggestion)") }
        if let walk = subject.evaluator?.walks.last, let step = friction.step, walk.steps.indices.contains(step - 1) {
            lines.append("The step: \(walk.steps[step - 1].title)")
        }
        lines.append("After it merges, heed walks again in a fresh clone to see whether it helped.")
        let marker = ReviewEvidence.marker(reviewer: evaluator.id, objection: row.id)
        goals.startingItem = goals.snapshot.items(of: subject.goal.id).first { $0.reason?.hasSuffix(marker) == true }
        openStartWork(prompt: lines.joined(separator: "\n"))
    }

    /// `eval.rewalk [lens]`: the picked lens's evaluator (or the one named) walks again now; a lens with no evaluator
    /// gets one first. Yours, so the budget does not hold it back (it still counts).
    func rewalk(_ words: [String]) {
        guard let subject = evalSubject ?? (view == .goals ? goals.selected.map {
            ($0, goals.selectedEvaluation?.evaluator, nil, goals.evalLens)
        } : nil) else { return say("no goal here") }
        var lens = subject.lens
        if let word = words.first {
            if let named = EvaluationLens(rawValue: word) {
                lens = named
            } else if let named = goals.qualities[subject.goal.id]?.reviewer(word)?.config.walk {
                lens = named
            } else {
                return say("no lens \(word): " + EvaluationLens.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        let goal = subject.goal
        if let evaluator = goals.qualities[goal.id]?.live.first(where: { $0.config.walk == lens }) {
            runReviewers(goal: goal, trigger: .manual, only: [evaluator.id])
            return
        }
        if isFixture || tutor != nil { return say("walks do not run in the fake world") }
        let table = config.goals.bars
        let config = ReviewerConfig(
            id: lens.reviewerID, kind: lens.kind,
            evaluation: EvaluationLens.defaultWalk(of: lens.kind) == lens ? nil : lens
        )
        goals.run { ops in
            try await ops.spawn(config, goal: goal.id, now: Clock.now, table: table)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(spawned):
                say("\(spawned.title) on \(goal.title), walking now")
                runReviewers(goal: goal, trigger: .manual, only: [spawned.id])
            case let .failure(error): say("no evaluator: \(error)")
            }
        }
    }

    // MARK: Walking

    /// The repos the goal's work is in: its sessions', then its ledger entries'.
    private func walkRepos(_ goal: HeedGoal) -> [Repo] {
        let targets = goals.snapshot.links(of: goal.id).sorted { $0.at > $1.at }.map(\.target)
        var repos: [Repo] = []
        for target in targets {
            let found = sessions.first { $0.id == target }?.repos
                ?? ledger.entries[target]?.repos.compactMap { slug -> Repo? in
                    let parts = slug.split(separator: "/")
                    return parts.count == 2 ? Repo(org: String(parts[0]), name: String(parts[1])) : nil
                } ?? []
            for repo in found where !repos.contains(repo) {
                repos.append(repo)
            }
        }
        return repos
    }

    /// What the goal's work touched: each of its sessions' ledger files.
    func goalPaths(_ goal: HeedGoal) -> Set<String> {
        Set(goals.snapshot.links(of: goal.id).flatMap { ledger.entries[$0.target]?.files ?? [] })
    }

    /// An evaluator's walk: its steps (drafted once per GOAL.md version), a fresh shallow clone in a temp folder, its
    /// agent headless there, its walk read and recorded as its review, the folder removed.
    func launchWalk(goal: HeedGoal, state: ReviewerState, trigger: ReviewTrigger, basis: ReviewBasis) {
        guard let lens = state.config.walk else { return }
        let pulls = goalPulls(goal).map { pull in
            ReviewRun.Pull(ref: pull.ref, headBranch: github.pull(pull.ref)?.headBranch, open: pull.state == "open")
        }
        guard let source = EvaluationRun.source(pulls: pulls, repos: walkRepos(goal)) else {
            if trigger == .manual { say("nothing to walk yet: \(goal.title) has no PR and no repo") }
            return
        }
        let newest = goals.snapshot.links(of: goal.id).sorted { $0.at > $1.at }.lazy
            .compactMap { link in
                self.sessions.first { $0.id == link.target } ?? self.history.first { $0.id == link.target }?.session
            }
            .first
        let agentName = state.config.agent
            ?? (config.goals.reviewerAgent.isEmpty ? newest?.agent ?? "claude" : config.goals.reviewerAgent)
        let tier = state.config.tier ?? config.goals.tier(for: state.config.kind)
        let model: String? = tier == .best ? nil
            : config.llm.model(for: agentName) ?? llmStatuses.first { $0.name == agentName }?.detectedModel
        let runID = UUID().uuidString.lowercased()
        let table = config.goals.bars
        let start = ReviewRunStart(
            id: runID, reviewer: state.id, trigger: trigger, basis: basis, agent: agentName, model: model
        )
        goals.run { ops in try await ops.runStarted(start, goal: goal.id, now: Clock.now, table: table) }
        let known = state.objections
        let drafted = WalkDrafter.current(state.draft, version: goal.version)
        let draftCall = drafted == nil && spendGoalCall(goal.id)
        let summarizer = summarizer
        let doc = goals.snapshot.docs[goal.id]?.render() ?? ""
        let keep = repos.map(\.path) + worktrees.map(\.path)
        Task {
            var draft = drafted
            if draft == nil {
                var steps: [String]?
                if draftCall {
                    let answer = try? await summarizer.summarize(
                        kind: .walkDraft, inputs: WalkDrafter.inputs(title: goal.title, doc: doc),
                        instructions: WalkDrafter.instructions(lens), caller: "goals.walk"
                    )
                    steps = answer.flatMap(WalkDrafter.steps)
                }
                let fresh = WalkDraft(
                    reviewer: state.id, lens: lens, goalVersion: goal.version, steps: steps ?? lens.defaultSteps,
                    source: steps == nil ? .defaults : .model
                )
                draft = fresh
                goals.run { ops in try await ops.draftWalk(fresh, goal: goal.id, now: Clock.now, table: table) }
            }
            let outcome = await walk(
                lens: lens, steps: draft?.steps ?? lens.defaultSteps, draftVersion: goal.version, source: source,
                goal: goal.id, reviewer: state.id, runID: runID, agentName: agentName, model: model, known: known,
                keep: keep
            )
            await finishReview(
                goal: goal.id, reviewer: state.id, runID: runID, basis: basis,
                report: outcome.walk.map(ReviewReport.init(walk:)), failure: outcome.failure
            )
        }
    }

    /// Clones, walks and cleans up; the walk, or why there is none.
    private func walk(
        lens: EvaluationLens, steps: [String], draftVersion: Int, source: WalkSource, goal: String, reviewer: String,
        runID: String, agentName: String, model: String?, known: [Objection], keep: [String]
    ) async -> (walk: EvaluationWalk?, failure: String?) {
        guard let agent = settings.agent(agentName) else { return (nil, "no agent \(agentName)") }
        let temp = FileManager.default.temporaryDirectory.path
        let folder = EvaluationRun.folder(temp: temp, goal: goal, reviewer: reviewer, run: runID)
        let clone = EvaluationRun.clonePath(folder: folder, repo: source.repo)
        guard EvaluationRun.isDisposable(clone, temp: temp, keep: keep) else {
            return (nil, "its clone would not be a fresh folder of its own")
        }
        defer {
            if EvaluationRun.isDisposable(folder, temp: temp, keep: keep) {
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for command in EvaluationRun.cloneCommands(source, path: clone) {
                let (path, pathVariable) = await ToolLocator.shared.executable(command[0])
                let result = try await ProcessRunner.run(
                    path ?? command[0], Array(command.dropFirst()), in: folder, environment: ["PATH": pathVariable],
                    timeout: .seconds(300), caller: "goals.walk"
                )
                guard result.succeeded else {
                    return (
                        nil,
                        "could not clone \(source.text): " + result.stderr
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
                    )
                }
            }
        } catch {
            return (nil, "could not clone \(source.text): \(error)")
        }
        let prompt = EvaluationRun.prompt(lens: lens, steps: steps, clone: clone, known: known)
        guard let words = EvaluationRun.headless(
            agent: agent.name, command: agent.command, prompt: prompt, model: model, clone: clone
        ) else {
            return (nil, "walks run headless: \(agent.name) has no headless mode, set [goals] reviewer_agent")
        }
        try? FileManager.default.createDirectory(atPath: clone + "/.heed", withIntermediateDirectories: true)
        let (path, pathVariable) = await ToolLocator.shared.executable(words[0])
        let started = Date()
        let result = try? await ProcessRunner.run(
            path ?? words[0], Array(words.dropFirst()), in: clone, environment: ["PATH": pathVariable],
            timeout: .seconds(Int64(EvaluationRun.timeout)), caller: "goals.walk"
        )
        let measured = Date().timeIntervalSince(started)
        let file = FileManager.default.contents(atPath: EvaluationRun.reportPath(clone: clone))
        let last = (try? String(contentsOfFile: EvaluationRun.lastMessagePath(clone: clone), encoding: .utf8))
            ?? result?.stdout
        let read = EvaluationRun.read(
            file: file, lastMessage: last, lens: lens, draftVersion: draftVersion, measured: measured,
            source: source.text
        )
        if read.walk == nil, result == nil {
            return (nil, "it did not finish in \(Int(EvaluationRun.timeout / 60)) minutes")
        }
        return read
    }

    // MARK: On their own

    /// Each sync, per goal: walks for what changed in their area since the last look, and re-walks after a fix for one
    /// of their findings merged. `merged` are the goal's PRs that merged since the last look; `walk` false only
    /// remembers what the work touched (a merge or a new version walks them already).
    func checkEvaluations(_ goal: HeedGoal, merged: Set<String>, walk: Bool = true) {
        guard let quality = goals.qualities[goal.id] else { return }
        let evaluators = quality.live.filter { $0.config.walk != nil }
        guard !evaluators.isEmpty else { return }
        let paths = goalPaths(goal)
        let fresh = EvaluationTriggers.newPaths(before: goals.seenPaths[goal.id], after: paths)
        goals.seenPaths[goal.id] = paths
        guard walk, config.goals.autoReview else { return }
        for (id, ref) in EvaluationTriggers.fixesMerged(
            quality,
            items: goals.snapshot.items(of: goal.id),
            merged: merged
        ) {
            runReviewers(goal: goal, trigger: .fixMerged(ref), only: [id])
        }
        var seen: Set<String> = []
        for (id, path) in EvaluationTriggers.areaChanged(evaluators: evaluators, paths: fresh)
            where seen.insert(id).inserted
        {
            runReviewers(goal: goal, trigger: .areaChanged(path), only: [id])
        }
    }
}
