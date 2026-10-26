import AppKit
import Foundation
import HeedCore
import Synchronization

/// Model tokens spent by one look, counted as the decider's calls come back.
private final class TokenCount: Sendable {
    private let total = Mutex(0)

    func add(_ response: LLMResponse) {
        guard !response.fromCache, let tokens = response.tokens else { return }
        total.withLock { $0 += tokens.input + tokens.output }
    }

    var value: Int { total.withLock { $0 } }
}

/// What y, n, m and i act on: an ask (in Attention or Unassigned), any decision in Unassigned's feed, or a suggested
/// goal.
enum AttachTarget {
    case decision(AttachDecision)
    case suggestion(GoalSuggestion)
}

/// Goals' attachment (plan pipeline 1): when a session or chat starts, gets its first prompt, tracks a PR or gets a
/// ledger entry, heed looks for its goal (`GoalAttacher`: rules, free signals, the cheap model only when unsure) and
/// attaches, asks or leaves it, through `GoalOps`. Your answers, undos and moves go through `GoalOps` too, and write
/// rule lines. Fixtures never look on their own.
extension AppModel {
    /// After a commit: new sessions and chats, first prompts, PRs tracked.
    func noticeGoalAttach(before: Domain, after: Domain) {
        guard !isFixture, config.goals.attach.enabled else { return }
        for (id, trigger) in AttachTrigger.of(before: before, after: after) {
            findGoal(id, trigger: trigger)
        }
    }

    /// A session or chat as attachment sees it, with the files its ledger entry lists.
    func attachSubject(_ session: Session) -> AttachSubject {
        AttachSubject(session, files: ledger.entries[session.id]?.files ?? [])
    }

    /// Every session and chat, open or closed, by link key: what the goals' contexts are built from.
    private var attachSubjects: [String: AttachSubject] {
        var all: [String: AttachSubject] = [:]
        for session in history.map(\.session) + sessions {
            let subject = attachSubject(session)
            all[subject.key] = subject
        }
        return all
    }

