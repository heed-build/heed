import Foundation
import HeedCore

/// The ways into a guided goal from Sessions: Start work sizing a longer prompt (`TaskSizer`, the card's Make it a
/// goal), and a session growing into a goal (`GoalGrowth`, the line at the foot of its panes and `gP`). Both end in
/// the goal's wizard (`goal.wizard <id>`), or, where heed has none, on the goal's overview as `goal.new` does.
extension AppModel {
    // MARK: Start work sizes the task

    /// Start work opened: a sizer when `[start_work] size_check` is on and decisions can run. Fixtures and the tutor
    /// never ask, so shots and lessons stay the same everywhere; a shot lays a sizing in by hand.
    func prepareStartWorkSize() {
        startWorkSizer?.cancel()
        startWorkSizer = nil
        guard config.startWork.sizeCheck, !isFixture, tutor == nil, config.decisions.effective != .off else { return }
        let decider = decider(caller: "work.size")
        let run: TaskSizer.Run = { [weak self] request in
            guard let self else { throw LLMError.disabled }
            return try await runLLM(request)
        }
        startWorkSizer = TaskSizeScheduler { [weak self] key in
            let repos = await MainActor.run { self?.startWork?.selectedRepos ?? [] }
            return await TaskSizer.size(prompt: key, repos: repos, decider: decider, run: run)
        }
        startWork?.sizeCheck = true
    }

    /// After every change to the dialog (`now`: ⌘↩ waits on it): sizes the prompt once typing pauses. An answer for
    /// a prompt no longer typed is dropped; one ⌘↩ waited for starts the work or shows the card.
    func sizeStartWork(now: Bool = false) {
        guard let form = startWork else {
            startWorkSizer?.cancel()
            return
        }
        guard let sizer = startWorkSizer else {
            // Nothing can size here: a ⌘↩ that waited starts.
            if now, let key = form.sizeQuestion { deliverSize(nil, for: key) }
            return
        }
        sizer.ask(form.sizeQuestion, now: now) { [weak self] key, sizing in
            self?.deliverSize(sizing, for: key)
        }
    }

    private func deliverSize(_ sizing: TaskSizing?, for key: String) {
        guard var form = startWork else { return }
        let outcome = form.sized(sizing, for: key)
        startWork = form
        if case let .start(plan) = outcome { proceed(plan) }
    }

    /// Make it a goal on the card: the goal from the prompt, then its wizard's first step, since you chose a goal.
    func makeGoal(_ draft: StartGoal) {
        let repo = draft.repos.first.flatMap { id in repos.first { $0.id == id }?.repo.slug }
        let tracker = config.goals.mirror.tracker(for: repo) ?? ""
        createGoal(
            GoalsBrowser.Form(
                title: draft.title, statement: draft.statement, tracker: tracker,
                mirror: !tracker.isEmpty && config.goals.mirror.mirrors(for: repo)
            ),
            wizard: true
        )
    }

    /// The goal's wizard (`goal.wizard <id>`) where heed has one; false when it has not, and the goal's overview
    /// stays where `createGoal` put you.
    @discardableResult
    func openGoalWizard(_ goal: String) -> Bool {
        guard Commands.spec("goal.wizard") != nil else { return false }
        perform(CommandInvocation(name: "goal.wizard", arguments: [goal]))
        return true
    }

    // MARK: A session growing into a goal

    /// Whether `session` is growing into a goal: two PRs or more, a second repo, or work its agent found and did not
    /// start. Never a chat, one on a goal, or one put aside (`x`).
    func goalGrowth(for session: Session) -> GoalGrowth? {
        GoalGrowth.of(
            session, pullState: { [github] in github.pull($0)?.state }, onGoal: goals.bySession[session.id] != nil,
            setAside: promotionsSetAside.contains(session.id)
        )
    }

    private func promotionSubject(_ target: CommandTarget?) -> Session? {
        if case let .session(id) = target { return sessions.first { $0.id == id } }
        return view == .sessions ? currentSession : nil
    }

