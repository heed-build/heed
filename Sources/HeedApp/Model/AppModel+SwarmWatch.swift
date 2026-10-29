import Foundation
import HeedCore

/// Watching a swarm: its workers' activity (tool calls from their hooks, file changes polled from their worktrees),
/// the stuck signal and the ladder it starts on its own, what the swarm used (kept on its workers' records while they
/// work), "since you last looked", and the end-of-build summary once it is done. The loop never runs in the fake
/// world: there everything is laid in by the fixtures.
extension AppModel {
    // MARK: The panes

    /// `goal.agents`: the swarm's agents (and, once it is done, its summary); again: the overview.
    func toggleGoalAgents() {
        if view != .goals {
            view = .goals
            if goals.pane != .agents { goals.toggleAgents() }
        } else {
            goals.toggleAgents()
        }
        endGoalEditing()
        guard goals.pane == .agents else { return }
        // The cursor on the worker that most needs a look: a stuck one, else the first at work.
        if let board = goals.board {
            let tasks = goals.agentTasks
            let index = tasks.firstIndex { stuckSignal($0.id, board: board)?.strong == true }
                ?? tasks.firstIndex { liveWorker(on: $0.id) != nil }
            if let index { goals.setAgentCursor(index) }
        }
        lookAtSwarm()
    }

    /// `goal.map`: the swarm as a map; again: the overview.
    func toggleGoalMap() {
        if view != .goals {
            view = .goals
            if goals.pane != .map { goals.toggleMap() }
        } else {
            goals.toggleMap()
        }
        endGoalEditing()
        if goals.pane == .map { lookAtSwarm() }
    }

    /// `swarm.map.move h|j|k|l`: the map's cursor between columns and between the cards of one.
    func moveMap(_ word: String?) {
        guard let layout = mapLayout() else { return say("no swarm plan to map here") }
        let (columns, rows): (Int, Int) = switch word {
        case "h": (-1, 0)
        case "l": (1, 0)
        case "j": (0, 1)
        case "k": (0, -1)
        default: (0, 0)
        }
        goals.mapCursor = SwarmMap.move(from: goals.mapCursor, columns: columns, rows: rows, in: layout)
    }

