import Foundation
import HeedCore

/// Steering a swarm: its questions climb their ladder (`SwarmLadder`) on a loop, the controller answers through the
/// deciders what is within its authority (`SwarmController`), and what waits for an agent (messages, questions for a
/// peer or the lead, answers, overrules) is typed into its pane once it is idle and you are not typing there
/// (`SwarmDelivery`, `Delivery`). You answer in Needs you or the plan pane: a digit, a typed answer, the controller,
/// or the same answer for similar questions. Every step is a steering row, through `GoalOps`.
extension AppModel {
    // MARK: The loop

    /// Every ten seconds: each active swarm's questions and hand-overs. Never in the fake world: nothing runs there.
    func startSteering() {
        guard !isFixture, tutor == nil else { return }
        steeringTask?.cancel()
        steeringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.tickSteering()
            }
        }
    }

    /// Questions whose `heed goal ask` read them in the last 20 seconds: they read their own answer.
    var waitingAsks: Set<Int64> {
        let now = Clock.now
        return Set(askPolls.filter { now.timeIntervalSince($0.value) < 20 }.keys)
    }

    /// One pass: each active swarm's ladder moved on, its controller asked, its hand-overs made, its board kept for
    /// Needs you.
    func tickSteering() async {
        guard !isFixture, tutor == nil, let ops = goals.ops, !steeringTicking else { return }
        steeringTicking = true
        defer { steeringTicking = false }
        var fresh: [String: SwarmBoard] = [:]
        for run in goals.snapshot.swarms where run.status.active {
            guard var board = try? await ops.board(of: run.id) else { continue }
            if await climb(board) { board = await (try? ops.board(of: run.id)) ?? board }
            if await handOver(board) { board = await (try? ops.board(of: run.id)) ?? board }
            fresh[run.id] = board
        }
        keepSteering(fresh)
    }

    /// The boards Needs you reads, when they changed: Attention and its notifications follow.
    func keepSteering(_ fresh: [String: SwarmBoard]) {
        guard fresh != steeringBoards else { return }
        steeringBoards = fresh
        for (id, board) in fresh {
            goals.boards[id] = board
        }
        if let selected = goals.board, let board = fresh[selected.swarm.id], board != selected {
            Task { await goals.reloadBoard() }
        }
        noteAttention()
        updateScope()
    }

    /// The ladder: escalations whose time came, and the controller asked where it is the controller's turn. True when
    /// it wrote something.
    private func climb(_ board: SwarmBoard) async -> Bool {
        let now = Clock.now
        var wrote = false
        for question in board.openQuestions {
            // A peer has as long as the swarm says a question may wait on one.
            let timeouts = SwarmLadder.Timeouts(peer: Double(board.swarm.settings.stuck.waitingOnPeer) * 60)
            switch SwarmLadder.due(question, rows: board.steering, now: now, timeouts: timeouts) {
            case .none: continue
            case let .escalate(step, why):
                let id = question.id
                let moved = await goalOp { try await $0.escalate(
                    swarm: board.swarm.id,
                    question: id,
                    to: step,
                    why: why,
                    now: now
                ) }
                wrote = wrote || moved != nil
                if step == .controller, !controllerBusy.contains(id) {
                    await runController(question, board: board, mode: .onItsOwn)
                }
            case .askController:
                guard !controllerBusy.contains(question.id) else { continue }
                await runController(question, board: board, mode: .onItsOwn)
                wrote = true
            }
        }
        return wrote
    }

    /// The controller on one question: a repeat of your answer, its pick, or (yours) a suggestion; declined on its own,
    /// the question goes to you. Its decider writes the `decide` row; the answer is a steering row by the controller.
    func runController(
        _ question: SwarmSteering.Question, board: SwarmBoard, mode: SwarmController.Mode
    ) async {
        let id = question.id
        guard !controllerBusy.contains(id) else { return }
        controllerBusy.insert(id)
        defer { controllerBusy.remove(id) }
        let swarm = board.swarm.id
        let row = question.row
        let category = row.category.flatMap(SwarmAuthority.Category.init(rawValue:))
            ?? SwarmAuthority.category(row.text, options: row.options)
        let history = await goalOp { try await SwarmRepeat.answered($0.steering(goal: board.swarm.goal)) } ?? []
        let decider = decider(
            caller: SwarmController.caller,
            priority: mode == .askedByYou ? .interactive : .background
        )
        let outcome = await SwarmController.decide(
            row,
            category: category,
            history: history,
            decider: decider,
            mode: mode,
            draft: answerDraft(goal: board.swarm.goal, mode: mode)
        )
        let now = Clock.now
        switch outcome {
        case let .answer(option, reason):
            _ = await goalOp {
                try await $0.answer(
                    swarm: swarm, question: id, text: option, actor: .controller, from: .controller,
                    reason: "by the controller: \(category.title), \(reason)", now: now
                )
            }
            if mode == .askedByYou { say("the controller answered: \(option) (\(reason))") }
        case let .repeatOf(earlier, answer, similar):
            _ = await goalOp {
                try await $0.answer(
                    swarm: swarm, question: id, text: answer, actor: .controller, from: .controller,
                    reason: "by the controller: " + GoalOps.repeatReason(earlier, similar: similar),
                    ref: "question:\(earlier.id)", now: now
                )
            }
            if mode == .askedByYou { say("the controller answered \(answer): you answered that before") }
        case let .suggest(option, reason):
            _ = await goalOp {
                try await $0.suggest(swarm: swarm, question: id, option: option, reason: reason, now: now)
            }
            say("the controller suggests \(option) (\(reason)): \(category.title) is yours, "
                + "\(keyText(for: "goal.ask.yes", in: "swarmask")) takes it")
        case let .draft(text):
            // Free text is only ever a suggestion: on its own the question still goes to you, with it.
            _ = await goalOp {
                try await $0.suggest(
                    swarm: swarm, question: id, option: text,
                    reason: "drafted, the question has no options: yours to take", now: now
                )
            }
            if mode == .onItsOwn {
                _ = await goalOp { try await $0.escalate(
                    swarm: swarm, question: id, to: .you,
                    why: "no options to pick from: the controller drafted an answer for you to take or not", now: now
                ) }
            }
            say("the controller suggests: \(text) (\(keyText(for: "goal.ask.yes", in: "swarmask")) takes it)")
        case let .decline(why):
            if mode == .onItsOwn {
                _ = await goalOp { try await $0.escalate(swarm: swarm, question: id, to: .you, why: why, now: now) }
            } else {
                say("the controller does not answer: \(why)")
            }
        }
        await refreshSteering(board.swarm.id)
    }

    /// Writes a free-text answer to a question with no options (`SummaryKind.swarmAnswer`, a cheap model call), from
    /// the question and the goal's GOAL.md; nil with model calls off.
    private func answerDraft(goal: String, mode: SwarmController.Mode) -> SwarmController.Draft? {
        guard config.llm.enabled else { return nil }
        let summarizer = summarizer
        let doc = goals.files.doc(goal)
        let priority: LLMRequest.Priority = mode == .askedByYou ? .interactive : .background
        return { row in
            let text = try? String(contentsOf: doc, encoding: .utf8)
            return try? await summarizer.summarize(
                kind: .swarmAnswer, inputs: SwarmController.draftInputs(row, goal: text),
                caller: SwarmController.caller, priority: priority
            )
        }
    }

    /// Hands over what waits for agents: one thing per pane, into an idle agent you are not typing to. True when it
    /// typed something.
    private func handOver(_ board: SwarmBoard) async -> Bool {
        let now = Clock.now
        let numbers = SwarmPlan.numbers(board.tasks)
        var typed: Set<String> = []
        var wrote = false
        for item in SwarmDelivery.pending(board.steering, waiting: waitingAsks, numbers: numbers, now: now) {
            guard !typed.contains(item.to.raw), let target = paneOf(item.to, swarm: board.swarm) else { continue }
            if let last = handedAt[target.pane], now.timeIntervalSince(last) < 15 { continue }
            guard Delivery.verdict(state: target.state, lastTyped: target.typed, now: now) == .deliver,
                  TerminalSurfaces.shared.hasTerminal(paneID: target.pane)
            else { continue }
            TerminalSurfaces.shared.typeLine(item.line, paneID: target.pane)
            typed.insert(item.to.raw)
            handedAt[target.pane] = now
            if target.worker { runStates[target.pane] = .working }
            let row = item.row.id ?? 0
            _ = await goalOp {
                try await $0.delivered(
                    swarm: board.swarm.id,
                    row: row,
                    to: item.to,
                    how: "typed into its pane",
                    now: now
                )
            }
            wrote = true
        }
        return wrote
    }

    /// The pane an address types into: the lead's agent pane, or a task's live worker's.
    private func paneOf(_ address: SwarmAddress, swarm: GoalSwarm)
        -> (pane: String, state: AgentState, typed: Date?, worker: Bool)?
    {
        switch address {
        case .lead:
            guard let id = swarm.lead, let session = sessions.first(where: { $0.id == id }),
                  let layout = layouts[id], let (_, pane) = agentPane(in: layout)
            else { return nil }
            return (pane, session.state.state, lastTyped[id], false)
        case let .task(task):
            guard let live = liveWorkers.values.first(where: { $0.task == task && $0.swarm == swarm.id }) else {
                return nil
            }
            return (live.paneID, runStates[live.paneID] ?? .working, lastTyped[live.sessionID], true)
        default: return nil
        }
    }

    /// Whether something waits for a worker: its turn is not over until it was handed over.
    func workerHasMail(_ live: LiveWorker) -> Bool {
        guard let board = steeringBoards[live.swarm] else { return false }
        return !SwarmDelivery.pending(for: .task(live.task), board.steering, waiting: waitingAsks, now: Clock.now)
            .isEmpty
    }

    /// One swarm's board read again for Needs you and the plan pane.
    func refreshSteering(_ swarm: String) async {
        guard let board = await goalOp({ try await $0.board(of: swarm) }) else { return }
        var fresh = steeringBoards
        fresh[swarm] = board.swarm.status.active ? board : nil
        keepSteering(fresh)
    }

    /// After `heed goal ask`, `heed swarm …`: the steering pass at once, so an answer, a hand-over or a Needs you
    /// item does not wait for the loop. A wait's own reads only note that it is waiting.
    func steeringCommandDone(_ command: GoalCommand, reply: GoalReply) {
        if command.verb == .ask, let question = reply.question { askPolls[question] = Clock.now }
        guard [.ask, .swarmSend, .swarmNote, .swarmAnswer].contains(command.verb), command.question == nil
            || command.verb == .swarmAnswer
        else { return }
        Task { await tickSteering() }
    }

    // MARK: The question under the cursor

    /// The swarm question Needs you has under the cursor.
    var attentionQuestion: (board: SwarmBoard, question: SwarmSteering.Question)? {
        guard view == .attention, let item = attentionSelected?.item else { return nil }
        return swarmQuestion(for: item)
    }

    /// The swarm question an Attention item is, with its board.
    func swarmQuestion(for item: AttentionItem) -> (board: SwarmBoard, question: SwarmSteering.Question)? {
        guard let (goal, id) = GoalAttention.question(of: item) else { return nil }
        let boards = steeringBoards.values.filter { $0.swarm.goal == goal }
            + [goals.board].compactMap(\.self).filter { $0.swarm.goal == goal }
        for board in boards {
            if let question = board.questions.first(where: { $0.id == id }) { return (board, question) }
        }
        return nil
    }

    /// The question a steering command acts on: Needs you's, else in the plan pane the one the steering row under
    /// the cursor is about, else the first open one (`open`: only an open one).
    func steeringQuestion(open: Bool = true) -> (board: SwarmBoard, question: SwarmSteering.Question)? {
        if let found = attentionQuestion { return found }
        guard view == .goals, let board = goals.board else { return nil }
        if goals.pane == .agents || goals.pane == .map {
            return waitingOnYou(board).first.map { (board, $0) }
        }
        if goals.focus == .steering, let row = goals.selectedSteer {
            let id = row.kind == .question ? row.id : row.about
            if let id, let question = board.questions.first(where: { $0.id == id }) { return (board, question) }
        }
        let first = open ? board.openQuestions.first : board.openQuestions.first ?? board.questions.last
        return first.map { (board, $0) }
    }

    // MARK: Answering

    /// Your answer to a question: in Needs you or the plan pane. Over an answer someone else gave, an overrule (retyped
    /// to the agent, and a label Hunch learns from). Armed with `swarm.similar`, also a repeat rule.
    func answerSwarmQuestion(_ text: String, board: SwarmBoard, question: SwarmSteering.Question) {
        let swarm = board.swarm.id
        let id = question.id
        let key = "\(swarm)#\(id)"
        let rule = similarArmed == key
        if rule { similarArmed = nil }
        let now = Clock.now
        let overrules = question.answer.map { $0.actor != .you } ?? false
        goals.run { ops in
            let answer = try await ops.answer(swarm: swarm, question: id, text: text, now: now)
            if rule { try await ops.rule(swarm: swarm, question: id, answer: text, now: now) }
            return answer
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(row):
                let asker = question.row.from.flatMap(SwarmAddress.init(raw:))?
                    .label(SwarmPlan.numbers(board.tasks)) ?? "the lead"
                if row.kind == .overrule {
                    say("overruled: \(asker) is told \(text); Hunch learns from it")
                } else {
                    say("answered \(asker): \(text)" + (rule ? "; similar questions get it too" : "")
                        + (overrules ? "" : ""))
                }
                // A question of the lead's from before the ladder: told in its pane, as before.
                if question.row.from == nil, question.row.actor == .lead {
                    nudgeLead(board, "The owner answered your question: \(text)")
                }
                Task { await self.tickSteering() }
                Task { await self.refreshSteering(swarm) }
            case let .failure(error): say("\(error)")
            }
        }
    }

    /// `swarm.answer [text]`: the question under the cursor (Needs you, the plan's log), else the first open one.
    /// No words: in the plan, the answer editor; in Needs you, the command line.
    func answerSwarm(_ words: [String], question asked: Int64? = nil) {
        var found = steeringQuestion(open: false)
        if let asked {
            found = nil
            for board in [goals.board].compactMap(\.self) + steeringBoards.values {
                if let question = board.questions.first(where: { $0.id == asked && board.swarm.goal == $0.row.goal }) {
                    found = (board, question)
                    break
                }
            }
        }
        guard let (board, question) = found else {
            return say(view == .attention ? "no swarm question here" : "nobody has asked anything")
        }
        guard board.swarm.status.active else { return say("that swarm has ended: its answers stay as they are") }
        guard !words.isEmpty else {
            if view == .goals {
                var draft = PlanDraft(kind: .answer(question.id))
                draft.text = question.answer?.text ?? ""
                return beginPlanAnswer(draft)
            }
            return openCommandLine("swarm.answer ")
        }
        answerSwarmQuestion(words.joined(separator: " "), board: board, question: question)
    }

    /// `swarm.answer.option <n>`: the question under the cursor answered with its option n.
    func answerSwarmOption(_ word: String?) {
        guard let (board, question) = steeringQuestion(open: false) else {
            return say(view == .attention ? "no swarm question here" : "nobody asks anything open")
        }
        let options = question.row.options
        guard let number = Int(word ?? ""), options.indices.contains(number - 1) else {
            return say(options.isEmpty ? "the question has no options: \(keyText(for: "swarm.answer")) types an answer"
                : "the question has \(options.count) option\(options.count == 1 ? "" : "s")")
        }
        answerSwarmQuestion(options[number - 1], board: board, question: question)
    }

    /// `swarm.overrule [text]`: answer again a question someone else answered.
    func overruleSwarm(_ words: [String]) {
        guard let (_, question) = steeringQuestion(open: false) else { return say("no swarm question here") }
        guard let answer = question.answer, answer.actor != .you else {
            return say(question.answer == nil ? "nobody answered it yet: answer it"
                : "you answered it: \(keyText(for: "swarm.answer")) changes your answer")
        }
        answerSwarm(words)
    }

    /// `swarm.controller`: the question under the cursor to the controller. Yours to answer, it only suggests.
    func askController() {
        guard let (board, question) = steeringQuestion() else { return say("no open swarm question here") }
        guard question.answer == nil else { return say("it is answered: \(question.answer?.text ?? "")") }
        guard !isFixture, tutor == nil else {
            return say("in the fake world the controller does not decide")
        }
        say("asking the controller…")
        Task { await runController(question, board: board, mode: .askedByYou) }
    }

    /// `swarm.similar`: your next answer to the question under the cursor also answers questions like it.
    func armSimilar() {
        guard let (board, question) = steeringQuestion() else { return say("no open swarm question here") }
        let category = question.row.category.flatMap(SwarmAuthority.Category.init(rawValue:))
            ?? SwarmAuthority.category(question.row.text, options: question.row.options)
        guard SwarmAuthority.mayRepeat(category) else {
            return say("\(category.title) always comes to you: no rule answers it for you")
        }
        let key = "\(board.swarm.id)#\(question.id)"
        if similarArmed == key {
            similarArmed = nil
            return say("only this question then")
        }
        similarArmed = key
        say(
            "your answer to this one answers similar questions too: pick it (1…\(min(max(question.row.options.count, 1), 9))) "
                + "or type it"
        )
    }

    /// `y` on a swarm question in Needs you: the controller's suggestion taken.
    func takeSuggestion() {
        guard let (board, question) = attentionQuestion else { return }
        guard let suggestion = SwarmSteering.suggestion(question, rows: board.steering) else {
            return say("no suggestion yet: \(keyText(for: "swarm.controller", in: "swarmask")) asks the controller")
        }
        answerSwarmQuestion(suggestion.text, board: board, question: question)
    }

    // MARK: PRs heed could not move

    /// The swarm whose PRs Needs you says heed could not move.
    var retargetAsk: SwarmBoard? {
        guard view == .attention, let item = attentionSelected?.item, GoalAttention.isRetarget(item),
              let goal = GoalAttention.goal(of: item)
        else { return nil }
        return steeringBoards.values.first { $0.swarm.goal == goal }
    }

    /// `y`: try again now; `n`: leave them where they are (`swarm.land` still moves one).
    func answerRetarget(_ board: SwarmBoard, yes: Bool) {
        let failures = SwarmSteering.retargetFailures(board.steering)
        if yes {
            landFailures = [:]
            tickSwarms()
            return say("moving \(failures.count == 1 ? "it" : "them") again…")
        }
        let now = Clock.now
        let swarm = board.swarm.id
        goals.run { ops in
            for failure in failures {
                try await ops.leaveRetarget(swarm: swarm, failure: failure.id ?? 0, now: now)
            }
        } done: { [weak self] _ in
            self?.say("left where \(failures.count == 1 ? "it is" : "they are"): "
                + "\(self?.keyText(for: "swarm.land", in: "goalplan") ?? "") on the task moves it")
            Task { await self?.refreshSteering(swarm) }
        }
    }

    // MARK: Messages

    /// `swarm.send <to> <text>`: a message from you to an agent of the selected goal's swarm.
    func sendSwarmMessage(_ words: [String]) {
        guard let board = goals.board ?? attentionQuestion?.board, board.swarm.status.active else {
            return say("no swarm going here")
        }
        guard words.count >= 2 else { return openCommandLine("swarm.send ") }
        guard let to = SwarmAddress.parse(words[0], tasks: board.tasks) else {
            return say(GoalOpError.unknownAddress(words[0]).description)
        }
        let text = words.dropFirst().joined(separator: " ")
        let swarm = board.swarm.id
        let now = Clock.now
        let numbers = SwarmPlan.numbers(board.tasks)
        planSteeringOp {
            try await $0.message(swarm: swarm, from: .you, to: to, text: text, actor: .you, now: now)
        } said: { _ in
            "sent to \(to.label(numbers)): typed into its pane once its agent is idle"
        }
    }

    private func planSteeringOp<T: Sendable>(
        _ operation: @escaping @Sendable (GoalOps) async throws -> T, said: @escaping @MainActor (T) -> String
    ) {
        goals.run(operation) { [weak self] result in
            switch result {
            case let .success(value):
                self?.say(said(value))
                Task { await self?.tickSteering() }
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    // MARK: The log

    /// `swarm.log.who [actor]`: the steering log by who decided, in turn (everyone, you, the controller, the lead,
    /// agents, heed), or the one named.
    func cycleLogActor(_ word: String?) {
        guard view == .goals, goals.board != nil else { return say("no swarm here") }
        if goals.pane != .plan { goals.togglePlan() }
        let order: [SwarmSteer.Actor?] = [nil] + SwarmSteer.Actor.allCases
        if let word {
            guard word == "all" || word == "everyone" || SwarmSteer.Actor(rawValue: word) != nil else {
                return say("no one called \(word): all, " + SwarmSteer.Actor.allCases.map(\.rawValue)
                    .joined(separator: ", "))
            }
            goals.logActor = SwarmSteer.Actor(rawValue: word)
        } else {
            let index = order.firstIndex(of: goals.logActor) ?? 0
            goals.logActor = order[(index + 1) % order.count]
        }
        goals.steeringCursor = 0
        goals.setFocus(.steering)
        let count = goals.shownSteering.count
        say("steering log: " + (goals.logActor.map { Self.actorTitle($0) } ?? "everyone") + " (\(count) row"
            + (count == 1 ? ")" : "s)"))
    }

    static func actorTitle(_ actor: SwarmSteer.Actor) -> String {
        switch actor {
        case .you: "you"
        case .controller: "the controller"
        case .lead: "the lead"
        case .agent: "agents"
        case .heed: "heed"
        }
    }

    /// `swarm.log.jump`: from a row to the question it is about, from a question to its answer; elsewhere, to the
    /// log at the newest open question (or the newest row).
    func jumpSteering() {
        guard view == .goals, let board = goals.board else { return say("no swarm here") }
        if goals.pane != .plan { goals.togglePlan() }
        if goals.focus == .steering, let row = goals.selectedSteer, let id = row.id {
            if row.kind == .question {
                guard let answer = board.questions.first(where: { $0.id == id })?.answer?.id else {
                    return say("not answered yet")
                }
                return goals.pointSteer(answer)
            }
            guard let about = row.about else { return say("this row is about nothing else") }
            return goals.pointSteer(about)
        }
        if let open = board.openQuestions.last?.id { return goals.pointSteer(open) }
        goals.setFocus(.steering)
        goals.steeringCursor = 0
    }

    func clickSteer(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.steering)
        goals.setSteeringCursor(index)
    }

    func steeringMenu(_ index: Int) -> [MenuEntry] {
        let rows = goals.shownSteering
        guard rows.indices.contains(index), let board = goals.board else { return [] }
        let row = rows[index]
        let id = row.kind == .question ? row.id : row.about
        let question = id.flatMap { id in board.questions.first { $0.id == id } }
        return ContextMenus.steeringRow(
            id: row.id ?? 0, question: question != nil, options: question?.row.options ?? [],
            answered: question?.answer != nil, byYou: question?.answer?.actor == .you,
            active: board.swarm.status.active
        )
    }

    // MARK: The fake world

    /// The fake world's steering: the running anchors swarm with its questions, the controller's answer you overruled,
    /// its messages and notes, as if they had happened. Nothing is typed anywhere.
    func loadSteeringFixture() {
        guard isFixture else { return }
        loadRunningSwarmFixture(.steering)
        steeringBoards = goals.boards.filter { $0.key == "\(SwarmFixtures.anchors)/swarm-1" }
        noteAttention()
        updateScope()
    }
}
