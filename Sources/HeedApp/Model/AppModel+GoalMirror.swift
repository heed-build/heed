import AppKit
import HeedCore

/// Goals' GitHub mirror: the tracker a goal follows along in, turning it on (the one confirmation), the sync on heed's
/// GitHub schedule, and what colleagues do there coming back as asks (an item done?) and GOAL.md proposals. Every
/// change goes through `GoalOps`, every GitHub call through `GoalMirrorSync` (gh, a `github` row each in `:log`).
/// Fixtures and the tutor never reach GitHub: their mirrors are `GoalMirrorFixtures`.
extension AppModel {
    /// The mirror's sync, once the goals' store is open (never in fixtures or the tutor).
    var goalMirror: GoalMirrorSync? {
        guard !isFixture, tutor == nil, let ops = goals.ops else { return nil }
        if let sync = goals.mirrorSync { return sync }
        let sync = GoalMirrorSync(ops: ops, github: GitHubMirror())
        goals.mirrorSync = sync
        return sync
    }

    /// The goal a mirror command acts on: the one right-clicked, else the one selected in Goals.
    private var mirrorSubject: HeedGoal? {
        if case let .row("goals", id)? = commandTarget, let goal = goals.snapshot.goal(id) { return goal }
        return view == .goals ? goals.selected : nil
    }

    // MARK: Commands

    /// `goal.mirror` (M): mirroring on, after a read-only check that the tracker can take it; again: off. On is the
    /// one confirmation: from then on heed writes there on its own.
    func toggleGoalMirror() {
        guard let goal = mirrorSubject else { return say("no goal here") }
        let state = goals.mirror(of: goal.id)
        if state.on {
            return goals.run { ops in try await ops.setMirror(goal: goal.id, on: false) } done: { [weak self] result in
                if case let .failure(error) = result { return self?.say("\(error)") ?? () }
                self?.goals.reloadMirrors()
                self?.say("\(goal.title) no longer mirrors: its issues stay as they are")
            }
        }
        guard let repo = goal.tracker?.repo else {
            return openCommandLine("goal.tracker " + (config.goals.mirror.tracker(for: goalRepo(goal)) ?? ""))
        }
        guard let sync = goalMirror else { return say(isFixture ? "fixture: nothing goes to GitHub" : "goals are off") }
        say("checking \(repo)…")
        Task { [weak self] in
            guard let self else { return }
            let check = await sync.check(repo: repo)
            goals.setCheck(check)
            guard check.ok else { return say("not mirrored: \(check.problem ?? repo)") }
            goals.run { ops in try await ops.setMirror(goal: goal.id, on: true) } done: { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result { return say("\(error)") }
                say("\(goal.title) mirrors to \(repo): heed keeps its issues up to date from now on")
                syncGoalMirrors(only: goal.id)
            }
        }
    }

    /// `goal.tracker <org/name>`: where the goal mirrors to, checked read-only first. No repo: the command line, with
    /// the default for the goal's work filled in. `none` takes it off (and mirroring with it).
    func setGoalTracker(_ words: [String]) {
        guard let goal = mirrorSubject else { return say("no goal here") }
        guard let word = words.first else {
            let current = goal.tracker?.repo ?? config.goals.mirror.tracker(for: goalRepo(goal)) ?? ""
            return openCommandLine("goal.tracker " + current)
        }
        let now = Clock.now
        if word == "none" || word == "off" {
            return goals
                .run { ops in try await ops.setTracker(goal: goal.id, repo: nil, now: now) } done: { [weak self] _ in
                    self?.goals.reloadMirrors()
                    self?.say("\(goal.title) has no tracker")
                }
        }
        guard let repo = TrackerCheck.slug(word) else { return say("\(word) is not org/name") }
        guard let sync = goalMirror else {
            // Fixtures: the tracker is set, nothing is asked of GitHub.
            return goals
                .run { ops in try await ops.setTracker(goal: goal.id, repo: repo, now: now) } done: { [weak self] _ in
                    self?.say("\(goal.title) tracks in \(repo)")
                }
        }
        say("checking \(repo)…")
        Task { [weak self] in
            guard let self else { return }
            let check = await sync.check(repo: repo)
            goals.setCheck(check)
            guard check.ok else { return say("not set: \(check.problem ?? repo)") }
            goals
                .run { ops in
                    try await ops.setTracker(goal: goal.id, repo: repo, now: now)
                } done: { [weak self] result in
                    guard let self else { return }
                    if case let .failure(error) = result { return say("\(error)") }
                    goals.reloadMirrors()
                    let on = goals.mirror(of: goal.id).on
                    say("\(goal.title) tracks in \(repo)" + (on ? ": syncing" : ": M mirrors it there"))
                    if on { syncGoalMirrors(only: goal.id) }
                }
        }
    }