    /// `goal.promote` (`gP`, the line's Make it a goal): the popover with what the goal would be. Again (or ⎋):
    /// closed.
    func promoteToGoal(from target: CommandTarget?) {
        if goalPromotion != nil, target == nil { return goalPromotion = nil }
        guard let session = promotionSubject(target) else { return say("no session here to make a goal of") }
        guard !session.isChat else { return say("a chat becomes work first: :promote") }
        if let goal = goals.bySession[session.id] {
            return say("\(session.title) is on \(goal.title) already: 'g goes there")
        }
        if view != .sessions { view = .sessions }
        if currentSession?.id != session.id { select(sessionID: session.id) }
        goalPromotion = GoalPromotion.draft(session, growth: goalGrowth(for: session)) { [github] ref in
            github.pull(ref).map { ($0.state, $0.title) }
        }
        nameFoundWork(of: session)
    }

    /// What the session found, named by a cheap model call while the popover shows its clauses; never in the fake
    /// world. An answer for a popover since closed or moved is dropped.
    private func nameFoundWork(of session: Session) {
        let sentences = GoalGrowth.foundSentences(in: session.lastMessage)
        guard !isFixture, !sentences.isEmpty else { return }
        let run: FoundWork.Run = { [weak self] request in
            guard let self else { throw LLMError.disabled }
            return try await runLLM(request)
        }
        Task { [weak self] in
            guard let named = await FoundWork.summarise(sentences, run: run), let self,
                  goalPromotion?.session == session.id
            else { return }
            goalPromotion?.found = named
        }
    }

    /// `goal.promote.go`: asks the session's agent for a handoff (what is done, decided, open, risky and next), then
    /// makes the goal with the session on it (its merged PRs done, what was open planned) and opens its plan step,
    /// which starts from the handoff. Where there is nobody to ask, asking is off, or the agent does not answer in
    /// time (`[goals] handoff_timeout`), it makes the goal from the session's prompt as it always did, with a note.
    /// The session goes on as it was.
    func confirmPromotion() {
        guard let promotion = goalPromotion else { return say("gP first: what the goal would be") }
        if let ask = promotionHandoff, ask.isOpen {
            return say(
                "asking \(ask.agent) for a handoff: \(keyText(for: "goal.promote.skip", asIn: "sessionspromote")) starts without it"
            )
        }
        guard let ask = handoffAsk(for: promotion) else { return makeGoal(from: promotion, note: nil) }
        promotionHandoff = ask
        if ask.isOpen { runHandoffAsk() } else { resolveHandoff() }
    }

    /// The ask for the promotion's session; nil where it is not made (off, or the fake world and the tutor, which
    /// never message agents).
    private func handoffAsk(for promotion: GoalPromotion) -> HandoffAsk? {
        guard !isFixture, tutor == nil, let session = sessions.first(where: { $0.id == promotion.session }) else {
            return nil
        }
        let pane = layouts[session.id].flatMap { agentPane(in: $0)?.1 }
        return HandoffAsk.begin(
            session: session.id, agent: session.agent, state: session.state.state,
            hasAgentPane: pane.map { TerminalSurfaces.shared.hasTerminal(paneID: $0) } ?? false, host: session.host,
            timeout: TimeInterval(config.goals.handoffTimeout), now: Clock.now
        )
    }