    /// The selected goal's swarm as the map lays it out: its approved plan (the current one before approval).
    func mapLayout() -> SwarmMap.Layout? {
        guard let board = goals.board, let goal = goals.snapshot.goal(board.swarm.goal) else { return nil }
        let tasks = runTasks(board).isEmpty ? goals.planTasks : runTasks(board)
        guard !tasks.isEmpty else { return nil }
        let schedule = swarmSchedule(board)
        var states: [String: SwarmMap.State] = [:]
        var details: [String: String] = [:]
        for task in tasks {
            let live = liveWorker(on: task.id)
            states[task.id] = SwarmMap.state(
                schedule?.states[task.id], worker: live.flatMap { runStates[$0.paneID] },
                stuck: stuckSignal(task.id, board: board)?.strong == true
            )
            let owner = task.owner?.label ?? board.swarm.lastWorker(on: task.id)?.owner.label ?? ""
            details[task.id] = [owner, states[task.id]?.word].compactMap(\.self).filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        return SwarmMap.layout(
            goal: goal.title, lead: board.swarm.settings.lead.label, tasks: tasks, states: states, details: details
        )
    }

    /// `swarm.task.edit` from any pane of the swarm: in the agents pane or the map, the plan opens on the task first.
    func editPlanTaskFromAnyPane() {
        if view == .goals, goals.pane == .agents || goals.pane == .map, let task = goals.selectedTask {
            goals.togglePlan()
            goals.pointTask(task.id)
            goals.setFocus(.tasks)
        }
        editPlanTask()
    }

    // MARK: Since you last looked

    /// Opening a swarm's agents or map: what changed since you last opened it, then now is when you last looked.
    func lookAtSwarm() {
        guard let board = goals.board else { return }
        let id = board.swarm.id
        let now = Clock.now
        let since = swarmLastLooked[id] ?? board.swarm.startedAt
        let tasks = runTasks(board).isEmpty ? goals.planTasks : runTasks(board)
        let digest = SwarmDigest.of(
            board, since: since, tasks: tasks, states: swarmSchedule(board)?.states ?? [:], now: now
        )
        swarmDigests[id] = digest
        if !isFixture {
            swarmLastLooked[id] = now
            UserDefaults.standard.set(
                swarmLastLooked.mapValues(\.timeIntervalSince1970), forKey: Self.lastLookedKey
            )
        }
        loadActivity(board)
        writeDigest(digest, board: board)
    }

    static let lastLookedKey = "heed.swarms.lastLooked"

    /// At launch: when you last opened each swarm.
    func loadLastLooked() {
        guard !isFixture else { return }
        let stored = UserDefaults.standard.dictionary(forKey: Self.lastLookedKey) as? [String: Double] ?? [:]
        swarmLastLooked = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The digest's text: cached by its key; a cheap model call when model calls are on, else heed's facts.
    private func writeDigest(_ digest: SwarmDigest, board: SwarmBoard) {
        let key = digest.key(board.swarm.id)
        guard swarmDigestText[key] == nil else { return }
        // The fake world's watched swarm reads as a model would have put it, the same every time.
        if isFixture || tutor != nil {
            swarmDigestText[key] = board.swarm.goal == SwarmFixtures.anchors && board.swarm.status.active
                ? SwarmFixtures.digestText : digest.plain
            return
        }
        guard config.llm.enabled, digest.facts != ["Nothing changed."] else {
            swarmDigestText[key] = digest.plain
            return
        }
        swarmDigestText[key] = digest.plain
        let summarizer = summarizer
        let title = goals.snapshot.goal(board.swarm.goal)?.title ?? board.swarm.goal
        Task { [weak self] in
            guard let text = try? await summarizer.summarize(
                kind: .swarmDigest, inputs: digest.inputs(title: title), caller: "swarm.digest"
            ) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self?.swarmDigestText[key] = trimmed }
        }
    }

    /// The text "since you last looked" shows for the selected goal's swarm, with the digest it is about.
    func digestShown(_ board: SwarmBoard) -> (digest: SwarmDigest, text: String)? {
        guard let digest = swarmDigests[board.swarm.id] else { return nil }
        return (digest, swarmDigestText[digest.key(board.swarm.id)] ?? digest.plain)
    }

    // MARK: Activity

    /// A worker's tool call (its hook): kept in memory for the agents pane and the stuck signal, and in the event log,
    /// at most one every two seconds (a failure always), the ones in between counted on the next.
    func recordWorkerCall(_ call: ToolCall, worker id: String, at: Date) {
        guard let live = liveWorkers[id] else { return }
        let kept = activityThrottle.keep(id, at: at, error: call.error)
        guard kept.keep else { return }
        appendActivity(SwarmActivityLine(at: at, kind: .tool(call), skipped: kept.skipped), task: live.task)
        // What it is about (`task:<id>`) and when say which worker: the row keeps only the call.
        let payload = kept.skipped > 0 ? ["skipped": "\(kept.skipped)"] : [:]
        let event = call.event(at: at, session: live.sessionID, subject: "task:\(live.task)", payload: payload)
        if let log = eventLog { Task { await log.append([event]) } }
    }

    private func appendActivity(_ line: SwarmActivityLine, task: String) {
        var lines = workerActivity[task] ?? []
        lines.append(line)
        if lines.count > Self.activityKept { lines.removeFirst(lines.count - Self.activityKept) }
        workerActivity[task] = lines
    }

    /// Lines of activity kept in memory per task.
    static let activityKept = 200

    /// The activity of a swarm's tasks from the event log, for those heed has none of in memory (after a launch).
    func loadActivity(_ board: SwarmBoard) {
        guard !isFixture, let log = eventLog else { return }
        let missing = Set(board.swarm.workers.map(\.task)).filter { workerActivity[$0] == nil }
        guard !missing.isEmpty else { return }
        let since = board.swarm.startedAt
        Task { [weak self] in
            guard let found = try? await log.activity(
                about: missing.map { "task:\($0)" }, since: since, limit: Self.activityKept
            ) else { return }
            for (subject, events) in found {
                let task = String(subject.dropFirst(5))
                let lines = events.compactMap(SwarmActivityLine.init(event:)).sorted { $0.at < $1.at }
                guard self?.workerActivity[task] == nil else { continue }
                self?.workerActivity[task] = lines
            }
        }
    }

    /// Each live worker's worktree, at most once a minute (every three on a host, over its shared ssh connection, and
    /// only while it answers): what changed since the last look, a row when it did.
    private func pollWorkerFiles(now: Date) async {
        for (id, live) in liveWorkers where !live.worktree.isEmpty {
            let last = workerFiles[id]
            guard FileActivityPolling.due(
                last: last?.at, now: now, interval: FileActivityPolling.interval(for: live.location)
            ) else { continue }
            if let host = live.location.hostName, !hostStatus(host).isConnected { continue }
            workerFiles[id] = (now, last?.files)
            guard let current = try? await Git.fileActivity(at: live.worktree, on: live.location) else { continue }
            workerFiles[id] = (now, current)
            guard let change = FileActivity.change(from: last?.files, to: current) else { continue }
            appendActivity(SwarmActivityLine(at: now, kind: .files(change)), task: live.task)
            var event = change.event(
                at: now, session: live.sessionID, worktree: live.worktree, subject: "task:\(live.task)"
            )
            event.text = change.line(after: last?.files)
            if let log = eventLog { await log.append([event]) }
        }
    }

    // MARK: Stuck

    /// A task's stuck signal now: its live worker's activity, errors, screen (Hunch's reading of it when Hunch reads
    /// screens, else heed's guess) and the questions it waits on. Nil without a live worker.
    func stuckSignal(_ task: String, board: SwarmBoard, now: Date = Clock.now) -> SwarmStuck.Signal? {
        guard let live = liveWorker(on: task) else { return nil }
        let plan = runTasks(board).first { $0.id == task }
        let lines = (workerActivity[task] ?? []).filter { $0.at >= live.startedAt }
        let facts = SwarmActivityFacts.of(lines)
        let reported = runStates[live.paneID]
        let guessed = TerminalSurfaces.shared.visibleText(paneID: live.paneID).flatMap { text in
            settings.agent(live.agent).flatMap { ScreenGuess.guess(text, patterns: ScreenGuess.patterns(for: $0)) }
        }
        var others: Date?
        var you: Date?
        let mine = SwarmAddress.task(task).raw
        for question in board.openQuestions where question.row.from == mine {
            let position = SwarmLadder.position(question.row, rows: board.steering)
            if position.step == .you { you = min(you ?? position.since, position.since) } else {
                others = min(others ?? question.row.at, question.row.at)
            }
        }
        // A worker asking on its own (its hooks say so) waits too, on whoever its question went to.
        if reported == .asking, others == nil, you == nil { others = lines.last?.at ?? live.startedAt }
        return SwarmStuck.signal(
            SwarmStuck.Observation(
                now: now, startedAt: live.startedAt, estimate: plan?.estimate, lastActivity: facts.last,
                recentErrors: Array(facts.errors.suffix(12)),
                screen: SwarmStuck.screen(
                    hunch: hunchReading(pane: live.paneID), guessed: guessed, reported: reported
                ),
                waitingOnOthers: others,
                waitingOnYou: you
            ),
            settings: board.swarm.settings.stuck
        )
    }

    // MARK: The loop

    /// Every 30 seconds: each running swarm's worktrees, stuck signals and ladder, what its workers used, reminders;
    /// done swarms' summaries; activity past its keep pruned now and then.
    func startSwarmWatch() {
        guard !isFixture, tutor == nil else { return }
        loadLastLooked()
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.tickWatch()
            }
        }
    }

    func tickWatch() async {
        guard !isFixture, tutor == nil, let ops = goals.ops, !watchTicking else { return }
        watchTicking = true
        defer { watchTicking = false }
        let now = Clock.now
        await pollWorkerFiles(now: now)
        var signals: [String: SwarmStuck.Signal] = [:]
        for run in goals.snapshot.swarms {
            if run.status == .done, run.endedAt.map({ now.timeIntervalSince($0) < 7 * 86400 }) ?? false {
                if let board = try? await ops.board(of: run.id) { await keepSummary(board) }
                continue
            }
            guard run.status.active, run.approved != nil, let board = try? await ops.board(of: run.id) else { continue }
            await persistUse(board.swarm)
            await signals.merge(climbStuck(board, now: now)) { $1 }
            await remind(board, now: now)
        }
        if signals != stuckSignals { stuckSignals = signals }
        if activityPrunedAt.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true, let log = eventLog {
            activityPrunedAt = now
            Task.detached(priority: .utility) { await log.pruneActivity(now: now) }
        }
    }

    /// Each live worker's signal, and the ladder's next step for it: a nudge, a question on its behalf, or the
    /// episode's end. Tasks whose worker ended have their episode ended too.
    private func climbStuck(_ board: SwarmBoard, now: Date) async -> [String: SwarmStuck.Signal] {
        let swarm = board.swarm
        let tasks = runTasks(board)
        let numbers = SwarmPlan.numbers(tasks)
        var signals: [String: SwarmStuck.Signal] = [:]
        var wrote = false
        for task in tasks {
            let signal = stuckSignal(task.id, board: board, now: now)
            if let signal { signals[task.id] = signal }
            let live = liveWorker(on: task.id) != nil
            let title = "\(numbers[task.id] ?? "") \(task.title)"
            let action = live ? SwarmStuck.next(
                task: task.id, signal: signal, rows: board.steering, now: now, settings: swarm.settings.stuck
            ) : (SwarmStuck.episode(of: task.id, board.steering) == nil ? .none : .clear)
            switch action {
            case .none: continue
            case let .nudge(signal):
                _ = await goalOp { try await $0.nudgeStuck(
                    swarm: swarm.id, task: task.id, title: title, signal: signal, now: now
                ) }
                say("swarm \(swarm.number): \(title) looks stuck (\(signal.main.text)): told to try another way")
            case let .ask(signal):
                _ = await goalOp { try await $0.askStuck(
                    swarm: swarm.id, task: task.id, number: numbers[task.id] ?? "", title: task.title,
                    signal: signal, now: now
                ) }
                say("swarm \(swarm.number): \(title) is still stuck: heed asks for it, up the ladder")
            case .clear:
                _ = await goalOp { try await $0.clearStuck(swarm: swarm.id, task: task.id, title: title, now: now) }
            }
            wrote = true
        }
        if wrote { await refreshSteering(swarm.id) }
        return signals
    }

    /// Questions that waited on you past the swarm's setting: a reminder (a steering row, and Needs you notifies
    /// again).
    private func remind(_ board: SwarmBoard, now: Date) async {
        let due = SwarmStuck.reminders(board.steering, now: now, settings: board.swarm.settings.stuck)
        guard !due.isEmpty else { return }
        let minutes = board.swarm.settings.stuck.waitingOnYou
        for question in due {
            _ = await goalOp {
                try await $0.remind(swarm: board.swarm.id, question: question.id, minutes: minutes, now: now)
            }
        }
        await refreshSteering(board.swarm.id)
    }

    // MARK: Use

    /// Each live worker's use now, from its hooks: dollars (reported or estimated) and tokens.
    func liveUses() -> [String: SwarmUsageRollup.Use] {
        liveWorkers.compactMapValues { live in
            guard let usage = live.usage else { return nil }
            return SwarmUsageRollup.Use(
                dollars: config.usage.cost(of: usage), tokens: usage.tokens.allInput + usage.tokens.output
            )
        }
    }

    /// What a swarm used: its ended workers as recorded, its live ones as their hooks say now.
    func swarmRollup(_ swarm: GoalSwarm) -> SwarmUsageRollup {
        SwarmUsageRollup.of(
            swarm,
            live: liveUses().filter { id, _ in liveWorkers[id]?.swarm == swarm.id },
            now: Clock.now
        )
    }

    /// Live workers' use onto their records, when it moved enough: a restart keeps it, and the dollar limit sees it.
    private func persistUse(_ swarm: GoalSwarm) async {
        for (id, use) in liveUses() where liveWorkers[id]?.swarm == swarm.id {
            let stored = persistedUse[id] ?? swarm.workers.first { $0.id == id }?.use ?? SwarmUsageRollup.Use()
            guard SwarmUsageRollup.worthPersisting(use, over: stored) else { continue }
            persistedUse[id] = use
            _ = await goalOp { try await $0.noteWorkerUse(swarm: swarm.id, worker: id, use: use) }
        }
    }

    // MARK: The summary

    /// A done swarm's summary, assembled from its record and the lead's words, kept on the run when it changed; the
    /// first time, the lead is asked to write its part. A new summary goes into the ledger (History) and its decisions
    /// into GOAL.md as records.
    func keepSummary(_ board: SwarmBoard) async {
        let swarm = board.swarm
        guard swarm.status == .done, !summarizing.contains(swarm.id),
              let goal = goals.snapshot.goal(swarm.goal)
        else { return }
        summarizing.insert(swarm.id)
        defer { summarizing.remove(swarm.id) }
        let tasks = runTasks(board)
        let facts = swarmFacts(board, tasks: tasks)
        let summary = SwarmSummary.assemble(
            board, goal: goal.title, tasks: tasks, facts: facts, use: swarmRollup(swarm), now: Clock.now
        )
        guard summary != swarm.summary else { return }
        let first = swarm.summary == nil
        _ = await goalOp { try await $0.saveSummary(swarm: swarm.id, summary) }
        guard !isFixture else { return }
        let pulls = tasks.compactMap { facts[$0.id]?.ref }
        let usage = AgentUsage(
            tokens: TokenCounts(input: summary.tokens),
            costUSD: summary.dollars > 0 ? summary.dollars : nil
        )
        ledger.upsert(summary.ledger(
            repos: swarm.settings.repos, pulls: pulls, lead: swarm.settings.lead.label, usage: usage
        ))
        let written = SwarmSummary.Written.of(board.steering)
        let now = Clock.now
        let from = "swarm \(swarm.number) summary"
        let decisions = written?.decisions ?? []
        if !decisions.isEmpty {
            _ = await goalOp { ops in
                for decision in decisions {
                    _ = try await ops.propose(GoalEdit(
                        goal: swarm.goal, section: .decisions, op: .add, text: decision, evidence: from,
                        from: "the lead of swarm \(swarm.number)", reason: "the end-of-build summary", at: now
                    ), now: now)
                }
            }
        }
        if first {
            nudgeLead(
                board,
                "The swarm is done. Write its end-of-build summary: heed swarm summary --outcome TEXT "
                    + "--decision TEXT --follow-up TEXT."
            )
            say("swarm \(swarm.number) on \(goal.title) is done: its summary is on the goal's swarm "
                + "(\(keyText(for: "goal.agents", in: "goals"))) and in History's ledger")
        }
    }

    /// `swarm.summary`: the selected goal's last swarm's summary assembled again, and the lead asked for its part.
    func rewriteSwarmSummary() {
        guard let board = goals.board else { return say("no swarm here") }
        guard board.swarm.status == .done else { return say("the swarm is not done: its summary comes when it is") }
        Task {
            await keepSummary(board)
            nudgeLead(
                board,
                "Write (again) the swarm's end-of-build summary: heed swarm summary --outcome TEXT "
                    + "--decision TEXT --follow-up TEXT."
            )
            say("summary written again from the swarm's record; the lead is asked for its part")
        }
    }

    /// `swarm.followup`: the swarm form again on the same goal, with the last run's team, limits and stuck settings;
    /// its lead starts from the last run's follow-ups.
    func followUpSwarm() {
        guard let goal = goals.selected else { return say("no goal here") }
        if let active = goals.snapshot.activeSwarm(of: goal.id) {
            return say("\(goal.title) has swarm \(active.number) going: a follow-up starts once it ends")
        }
        guard let last = goals.snapshot.swarms(of: goal.id).first else {
            return say("\(goal.title) has had no swarm: :swarm.start swarms it")
        }
        startSwarmOnGoal()
        guard var form = goals.swarmForm else { return }
        let settings = last.settings
        form.repos = settings.repos.filter { slug in repos.contains { $0.repo.slug == slug } }
        form.lead = settings.lead
        form.workers = settings.workers
        form.limits = settings.limits
        form.autonomy = settings.autonomy
        form.stuck = settings.stuck
        form.merge = settings.merge
        if let followUps = last.summary?.followUps, !followUps.isEmpty {
            form.statement = "Follow-ups from swarm \(last.number): " + followUps.joined(separator: "; ")
        }
        goals.swarmForm = form
        say("a follow-up to swarm \(last.number): its team and limits; ⌘↩ starts it")
    }

    // MARK: Settings and rules

    /// `swarm.stuck <estimate|errors|quiet|peer|you> <value>`: when the goal's swarm counts a worker as stuck.
    func setStuckSettings(_ words: [String]) {
        guard let swarm = goals.activeSwarm else { return say("no swarm going here") }
        guard words.count == 2 else {
            say("stuck when: \(swarm.settings.stuck.line)")
            return openCommandLine("swarm.stuck ")
        }
        guard let next = swarm.settings.stuck.setting(words[0], to: words[1]) else {
            return say("swarm.stuck takes estimate (× its estimate, 0 off), errors, quiet, peer or you, and a number")
        }
        let now = Clock.now
        goals.run { try await $0.setStuck(swarm: swarm.id, next, now: now) } done: { [weak self] result in
            switch result {
            case let .success(run): self?.say("stuck when: \(run.settings.stuck.line)")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `swarm.merge <off|auto|heed|repo>`: get it merged for the goal's swarm's PRs. Its PRs still merge in merge
    /// order, a held child after its parent, and a PR's own choice (`zm`) still wins.
    func setSwarmMerge(_ word: String?) {
        guard let swarm = goals.activeSwarm else { return say("no swarm going here") }
        let repo = swarmRepoMerge(swarm)
        guard let word else {
            say("swarm \(swarm.number): \(swarm.settings.merge.line(repo: repo))")
            return openCommandLine("swarm.merge ")
        }
        guard let merge = SwarmSettings.Merge.named(word) else {
            return say("swarm.merge takes off, auto, heed or repo")
        }
        let now = Clock.now
        goals.run { try await $0.setMerge(swarm: swarm.id, merge, now: now) } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(run):
                refreshSwarmPulls()
                say("swarm \(run.number): \(run.settings.merge.line(repo: repo)), in merge order")
            case let .failure(error): say("\(error)")
            }
        }
    }

    /// What get it merged is for the swarm's first repo by its `[pilot]` settings: what `repo` follows.
    func swarmRepoMerge(_ swarm: GoalSwarm) -> MergeMode {
        let parts = swarm.settings.repos.first?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2 else { return config.pilot.defaults.merge }
        return config.pilot.resolve(Repo(org: parts[0], name: parts[1])).merge
    }

    /// The goal's repeat rules, newest first, as the plan pane lists them.
    func repeatRules(_ board: SwarmBoard) -> [SwarmSteer] {
        let rows = goals.snapshot.swarms(of: board.swarm.goal).flatMap { run in
            goals.boards[run.id]?.steering ?? (run.id == board.swarm.id ? board.steering : [])
        }
        return SwarmRepeat.rules(rows.sorted { ($0.id ?? 0) < ($1.id ?? 0) })
    }

    /// `swarm.rule.delete [n]`: a repeat rule (its number in the list, or its row id from a menu) deleted.
    func deleteRepeatRule(_ word: String?) {
        guard let board = goals.board else { return say("no swarm here") }
        let rules = repeatRules(board)
        guard !rules.isEmpty else { return say("no repeat rules on this goal") }
        guard let word, let number = Int64(word) else { return openCommandLine("swarm.rule.delete ") }
        let rule = rules.first { $0.id == number } ?? (rules.indices.contains(Int(number) - 1) ? rules[Int(number) - 1]
            : nil)
        guard let rule, let id = rule.id else { return say("no rule \(word): 1…\(rules.count)") }
        let now = Clock.now
        let goal = board.swarm.goal
        goals.run { try await $0.deleteRule(id, goal: goal, now: now) } done: { [weak self] result in
            switch result {
            case .success:
                self?.say("deleted the rule for \"\(rule.text)\": the controller no longer answers with it")
                Task { await self?.goals.reloadBoard() }
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    func repeatRuleMenu(_ id: Int64, question: String) -> [MenuEntry] {
        ContextMenus.repeatRule(id: id, question: question)
    }

    /// The swarm's questions at your step, the agents pane's worker's first, then oldest first: Needs you's queue in
    /// the agents and map panes, whose first one 1…9, i and c act on.
    func waitingOnYou(_ board: SwarmBoard) -> [SwarmSteering.Question] {
        let mine = goals.pane == .agents ? goals.selectedAgentTask.map { SwarmAddress.task($0.id).raw } : nil
        return board.openQuestions.filter { question in
            SwarmLadder.position(question.row, rows: board.steering).step == .you
        }.sorted { ($0.row.from == mine ? 0 : 1, $0.row.at) < ($1.row.from == mine ? 0 : 1, $1.row.at) }
    }

    // MARK: Clicks

    func clickAgent(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.agents)
        goals.setAgentCursor(index)
    }

    func clickMapCard(_ id: String) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.mapCursor = id
    }

    func agentMenu(_ task: SwarmTask) -> [MenuEntry] {
        guard let board = goals.board else { return [] }
        let state = swarmSchedule(board)?.states[task.id]?.state
        return ContextMenus.swarmTask(
            id: task.id, title: task.title, first: true, last: true, active: board.swarm.status.active, running: true,
            paused: state == .paused, working: liveWorker(on: task.id) != nil, owner: task.owner?.agent,
            agents: settings.agents.map(\.name)
        )
    }

    // MARK: The fake world

    /// The fake world's watched swarm: the steering world with 2.2 stuck and the ladder heed climbed for it, every
    /// worker's activity, and what changed since you last looked (fixed text).
    func loadWatchFixture(_ variant: SwarmFixtures.Running = .watch) {
        guard isFixture else { return }
        loadRunningSwarmFixture(variant)
        steeringBoards = goals.boards.filter { $0.key == "\(SwarmFixtures.anchors)/swarm-1" }
        workerActivity = SwarmFixtures.activity(now: Clock.now)
        swarmLastLooked["\(SwarmFixtures.anchors)/swarm-1"] = SwarmFixtures.lastLooked(now: Clock.now)
        noteAttention()
        updateScope()
    }

    /// The fake world's done swarm with its summary.
    func loadSummaryFixture() {
        guard isFixture else { return }
        loadRunningSwarmFixture(.summary)
    }

    /// The summary of a done swarm as the panes show it: the one kept on the run, else assembled now.
    func summaryShown(_ board: SwarmBoard) -> SwarmSummary? {
        guard board.swarm.status == .done else { return nil }
        if let kept = board.swarm.summary ?? goals.snapshot.swarms.first(where: { $0.id == board.swarm.id })?.summary {
            return kept
        }
        guard let goal = goals.snapshot.goal(board.swarm.goal) else { return nil }
        let tasks = runTasks(board)
        return SwarmSummary.assemble(
            board, goal: goal.title, tasks: tasks, facts: swarmFacts(board, tasks: tasks),
            use: swarmRollup(board.swarm), now: board.swarm.endedAt ?? Clock.now
        )
    }
}