    /// `goal.mirror.sync`: the goal's mirror now, written and read back, instead of on the next GitHub sync.
    func syncGoalMirrorNow() {
        guard let goal = mirrorSubject else { return say("no goal here") }
        guard goals.mirror(of: goal.id).on else { return say("\(goal.title) does not mirror: M turns it on") }
        guard goalMirror != nil else { return say("fixture: nothing goes to GitHub") }
        say("syncing \(goal.title)'s issues…")
        syncGoalMirrors(only: goal.id, poll: true, tell: true)
    }

    /// `goal.mirror.yes|no`: answers the first ask of the goal (or the item right-clicked). Yes: the item follows
    /// what the colleague did. No: heed puts the sub-issue back the way heed has it.
    func answerMirrorAsk(yes: Bool) {
        var goal = mirrorSubject?.id
        if view == .attention, let item = attentionSelected?.item, item.reasons.contains(.goalMirror) {
            goal = GoalAttention.goal(of: item)
        }
        var ask = goal.flatMap { goals.mirror(of: $0).asks.first }
        if case let .row("goals", key)? = commandTarget, let item = goals.snapshot.item(key),
           let found = goals.mirror(of: item.goal).ask(for: key)
        {
            ask = found
        }
        guard let ask else { return say("nothing from GitHub waits for an answer") }
        let title = goals.snapshot.item(ask.item)?.title ?? ask.item
        let now = Clock.now
        goals.run { ops in try await ops.answer(ask: ask.item, yes: yes, now: now) } done: { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result { return say("\(error)") }
            goals.reloadMirrors()
            switch (ask.kind, yes) {
            case (.done, true): say("\(title) → Done, as on GitHub")
            case (.done, false): say("\(title) stays open: heed reopens #\(ask.issue)")
            case (.reopen, true): say("\(title) → Working, as on GitHub")
            case (.reopen, false): say("\(title) stays done: heed closes #\(ask.issue) again")
            }
            if let goal = goals.snapshot.item(ask.item)?.goal { syncGoalMirrors(only: goal) }
        }
    }

    /// `goal.mirror.open`: the goal's meta issue in the browser; on a card (or a right-clicked item), its sub-issue.
    func openGoalOnGitHub() {
        var item: GoalItem?
        if case let .row("goals", key)? = commandTarget { item = goals.snapshot.item(key) }
        if item == nil, view == .goals, goals.pane == .board { item = goals.selectedCard }
        guard let goal = item.flatMap({ goals.snapshot.goal($0.goal) }) ?? mirrorSubject else {
            return say("no goal here")
        }
        guard let repo = goal.tracker?.repo, let number = item?.issueNumber ?? goal.tracker?.metaIssue else {
            return say("\(goal.title) is not on GitHub yet: M mirrors it")
        }
        guard let url = URL(string: "https://github.com/\(repo)/issues/\(number)") else { return }
        if isFixture { return say("fixture: would open \(url.absoluteString)") }
        NSWorkspace.shared.open(url)
    }

    /// A new goal's tracker and mirror from the dialog: the tracker checked read-only first, and set only when it can
    /// take the goal; mirroring on when the dialog (or the org's default) said so.
    func mirrorNewGoal(_ goal: HeedGoal, tracker: String, on: Bool) {
        guard let repo = TrackerCheck.slug(tracker) else {
            if !tracker.trimmingCharacters(in: .whitespaces).isEmpty { say("\(tracker) is not org/name: no tracker") }
            return
        }
        let now = Clock.now
        guard let sync = goalMirror else {
            // Fixtures and the tutor: set, never checked or synced.
            return goals.run { ops in
                try await ops.setTracker(goal: goal.id, repo: repo, now: now)
                if on { try await ops.setMirror(goal: goal.id, on: true) }
            } done: { [weak self] _ in self?.goals.reloadMirrors() }
        }
        Task { [weak self] in
            guard let self else { return }
            let check = await sync.check(repo: repo)
            goals.setCheck(check)
            guard check.ok else { return say("\(goal.title) has no tracker: \(check.problem ?? repo)") }
            goals.run { ops in
                try await ops.setTracker(goal: goal.id, repo: repo, now: now)
                if on { try await ops.setMirror(goal: goal.id, on: true) }
            } done: { [weak self] result in
                guard let self, case .success = result else { return }
                goals.reloadMirrors()
                if on { syncGoalMirrors(only: goal.id) }
            }
        }
    }