    /// Tries to deliver the ask every second (it waits while the agent works or you type there, and never types into
    /// a busy session: `HandoffAsk.route`), and gives up when the time is up.
    private func runHandoffAsk() {
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, promotionHandoff?.isOpen == true else { return }
                if promotionHandoff?.unsent == true { await deliverHandoffAsk() }
                guard var ask = promotionHandoff, ask.isOpen else { return }
                ask.tick(now: Clock.now)
                if ask != promotionHandoff { promotionHandoff = ask }
                if !ask.isOpen { return resolveHandoff() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func deliverHandoffAsk() async {
        guard var ask = promotionHandoff, ask.unsent,
              let session = sessions.first(where: { $0.id == ask.session })
        else { return }
        guard let pane = layouts[session.id].flatMap({ agentPane(in: $0)?.1 }),
              TerminalSurfaces.shared.hasTerminal(paneID: pane)
        else {
            ask.delivered(.failed("its agent isn't running (no agent pane)"))
            promotionHandoff = ask
            return
        }
        let route = HandoffAsk.route(
            state: session.state.state, lastTyped: lastTyped[session.id], inbox: inbox(forPane: pane),
            settings: settings.channels, now: Clock.now
        )
        if case let .wait(why) = route {
            ask.delivered(.waiting(why))
            if ask != promotionHandoff { promotionHandoff = ask }
            return
        }
        let outcome = await notify(session: session.id, text: SessionHandoff.ask)
        guard var after = promotionHandoff, after.session == ask.session else { return }
        after.delivered(outcome)
        promotionHandoff = after
    }

    /// `heed goal handoff` from the session's pane: the handoff the ask was waiting for. One heed cannot read is
    /// refused with why, so the agent can write it again while there is time.
    func receiveHandoff(_ text: String, from session: String?) -> GoalReply {
        guard let session, var ask = promotionHandoff, ask.session == session, ask.isOpen else {
            return .refused(
                "heed is not waiting for a handoff from this session: it asks when the owner makes it a goal, and "
                    + "stops waiting after a while (heed goal --help)"
            )
        }
        switch ask.receive(text) {
        case let .failure(problem):
            promotionHandoff = ask
            return .refused("that handoff was not readable: \(problem). Write it again and run heed goal handoff")
        case .success:
            promotionHandoff = ask
            resolveHandoff()
            return GoalReply("handoff", message: "heed has it: the goal is made from it, nothing more to do here")
        }
    }

    /// `goal.promote.skip`: stop waiting; the goal is made from the session's prompt.
    func skipHandoff() {
        guard var ask = promotionHandoff, ask.isOpen else { return say("not waiting for a handoff") }
        ask.skip()
        promotionHandoff = ask
        resolveHandoff()
    }

    /// The ask is over: the goal is made with the handoff, or without it (and why).
    private func resolveHandoff() {
        guard let ask = promotionHandoff, let resolution = ask.resolution, var promotion = goalPromotion else { return }
        var note: String?
        switch resolution {
        case let .handoff(handoff): promotion = promotion.handingOff(handoff)
        case let .without(why): note = why
        }
        goalPromotion = nil
        makeGoal(from: promotion, note: note)
    }

    /// The popover is gone or done: nobody waits for a handoff any more.
    func endHandoffAsk() {
        handoffTask?.cancel()
        handoffTask = nil
        if promotionHandoff != nil { promotionHandoff = nil }
    }

    private func makeGoal(from promotion: GoalPromotion, note: String?) {
        goalPromotion = nil
        let now = Clock.now
        goals.run { ops in
            try await ops.promote(promotion, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(goal):
                view = .goals
                goals.point(to: goal.id)
                goals.show(.overview)
                say(
                    "\(goal.title) is a goal, this session its first part"
                        + (promotion.handoff != nil ? ", the plan starts from its handoff" : "")
                        + (note.map { ": " + $0 } ?? "")
                )
                openGoalWizard(goal.id)
            case let .failure(error): say("no goal made: \(error)")
            }
        }
    }

    /// `goal.promote.dismiss` (`x` on the popover, the line's ✕): not now. The line goes for this session for good;
    /// `gP` still makes it a goal.
    func setPromotionAside(from target: CommandTarget?) {
        guard let id = goalPromotion?.session ?? promotionSubject(target)?.id else { return }
        goalPromotion = nil
        promotionsSetAside.insert(id)
        if !isFixture { UserDefaults.standard.set(promotionsSetAside.sorted(), forKey: "promotionsSetAside") }
        say("not now: \(keyText(for: "goal.promote", asIn: "sessions")) still makes it a goal")
    }

    /// The popover belongs to the session it was opened on: moving to another closes it.
    func closePromotionIfMoved() {
        guard let promotion = goalPromotion, promotion.session != currentSession?.id || view != .sessions else {
            return
        }
        goalPromotion = nil
    }
}