    /// Looks for the goal of session `id`, unless it is on one, heed is looking already, or you settled it before
    /// (`asked`, from `goal.attach.find`, looks anyway). An open ask is looked at again only on new evidence (a PR,
    /// a ledger entry).
    func findGoal(_ id: String, trigger: AttachTrigger) {
        let asked = trigger == .asked
        guard asked || (!isFixture && config.goals.attach.enabled) else { return }
        guard let session = (sessions + history.map(\.session)).first(where: { $0.id == id }) else { return }
        let subject = attachSubject(session)
        if goals.bySession[id] != nil {
            if asked { say("\(session.title) is on \(goals.bySession[id]?.title ?? "a goal") already") }
            return
        }
        guard !goals.attach.inFlight.contains(subject.key) else { return }
        if !asked, let previous = goals.attach.decisions.first(where: { $0.subject.key == subject.key }) {
            let settled: Set<AttachDecision.State> = [.accepted, .declined, .moved, .undone, .ignored, .clustered]
            if settled.contains(previous.state) { return }
            if previous.state == .open, trigger != .pull, trigger != .ledger { return }
        }
        goals.attach.inFlight.insert(subject.key)
        let contexts = GoalContext.build(snapshot: goals.snapshot, subjects: attachSubjects)
        let settings = config.goals.attach
        let tokens = TokenCount()
        let decider: LLMDecider? = !isFixture && config.llm.enabled && settings.model
            ? LLMDecider(caller: "goals.attach") { [weak self] request in
                guard let self else { throw LLMError.disabled }
                let response = try await runLLM(request)
                tokens.add(response)
                return response
            } : nil
        let now = Clock.now
        if asked { say("looking for \(session.title)'s goal…") }
        goals.run { ops in
            let outcome = await GoalAttacher.decide(
                subject, contexts: contexts, rules: ops.rules(), settings: settings, decider: decider, now: now
            )
            return try await ops.act(subject, trigger: trigger, outcome: outcome, tokens: tokens.value, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            goals.attach.inFlight.remove(subject.key)
            switch result {
            case let .success(decision): announce(decision, asked: asked)
            case let .failure(error): if asked { say("no goal looked for: \(error)") }
            }
        }
    }

    private func goalTitle(_ id: String?) -> String {
        id.flatMap { goals.snapshot.goal($0)?.title } ?? id ?? "a goal"
    }

    /// Says what heed did: an attachment with its undo; an ask is in Attention (rules may notify); the rest only when
    /// you asked.
    private func announce(_ decision: AttachDecision, asked: Bool) {
        let title = decision.subject.title
        switch decision.verdict.action {
        case .attach:
            say(
                "\(title) → \(goalTitle(decision.goal)) (\(decision.verdict.reason)) · \(keyText(for: "goal.attach.undo", in: "goals")) undoes"
            )
        case .ask:
            noteAttention()
            if asked { say("not sure: \(title) → \(goalTitle(decision.verdict.goal))? Attention asks (y n m i)") }
        case .leave:
            if asked { say("\(title) stays unassigned: \(decision.verdict.reason)") }
        case .ignore:
            if asked { say("\(title) is ignored: \(decision.verdict.reason)") }
        }
    }

    // MARK: Commands

    /// `goal.unassigned`: Goals › Unassigned, or back to the overview.
    func showUnassigned() {
        if view != .goals {
            view = .goals
            goals.show(.unassigned)
        } else {
            goals.toggleUnassigned()
        }
        endGoalEditing()
    }

    /// `goal.attach.find`: look for the session's goal now.
    func findGoalNow() {
        guard let session = currentSession else { return say("no session here") }
        findGoal(session.id, trigger: .asked)
    }

    /// What y, n, m and i act on here, if anything.
    var attachTarget: AttachTarget? {
        if view == .attention, let item = attentionSelected?.item, let key = GoalAttachAsks.key(of: item.id) {
            return goals.attach.asks.first { $0.subject.key == key }.map(AttachTarget.decision)
        }
        guard view == .goals, goals.pane == .unassigned, let row = goals.attach.selected else { return nil }
        switch row {
        case let .ask(decision), let .decision(decision): return .decision(decision)
        case let .suggestion(suggestion): return .suggestion(suggestion)
        }
    }

    private func notHere(_ command: String) {
        // In Attention these keys keep their old use on everything that is not an ask.
        if view == .attention, command == "goal.ask.move" { return perform(CommandInvocation(name: "session.pin")) }
        if view == .attention, command == "goal.ask.ignore" { return }
        say(
            "y n m i answer heed's goal asks: in Attention, or in Goals › Unassigned (\(keyText(for: "goal.unassigned", in: "goals")))"
        )
    }

    /// `goal.ask.yes`: on the goal heed proposed; on a suggestion, the goal is made.
    func answerGoalYes() {
        if let goal = heldSpawnGoal { return startHeldSpawns(goal) }
        switch attachTarget {
        case let .decision(decision): answerGoal(decision, .yes)
        case let .suggestion(suggestion): createSuggestedGoal(suggestion)
        case nil: notHere("goal.ask.yes")
        }
    }

    /// `goal.ask.no`: not on that goal (heed learns); on a suggestion, it goes away.
    func answerGoalNo() {
        if let goal = heldSpawnGoal { return dropHeldSpawns(goal) }
        switch attachTarget {
        case let .decision(decision): answerGoal(decision, .no)
        case let .suggestion(suggestion):
            goals.attach.dismiss(suggestion)
            say("no goal made of \(suggestion.title)")
        case nil: notHere("goal.ask.no")
        }
    }

    /// `goal.ask.move <goal>`: on another goal instead; no goal: the command line, to pick one.
    func answerGoalMove(_ words: [String]) {
        switch attachTarget {
        case let .decision(decision):
            guard !words.isEmpty else { return openCommandLine("goal.ask.move ") }
            let query = words.joined(separator: " ")
            guard let goal = goals.snapshot.find(query) else {
                return say("no goal \(query): :goal.ask.move ⇥ lists them")
            }
            answerGoal(decision, .move(goal.id))
        case .suggestion: say("m moves one thing to a goal; y makes this suggestion a goal")
        case nil: notHere("goal.ask.move")
        }
    }

    /// `goal.ask.ignore`: leave things like this alone (heed learns `ignore`).
    func answerGoalIgnore() {
        switch attachTarget {
        case let .decision(decision): answerGoal(decision, .ignore)
        case .suggestion: say("n drops a suggestion; i ignores one thing and those like it")
        case nil: notHere("goal.ask.ignore")
        }
    }

    private func answerGoal(_ decision: AttachDecision, _ answer: AttachAnswer) {
        let now = Clock.now
        let title = decision.subject.title
        let proposed = goalTitle(decision.verdict.goal)
        goals.run { ops in
            try await ops.answer(decision.id, answer, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(done):
                switch answer {
                case .yes: say("\(title) is on \(proposed)")
                case .no: say("\(title) stays off \(proposed); heed learnt a never rule")
                case .move: say("\(title) is on \(goalTitle(done.goal)); heed learnt a never rule for \(proposed)")
                case .ignore: say("heed leaves things like \(title) alone (an ignore rule)")
                }
            case let .failure(error): say("\(error)")
            }
        }
    }

    /// `goal.attach.undo`: takes heed's last attachment off (or the one under the cursor in Unassigned).
    func undoGoalAttach() {
        var id: Int64?
        if view == .goals, goals.pane == .unassigned, case let .decision(decision)? = goals.attach.selected,
           decision.verdict.action == .attach, decision.state == .settled
        {
            id = decision.id
        }
        let now = Clock.now
        let undoing = id
        goals.run { ops in
            try await ops.undo(undoing, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(decision):
                say("\(decision.subject.title) is off \(goalTitle(decision.verdict.goal)); heed learnt a never rule")
            case let .failure(error): say("\(error)")
            }
        }
    }

    /// y on a suggestion: the model drafts its GOAL.md (with model calls off, or when that fails, a plain draft), the
    /// goal is made, and the work in it goes on it.
    func createSuggestedGoal(_ suggestion: GoalSuggestion) {
        let useModel = !isFixture && config.llm.enabled
        if useModel { say("drafting \(suggestion.title)'s GOAL.md…") }
        let summarizer = summarizer
        let instructions = summaryInstructions(for: nil)
        let now = Clock.now
        goals.run { ops in
            var draft = suggestion.fallbackDraft
            if useModel, let text = try? await summarizer.summarize(
                kind: .goalDraft, inputs: suggestion.draftInputs, instructions: instructions, caller: "goals.suggest"
            ), !GoalDoc.parse(text).title.isEmpty {
                draft = text
            }
            return try await ops.create(suggestion: suggestion, draft: draft, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(goal):
                goals.show(.overview)
                goals.point(to: goal.id)
                say("goal \(goal.title) made, with \(suggestion.subjects.count) on it: E reads its draft GOAL.md")
            case let .failure(error): say("no goal made: \(error)")
            }
        }
    }

    // MARK: Mouse and settings

    func clickAttachRow(_ index: Int) {
        guard clicksReachLists, view == .goals, goals.pane == .unassigned else { return }
        clickedOutsideTerminal()
        goals.attach.setCursor(index)
    }

    /// Settings' link: `attach.rules` in your editor, made first (its header only) when there is none.
    func openAttachRules() {
        guard !isFixture else { return say("fixture: no IO") }
        let url = goals.files.rules
        goals.run { ops in
            if try await ops.rulesText().isEmpty { try await ops.setRules(GoalOps.rulesHeader) }
        } done: { _ in
            NSWorkspace.shared.open(url)
        }
    }
}
