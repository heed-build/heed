import Foundation
import HeedCore

/// Quality goalposts and reviewers: the goal's profile decided by a cheap model call on each new GOAL.md version,
/// reviewers run in their own worktrees when the goal's work changes (within the day's budget), their reviews recorded
/// through `GoalOps`, and the goal marked done once every criterion has evidence and every required lens is at its bar.
/// The pure parts are in HeedCore (`GoalProfile`, `GoalScore`, `ReviewPlanner`, `ReviewRun`, `GoalQuality`).
extension AppModel {
    // MARK: The pane

    /// `goal.reviewers`: the Reviewers pane, or back to the overview.
    func toggleGoalReviewers() {
        endGoalEditing()
        if view != .goals {
            view = .goals
            if goals.pane != .reviewers { goals.toggleReviewers() }
            return
        }
        goals.toggleReviewers()
    }

    func clickReviewer(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.reviewers)
        goals.setCursor(index)
    }

    func clickObjection(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.objections)
        goals.setCursor(index)
    }

    func reviewerMenu(_ index: Int) -> [MenuEntry] {
        let reviewers = goals.reviewers
        guard let goal = goals.selected, reviewers.indices.contains(index) else { return [] }
        let reviewer = reviewers[index]
        return ContextMenus.reviewer(
            goal: goal.id, id: reviewer.id, title: reviewer.config.title, running: reviewer.running
        )
    }

    func objectionMenu(_ index: Int) -> [MenuEntry] {
        let objections = goals.objections
        guard let goal = goals.selected, let reviewer = goals.selectedReviewer, objections.indices.contains(index)
        else { return [] }
        let objection = objections[index]
        return ContextMenus.objection(
            goal: goal.id, reviewer: reviewer.id, id: objection.id, text: objection.text,
            accepted: objection.state == .acceptedRisk
        )
    }

    /// The reviewer and objection a command acts on: a right-click's row (`goal/reviewer[/objection]`), else the
    /// cursor's.
    private var reviewSubject: (goal: HeedGoal, reviewer: ReviewerState, objection: Objection?)? {
        if case let .row(view: "goals", id: id) = commandTarget {
            let parts = id.split(separator: "/").map(String.init)
            if parts.count >= 2, let goal = goals.snapshot.goal(parts[0]),
               let reviewer = goals.qualities[goal.id]?.reviewer(parts[1])
            {
                let objection = parts.count > 2 ? reviewer.objections.first { $0.id == parts[2] } : nil
                return (goal, reviewer, objection)
            }
        }
        guard view == .goals, goals.pane == .reviewers, let goal = goals.selected,
              let reviewer = goals.selectedReviewer
        else { return nil }
        return (goal, reviewer, goals.selectedObjection)
    }

    // MARK: Actions

    /// `review.recheck [reviewer]`: in Reviewers, the reviewer under the cursor (or named) looks again now; elsewhere
    /// in Goals, every reviewer the goal needs. Yours, so the budget does not hold it back (it still counts).
    func recheckReviewers(_ words: [String]) {
        guard let goal = (view == .goals ? goals.selected : nil) ?? reviewSubject?.goal else {
            return say("no goal here")
        }
        var only: Set<String>?
        if let name = words.first {
            only = [name]
        } else if let subject = reviewSubject, goals.focus == .reviewers || goals.focus == .objections {
            only = [subject.reviewer.id]
        }
        runReviewers(goal: goal, trigger: .manual, only: only)
    }

    /// `review.accept`: accept the risk of the objection under the cursor, or open an accepted one again.
    func acceptRisk() {
        guard let subject = reviewSubject, let objection = subject.objection else {
            return say("no objection here: R opens Reviewers, ⇥ moves to a reviewer's objections")
        }
        guard objection.state != .fixed else { return say("that one is fixed already") }
        let state: Objection.State = objection.state == .acceptedRisk ? .open : .acceptedRisk
        let now = Clock.now
        let table = config.goals.bars
        goals.run { ops in
            try await ops.setObjection(
                goal: subject.goal.id, reviewer: subject.reviewer.id, objection: objection.id, state, now: now,
                table: table
            )
        } done: { [weak self] result in
            switch result {
            case let .success(quality):
                let score = quality.reviewer(subject.reviewer.id)?.score.map { GoalBarTable.number($0.value) } ?? "–"
                self?.say(state == .acceptedRisk ? "risk accepted: \(subject.reviewer.config.title) now \(score)"
                    : "open again: \(subject.reviewer.config.title) now \(score)")
                self?.checkDone(subject.goal.id, quality: quality)
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `review.fix`: Start work with the objection filled in, and the goal named.
    func fixObjection() {
        guard let subject = reviewSubject, let objection = subject.objection else {
            return say("no objection here: R opens Reviewers, ⇥ moves to a reviewer's objections")
        }
        var lines = [
            "Fix this objection from the \(subject.reviewer.config.kind.title.lowercased()) on the goal "
                + "\"\(subject.goal.title)\" (its GOAL.md: \(Paths.tilde(goals.files.doc(subject.goal.id).path))):",
            "",
            "[\(objection.severity.rawValue)] \(objection.text)",
        ]
        if let evidence = objection.evidence { lines.append("Evidence: \(evidence)") }
        if let file = objection.file { lines.append("File: \(file)") }
        perform(CommandInvocation(name: "work.start", arguments: [lines.joined(separator: "\n")]))
    }

    /// `review.why`: a chat seeded with the reviewer's review, asking it to explain.
    func askReviewerWhy() {
        guard let subject = reviewSubject else { return say("no reviewer here: R opens Reviewers") }
        let reviewer = subject.reviewer
        var lines = [
            "You are the \(reviewer.config.kind.title.lowercased()) for the goal \"\(subject.goal.title)\" (its "
                + "GOAL.md: \(Paths.tilde(goals.files.doc(subject.goal.id).path))). Here is your last review; explain "
                + "your reasoning and answer my questions about it.",
            "",
            "Score: \(reviewer.score.map { GoalBarTable.number($0.value) } ?? "–") (\(reviewer.score?.basis ?? "not scored yet"))",
        ]
        if !reviewer.summary.isEmpty { lines.append("Summary: \(reviewer.summary)") }
        for objection in reviewer.ordered {
            lines.append("- [\(objection.severity.rawValue), \(objection.state.text)] \(objection.text)"
                + (objection.evidence.map { " (evidence: \($0))" } ?? ""))
        }
        if let objection = subject.objection {
            lines += ["", "Why is this one \(objection.severity.rawValue)? \(objection.text)"]
        }
        perform(CommandInvocation(name: "chat.new", arguments: [lines.joined(separator: "\n")]))
    }

    /// `reviewer.spawn [kind]`: a reviewer on the goal, as the spawn panel says (or of the kind given). Custom ones
    /// need their instructions.
    func spawnReviewer(_ words: [String]) {
        guard let goal = goals.selected else { return say("no goal here") }
        var draft = goals.spawn
        if let name = words.first {
            guard let kind = ReviewerKind(rawValue: name) else {
                return say("no reviewer kind \(name): " + ReviewerKind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            draft.kind = kind
            if kind == .custom, words.count > 1 { draft.instructions = words.dropFirst().joined(separator: " ") }
        }
        if draft.kind == .custom, draft.instructions.trimmingCharacters(in: .whitespaces).isEmpty {
            view = .goals
            if goals.pane != .reviewers { goals.toggleReviewers() }
            goals.spawn.kind = .custom
            goals.spawnTyping = true
            textInputActive = true
            return say("a custom reviewer needs its instructions: type them, ⌘↩ spawns it")
        }
        let table = config.goals.bars
        let reviewer = ReviewerConfig(
            id: draft.kind.rawValue, kind: draft.kind,
            instructions: draft.kind == .custom ? draft.instructions : nil, policy: draft.policy, agent: draft.agent,
            tier: draft.tier
        )
        let now = Clock.now
        goals.run { ops in
            try await ops.spawn(reviewer, goal: goal.id, now: now, table: table)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(spawned):
                goals.spawn.instructions = ""
                if goals.pane != .reviewers { goals.toggleReviewers() }
                goals.point(reviewer: spawned.id)
                let required = spawned.kind.lens
                    .map { goals.qualities[goal.id]?.lenses.map(\.lens).contains($0) ?? false }
                say("\(spawned.title) on \(goal.title)" + (required == false
                        ? ": its lens is not required, so it runs only when you press r"
                        : ", looking now"))
                if required != false { runReviewers(goal: goal, trigger: .manual, only: [spawned.id]) }
            case let .failure(error): say("no reviewer: \(error)")
            }
        }
    }

    /// Keys while the custom reviewer's instructions are typed.
    func answerSpawnText(_ stroke: KeyStroke) -> Bool {
        guard goals.spawnTyping else { return false }
        switch stroke {
        case .escape:
            goals.spawnTyping = false
            textInputActive = false
        case KeyStroke("CR", .command):
            goals.spawnTyping = false
            textInputActive = false
            spawnReviewer([])
        default: return false
        }
        return true
    }

    /// `reviewer.remove`: the reviewer under the cursor off the goal; its history stays.
    func removeReviewer() {
        guard let subject = reviewSubject else { return say("no reviewer here: R opens Reviewers") }
        let table = config.goals.bars
        var removed = subject.reviewer.config
        removed.removed = true
        let reviewer = removed
        let now = Clock.now
        let goal = subject.goal
        goals.run { ops in
            try await ops.spawn(reviewer, goal: goal.id, now: now, table: table)
        } done: { [weak self] result in
            if case let .failure(error) = result { return self?.say("\(error)") ?? () }
            self?.say("\(subject.reviewer.config.title) is off \(goal.title)")
        }
    }

    /// `goal.bar <lens> <bar|off|auto>`: pins a bar for the goal under the cursor.
    func pinGoalBar(_ words: [String]) {
        guard let goal = goals.selected else { return say("no goal here") }
        let lenses = GoalLens.allCases.map(\.rawValue).joined(separator: ", ")
        guard words.count == 2, let lens = GoalLens(rawValue: words[0].lowercased()) else {
            return words.isEmpty ? openCommandLine("goal.bar ") : say("goal.bar <\(lenses)> <0-10|off|auto>")
        }
        var pins = goals.qualities[goal.id]?.pins ?? [:]
        switch words[1].lowercased() {
        case "off": pins[lens] = 0
        case "auto": pins[lens] = nil
        default:
            guard let bar = Double(words[1]), (0 ... 10).contains(bar) else { return say("a bar is 0 to 10") }
            pins[lens] = bar
        }
        let now = Clock.now
        let table = config.goals.bars
        let pinned = pins
        goals.run { ops in
            try await ops.pin(goal: goal.id, pinned, now: now, table: table)
        } done: { [weak self] result in
            switch result {
            case let .success(quality):
                let bar = quality.lenses.first { $0.lens == lens }?.bar
                self?
                    .say("\(lens.title) on \(goal.title): " +
                        (bar.map { "bar \(GoalBarTable.number($0))" } ?? "not required"))
                self?.checkDone(goal.id, quality: quality)
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `goal.reopen`: undo heed marking the goal done; it stays open until what made it done changes.
    func reopenGoal() {
        let id = (view == .goals ? goals.selected?.id : nil) ?? attentionSelected
            .flatMap { GoalAttention.goal(of: $0.item) }
        guard let id, let goal = goals.snapshot.goal(id) else { return say("no goal here") }
        guard goal.status == .done else { return say("\(goal.title) is not done") }
        let now = Clock.now
        let table = config.goals.bars
        goals.run { ops in
            try await ops.markDone(goal: id, false, now: now, table: table)
        } done: { [weak self] result in
            if case let .failure(error) = result { return self?.say("\(error)") ?? () }
            self?.say("\(goal.title) is open again; heed waits for something new before calling it done")
        }
    }

    // MARK: Running reviewers

    /// What the goal's reviews look at now: its GOAL.md version and each of its PRs' heads.
    func reviewBasis(_ goal: HeedGoal) -> ReviewBasis {
        ReviewBasis(goalVersion: goal.version, heads: goalPulls(goal).compactMap { pull in
            pull.head.map { "\(pull.ref.description)@\($0)" }
        })
    }

    /// The goal's PRs with their heads (the commit when heed has the PR's details, else when it last changed) and
    /// states.
    func goalPulls(_ goal: HeedGoal) -> [(ref: PullRef, head: String?, state: String)] {
        goalOverview(goal).pulls.map { pull in
            let head = pullDetails[pull.ref.description]?.headSHA
                ?? github.pull(pull.ref).map { String(Int($0.updatedAt.timeIntervalSince1970)) }
            return (pull.ref, head, pull.state)
        }
    }

    /// Plans and starts the goal's reviewers for `trigger`; the over-budget ones wait in Attention. The plan, for
    /// `heed goal review request`; nil when nothing was planned.
    @discardableResult
    func runReviewers(goal: HeedGoal, trigger: ReviewTrigger, only: Set<String>? = nil) -> ReviewPlan? {
        guard let quality = goals.qualities[goal.id] else { return nil }
        if isFixture || tutor != nil {
            say("reviewers do not run in the fake world")
            return nil
        }
        let bars = quality.lenses.reduce(into: [GoalLens: Double]()) { $0[$1.lens] = $1.bar }
        let basis = reviewBasis(goal)
        let used = ReviewPlanner.used(quality.runs, now: Clock.now)
        // Evaluators walk on their own plan (`EvaluationPlanner`), after the reviewers, from the same budget.
        let plan = ReviewPlanner.plan(
            trigger: trigger, only: only, reviewers: quality.live.filter { $0.config.walk == nil }, bars: bars,
            basis: basis, used: used, limit: config.goals.reviewerRunsPerDay
        )
        let walks = EvaluationPlanner.plan(
            trigger: trigger, only: only, evaluators: quality.live.filter { $0.config.walk != nil }, bars: bars,
            required: Set(EvaluationLens.required(profile: quality.profile?.profile, bars: bars)),
            used: used + (trigger == .manual ? 0 : plan.run.count), limit: config.goals.reviewerRunsPerDay
        )
        goals.setWaiting(goal.id, plan.overBudget + walks.overBudget)
        if trigger == .manual, plan.run.isEmpty, walks.run.isEmpty {
            let quiet = plan.quiet.values.first ?? walks.quiet.values.first
            say(quiet.map { "nothing to re-check: \($0)" } ?? "no reviewers on \(goal.title)")
            return ReviewPlan(quiet: plan.quiet.merging(walks.quiet) { first, _ in first })
        }
        for id in walks.run {
            guard let state = quality.reviewer(id) else { continue }
            launchWalk(goal: goal, state: state, trigger: trigger, basis: basis)
        }
        for id in plan.run {
            guard let state = quality.reviewer(id) else { continue }
            launchReviewer(
                goal: goal,
                state: state,
                trigger: trigger,
                basis: basis,
                bar: state.config.kind.lens
                    .flatMap { bars[$0] }
            )
        }
        let started = plan.run + walks.run
        if trigger == .manual, !started.isEmpty {
            let title = quality.reviewer(started[0])?.config.title ?? "the reviewer"
            say(started.count == 1 ? title + (walks.run.isEmpty ? " is looking" : " is walking, in a fresh clone")
                : "\(started.count) reviewers are looking")
        }
        return plan
    }

    /// Where a goal's reviewer runs (`ReviewRun.place`): its open PR's head, else a branch its work is on, from a
    /// clone on this Mac; in a tab of an open session on the goal when there is one, else headless.
    private func reviewPlace(_ goal: HeedGoal) -> ReviewPlace {
        let links = goals.snapshot.links(of: goal.id).sorted { $0.at > $1.at }
        let open = links.filter { $0.kind == .session }.compactMap { link in sessions.first { $0.id == link.target } }
        let pulls = goalPulls(goal).map { pull in
            ReviewRun.Pull(ref: pull.ref, headBranch: github.pull(pull.ref)?.headBranch, open: pull.state == "open")
        }
        let branches: [(repo: Repo, branch: String)] = links.compactMap { link in
            guard let entry = ledger.entries[link.target], let slug = entry.repos.first else { return nil }
            let parts = slug.split(separator: "/")
            guard parts.count == 2 else { return nil }
            return (Repo(org: String(parts[0]), name: String(parts[1])), entry.branch)
        }
        return ReviewRun.place(pulls: pulls, sessions: open, worktrees: worktrees, repos: repos, branches: branches)
    }

    private func launchReviewer(
        goal: HeedGoal, state: ReviewerState, trigger: ReviewTrigger, basis: ReviewBasis, bar: Double?
    ) {
        let runID = UUID().uuidString.lowercased()
        let table = config.goals.bars
        let target: ReviewTarget
        switch reviewPlace(goal) {
        case let .target(found):
            target = found
            goals.setBlocked(goal.id, nil)
        case let .noClone(repo):
            goals.setBlocked(goal.id, "\(repo.slug) is not cloned on this Mac")
            return
        case .nothing:
            // Nothing to look at yet: the next PR or branch on the goal is a trigger of its own.
            return
        }
        let host = target.host.flatMap { id in sessions.first { $0.id == id } }
        let newest = goals.snapshot.links(of: goal.id).sorted { $0.at > $1.at }
            .lazy
            .compactMap { link in
                self.sessions.first { $0.id == link.target } ?? self.history.first { $0.id == link.target }?
                    .session
            }
            .first
        let agentName = state.config.agent
            ?? (config.goals.reviewerAgent.isEmpty ? (host ?? newest)?.agent ?? "claude" : config.goals.reviewerAgent)
        let tier = state.config.tier ?? config.goals.tier(for: state.config.kind)
        let model: String? = tier == .best ? nil
            : config.llm.model(for: agentName) ?? llmStatuses.first { $0.name == agentName }?.detectedModel
        let doc = goals.versions.first { $0.goal == goal.id && $0.number == goal.version }?.text
            ?? goals.snapshot.docs[goal.id]?.render() ?? ""
        let changed = [trigger.text]
        let reviewer = state.config
        let known = state.objections
        let prompt: (String) -> String = { worktree in
            ReviewRun.prompt(
                config: reviewer, goalTitle: goal.title, doc: doc, bar: bar, changed: changed, worktree: worktree,
                known: known
            )
        }
        let start = ReviewRunStart(
            id: runID, reviewer: state.id, trigger: trigger, basis: basis, agent: agentName, model: model
        )
        goals.run { ops in try await ops.runStarted(start, goal: goal.id, now: Clock.now, table: table) }
        Task {
            let failure: String? = if let host {
                await startReviewRun(
                    runID: runID, goal: goal.id, reviewer: state.id, session: host.id, record: target.record,
                    branch: target.branch, repo: target.repo, agentName: agentName, model: model, basis: basis,
                    prompt: prompt
                )
            } else {
                await runHeadlessReview(
                    runID: runID, goal: goal.id, reviewer: state.id, target: target, agentName: agentName,
                    model: model, basis: basis, prompt: prompt
                )
            }
            if let failure {
                let result = ReviewResult(run: runID, reviewer: state.id, basis: basis, report: nil, failure: failure)
                goals.run { ops in try await ops.reviewEnded(result, goal: goal.id, now: Clock.now, table: table) }
            }
        }
    }

    /// A reviewer with no session to show it: its worktree from the clone, its agent headless there
    /// (`ReviewRun.headless`), its review read, its worktree removed. Nil when it ran (the review is recorded), else
    /// why it could not start.
    private func runHeadlessReview(
        runID: String, goal: String, reviewer: String, target: ReviewTarget, agentName: String, model: String?,
        basis: ReviewBasis, prompt: (String) -> String
    ) async -> String? {
        guard let agent = settings.agent(agentName) else { return "no agent \(agentName)" }
        guard target.record.location.isLocal else { return "\(target.repo.slug) is not cloned on this Mac" }
        let root = Runs.worktreeRoot(local: settings.worktreeRoot, host: nil, hosts: config.hosts)
        let runBranch = ReviewRun.branch(goal: goal, reviewer: reviewer)
        let worktree: String
        do {
            worktree = try await Git.addRunWorktree(
                target.record, path: ReviewRun.worktreePath(
                    root: root,
                    repo: target.repo,
                    goal: goal,
                    reviewer: reviewer
                ),
                branch: target.branch, runBranch: runBranch
            )
        } catch {
            return "could not make its worktree: \(error)"
        }
        guard let words = ReviewRun.headless(
            agent: agent.name, command: agent.command, prompt: prompt(worktree), model: model, worktree: worktree
        ) else {
            await Git.removeWorktree(target.record, path: worktree, branch: runBranch)
            return "\(agent.name) runs only in a tab: open a session on the goal, or set [goals] reviewer_agent"
        }
        try? FileManager.default.createDirectory(atPath: worktree + "/.heed", withIntermediateDirectories: true)
        let (path, pathVariable) = await ToolLocator.shared.executable(words[0])
        let result = try? await ProcessRunner.run(
            path ?? words[0], Array(words.dropFirst()), in: worktree, environment: ["PATH": pathVariable],
            timeout: .seconds(Int64(ReviewRun.timeout)), caller: "goals.review"
        )
        let file = FileManager.default.contents(atPath: ReviewRun.reportPath(worktree: worktree))
        let last = (try? String(contentsOfFile: ReviewRun.lastMessagePath(worktree: worktree), encoding: .utf8))
            ?? result?.stdout
        await Git.removeWorktree(target.record, path: worktree, branch: runBranch)
        let read = ReviewRun.read(file: file, lastMessage: last)
        let failure = result == nil ? "it did not finish in \(Int(ReviewRun.timeout / 60)) minutes" : read.failure
        await finishReview(
            goal: goal, reviewer: reviewer, runID: runID, basis: basis, report: read.report,
            failure: read.report == nil ? failure : nil
        )
        return nil
    }

    /// A reviewer run ended: its objections matched to the ones before (by id and words, then a cheap model for
    /// what is left), recorded, and the goal checked for done.
    func finishReview(
        goal: String, reviewer: String, runID: String, basis: ReviewBasis, report: ReviewReport?, failure: String?
    ) async {
        let live = (goal: goal, reviewer: reviewer, runID: runID, basis: basis)
        let known = goals.qualities[live.goal]?.reviewer(live.reviewer)?.objections ?? []
        var pairs: [Int: String] = [:]
        if let report {
            pairs = await ObjectionMatch.ask(
                known: known, raised: report.objections, decider: decider(caller: "goals.objections"),
                subject: "goal:\(live.goal)"
            )
        }
        let result = ReviewResult(
            run: live.runID, reviewer: live.reviewer, basis: live.basis, report: report, failure: failure, pairs: pairs
        )
        let table = config.goals.bars
        let goal = live.goal
        goals.run { ops in
            try await ops.reviewEnded(result, goal: goal, now: Clock.now, table: table)
        } done: { [weak self] outcome in
            guard let self, case let .success(quality) = outcome else { return }
            let title = quality.reviewer(live.reviewer)?.config.title ?? live.reviewer
            if let failure {
                say("\(title) wrote no review: \(failure)")
            } else if let score = quality.reviewer(live.reviewer)?.score {
                let high = quality.reviewer(live.reviewer)?.open.count { $0.severity == .high } ?? 0
                say("\(title): \(GoalBarTable.number(score.value))" + (high > 0 ? ", \(high) high" : ""))
            }
            checkDone(goal, quality: quality)
        }
    }

    // MARK: On their own

    /// Each sync: profiles for new GOAL.md versions, reviewers for what changed (PRs opened, updated or merged, a new
    /// version, the nightly sweep), and goals that are done.
    func checkGoalQuality() {
        guard !isFixture, tutor == nil, goals.ops != nil else { return }
        goals.table = config.goals.bars
        let now = Clock.now
        let nightly = ReviewPlanner.nightlyDue(last: goals.lastNightly, now: now)
        if nightly { goals.lastNightly = now }
        for goal in goals.snapshot.goals where goal.status == .active {
            let quality = goals.qualities[goal.id]
            if quality?.profile == nil || (quality?.profile?.goalVersion ?? 0) < goal.version {
                decideProfile(goal)
            }
            let pulls = goalPulls(goal)
            let now = Dictionary(pulls.map { ($0.ref.description, (head: $0.head, state: $0.state)) }) { first, _ in
                first
            }
            var triggers: [ReviewTrigger] = []
            if let before = goals.seenPulls[goal.id] { triggers += ReviewTrigger.from(before: before, after: now) }
            goals.seenPulls[goal.id] = now
            if let version = goals.seenVersions[goal.id],
               version < goal.version { triggers.append(.goalVersion(goal.version)) }
            goals.seenVersions[goal.id] = goal.version
            if nightly { triggers.append(.nightly) }
            if config.goals.autoReview, let trigger = triggers.first { runReviewers(goal: goal, trigger: trigger) }
            // Walks of their own: a change in their area, a fix for a finding merged; not when a merge or a new
            // version walks them already.
            let merged = Set(triggers.compactMap { trigger -> String? in
                if case let .prMerged(ref) = trigger { return ref }
                return nil
            })
            let walking = triggers.first.map { trigger in
                if case .prMerged = trigger { return true }
                if case .goalVersion = trigger { return true }
                return false
            } ?? false
            checkEvaluations(goal, merged: walking ? [] : merged, walk: !walking)
            if let quality { checkDone(goal.id, quality: quality) }
        }
    }

    /// Asks a cheap model what the goal is (stakes and flags), once per GOAL.md version; the bars follow, raised or
    /// lowered, with a note.
    private func decideProfile(_ goal: HeedGoal) {
        guard !goals.deciding.contains(goal.id) else { return }
        goals.deciding.insert(goal.id)
        let doc = goals.snapshot.docs[goal.id]?.render() ?? ""
        let mine = goals.snapshot.links(of: goal.id).map(\.target)
        let owned = sessions.filter { mine.contains($0.id) }
        let repos = Array(Set(owned.flatMap { $0.repos.map(\.slug) })).sorted()
        let paths = Array(Set(mine.flatMap { ledger.entries[$0]?.files ?? [] })).sorted()
        let decider = decider(caller: "goals.profile")
        let table = config.goals.bars
        let version = goal.version
        Task {
            defer { goals.deciding.remove(goal.id) }
            guard let profile = await GoalProfile.decide(
                goal: goal.id, doc: doc, repos: repos, paths: paths, decider: decider
            ) else { return }
            goals.run { ops in
                try await ops.setProfile(goal: goal.id, profile, now: Clock.now, table: table)
            } done: { [weak self] result in
                guard let self, case let .success(decision?) = result else { return }
                if !decision.changes.isEmpty { say("\(goal.title) v\(version): \(decision.note)") }
                // Reviewers new to the goal look for the first time.
                if config.goals.autoReview, let fresh = goals.snapshot.goal(goal.id) {
                    runReviewers(goal: fresh, trigger: .goalVersion(version))
                }
            }
        }
    }

    /// Marks the goal done when it is (every criterion with evidence, every required lens at its bar) and you did not
    /// undo that for what is true now. Undo: `goal.reopen`.
    func checkDone(_ id: String, quality: GoalQuality) {
        guard !isFixture, let goal = goals.snapshot.goal(id), goal.status == .active,
              quality.shouldMarkDone else { return }
        let table = config.goals.bars
        goals.run { ops in
            try await ops.markDone(goal: id, true, now: Clock.now, table: table)
        } done: { [weak self] result in
            guard case .success = result else { return }
            let key = self?.keyText(for: "goal.reopen", in: "goals") ?? ""
            self?.say("\(goal.title) is done: every criterion has evidence and every lens is at its bar. "
                + (key.isEmpty ? ":goal.reopen" : key) + " undoes")
        }
    }

    /// Goals' Attention items: goals heed marked done, reviewers waiting for budget, spawns waiting past the cap,
    /// swarms
    /// paused at a limit.
    var goalAttentionItems: [AttentionItem] {
        GoalAttention.items(
            goals: goals.snapshot.goals, qualities: goals.qualities, waiting: goals.waiting, blocked: goals.blocked,
            spawns: goals.heldSpawns, swarms: goals.snapshot.swarms,
            boards: steeringBoards.values.sorted { $0.swarm.id < $1.swarm.id }, now: Clock.now
        )
    }
}
