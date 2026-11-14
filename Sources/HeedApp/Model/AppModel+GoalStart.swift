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

    /// `goal.promote.go`: the goal made with the session on it (its merged PRs done, what it found planned), and its
    /// plan step opens. The session goes on as it was.
    func confirmPromotion() {
        guard let promotion = goalPromotion else { return say("gP first: what the goal would be") }
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
                say("\(goal.title) is a goal, this session its first part")
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