    /// The repo a goal's work is in, for its tracker default: its first session's.
    func goalRepo(_ goal: HeedGoal) -> String? {
        let ids = Set(goals.snapshot.links(of: goal.id).map(\.target))
        return (sessions + history.map(\.session)).first { ids.contains($0.id) }?.repos.first?.slug
    }

    // MARK: Syncing

    /// On each GitHub sync: every mirrored goal's issues brought up to date (no gh call when nothing changed), and
    /// read back every background interval (a call per tracker for what changed, one more for new comments).
    func syncGoalMirrors(only: String? = nil, poll: Bool = false, tell: Bool = false) {
        guard let sync = goalMirror else { return }
        let mirrored = goals.snapshot.goals.filter { goal in
            (only == nil || goal.id == only) && goals.mirror(of: goal.id).on
        }
        guard !mirrored.isEmpty else { return }
        let table = goals.table
        let labels = config.goals.mirror.labels
        let interval = TimeInterval(config.githubPollSeconds) * 5
        let due = mirrored.filter { goal in
            poll || goals.lastMirrorPoll[goal.id].map { Date().timeIntervalSince($0) >= interval - 5 } ?? true
        }.map(\.id)
        for id in due {
            goals.lastMirrorPoll[id] = Date()
        }
        Task {
            var polls: [MirrorPoll] = []
            var errors: [String] = []
            for goal in mirrored {
                if due.contains(goal.id),
                   let found = await sync.poll(goal: goal.id, now: Date()) { polls.append(found) }
                let state = await sync.sync(goal: goal.id, labels: labels, table: table, now: Date())
                if let error = state.error { errors.append("\(goal.title): \(error)") }
            }
            goals.reloadMirrors()
            for found in polls {
                proposeFromComments(found)
            }
            if tell { say(errors.first.map { "mirror: \($0)" } ?? "issues up to date") }
        }
    }

    /// New comments on a goal's meta issue: the proposer reads them (a model call within the goal's daily budget)
    /// and what they suggest (an open question, a decision) waits in GOAL.md for you. Over budget: read on a later
    /// poll; with `[llm]` off: let go.
    func proposeFromComments(_ poll: MirrorPoll) {
        guard let sync = goalMirror, let through = poll.through,
              let goal = goals.snapshot.goal(poll.goal) else { return }
        guard config.llm.enabled else {
            Task { await sync.read(comments: through, goal: goal.id) }
            return
        }
        guard spendGoalCall(goal.id) else { return }
        let summarizer = summarizer
        let from = "GitHub \(poll.issue)"
        goals.run { ops in
            let text = try await ops.text(of: goal.id)
            let answer = try await summarizer.summarize(
                kind: .goalEdits,
                inputs: GoalMirrorBack.inputs(goal: goal.title, doc: text, comments: poll.comments, issue: poll.issue),
                caller: "goals.mirror"
            )
            let edits = GoalEditProposer.edits(answer, goal: goal.id, from: from, now: Date(), scopeOnly: true)
            var waiting = 0
            for edit in GoalMirrorBack.proposals(edits) {
                waiting += try await ops.propose(edit, now: Date()).state == .proposed ? 1 : 0
            }
            await sync.read(comments: through, goal: goal.id)
            return waiting
        }
    }

    // MARK: Attention

    /// A colleague's change on GitHub waiting for an answer: one item per goal.
    var goalMirrorAttention: [AttentionItem] {
        goals.snapshot.goals.compactMap { goal in
            let state = goals.mirror(of: goal.id)
            guard state.on, let first = state.asks.first else { return nil }
            let asks = state.asks
            let title = goals.snapshot.item(first.item)?.title ?? first.item
            let what = first.kind == .done ? "closed on GitHub: done?" : "reopened on GitHub: not done?"
            return AttentionItem(
                id: "goal:\(goal.id):mirror", kind: .goal, repo: nil, number: nil,
                title: "\(goal.title): \(title) \(what)" + (asks.count > 1 ? " (+\(asks.count - 1))" : ""),
                url: nil, reasons: [.goalMirror], updatedAt: asks.map(\.at).max() ?? goal.updatedAt
            )
        }
    }
}
