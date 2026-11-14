import AppKit
import Foundation
import HeedCore

/// The new-goal wizard (`goal.wizard`, and `n` in Goals): steps 1–3 here, Split, How careful and Go handed to the
/// goal's
/// page until they have screens (`WizardStep.built`, `wizard.later`), and the TL;DR (`goal.tldr`). The pure parts are
/// in HeedCore (`GoalWizard`, `PlanTalk`, `PanelInvites`, `DoneDraft`, `TLDRInputs`); this runs the model calls off the
/// main actor and saves the wizard after every change, so leaving and coming back resumes it.
extension AppModel {
    /// Handles the wizard's and the TL;DR's commands; false for any other.
    func performWizard(_ command: CommandInvocation) -> Bool {
        let words = command.arguments
        switch command.name {
        case "goal.wizard": openWizard(words)
        case "goal.tldr": toggleTLDR()
        case "wizard.leave": leaveWizard()
        case "wizard.next": wizardNext()
        case "wizard.step": showWizardStep(words.first ?? "next")
        case "wizard.row": goals.wizard.moveRow(Int(words.first ?? "") ?? 1)
        case "wizard.pick": wizardPick(Int(words.first ?? "") ?? 1)
        case "wizard.answer": beginWizardTyping()
        case "wizard.smaller": panelSmaller()
        case "wizard.talk": talkToPersona()
        case "wizard.drop": beginDrop()
        case "wizard.invite": invitePersona(words)
        case "wizard.invite.pick": pickInvite()
        case "wizard.use": useReplacement()
        case "wizard.define": defineCriterion(words.first.flatMap(Int.init))
        case "wizard.later": openLaterStep()
        case "tldr.copy": copyTLDR()
        case "tldr.act": actOnTLDR()
        default: return false
        }
        updateScope()
        return true
    }

    // MARK: Opening and leaving

    /// `goal.wizard [goal]`: the goal's wizard (the one under the cursor without a word), made at Plan when it has
    /// none, else where it was left.
    func openWizard(_ words: [String]) {
        let query = words.joined(separator: " ")
        let goal = query.isEmpty ? goals.selected : goals.snapshot.find(query)
        guard let goal else {
            return say(query.isEmpty ? "no goal here: n makes one" : "no goal \(query): :goal.wizard ⇥ lists them")
        }
        startWizard(goal.id, firstMessage: nil)
    }

    /// The goal's wizard shows; a new one starts with `firstMessage` (the ask, in your words) and heed's first
    /// question.
    func startWizard(_ goal: String, firstMessage: String?) {
        view = .goals
        goals.point(to: goal)
        let now = Clock.now
        let known = goals.wizard.wizard(of: goal)
        let doc = goals.snapshot.docs[goal]
        goals.run { ops in
            var wizard = try await ops.startWizard(goal: goal, now: now)
            if wizard.plan.turns.isEmpty {
                let ask = firstMessage ?? [doc?.title, doc?.goal].compactMap(\.self).filter { !$0.isEmpty }
                    .joined(separator: ": ")
                wizard.plan.answer(ask)
                try await ops.save(wizard: wizard)
            }
            return wizard
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(wizard):
                goals.wizard.set(known ?? wizard)
                goals.wizard.open = goal
                goals.wizard.resetCursors()
                updateScope()
                observeTutorNow()
                if !(known ?? wizard).step.built {
                    say(
                        "\((known ?? wizard).step.title) has no screen in the wizard yet: ↩ opens the goal's page for it"
                    )
                }
                continueWizard(goal)
            case let .failure(error): say("no wizard: \(error)")
            }
        }
    }

    /// `goal.open` on a goal whose wizard is not finished: back into it. False when there is none.
    func resumeWizardIfUnfinished() -> Bool {
        guard view == .goals, goals.focus == .goals, let goal = goals.selected, goals.wizard.unfinished(goal.id)
        else { return false }
        startWizard(goal.id, firstMessage: nil)
        return true
    }

    /// `wizard.leave`: back to the goals list; the wizard keeps its place.
    func leaveWizard() {
        guard let goal = goals.wizard.open else { return }
        goals.wizard.open = nil
        goals.wizard.resetCursors()
        textInputActive = false
        let step = goals.wizard.wizard(of: goal)?.step.title ?? ""
        say("the wizard waits at \(step): ↩ on the goal or :goal.wizard comes back")
    }

    /// What the step that shows needs and has not had: heed's next question, the panel's read, the draft.
    private func continueWizard(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), goals.wizard.busy[goal] == nil else { return }
        switch wizard.step {
        case .plan: if wizard.plan.open == nil, !wizard.state(of: .plan).isDone { runPlanTurn(goal) }
        case .panel: if wizard.panel.rounds.isEmpty { readPanel(goal) }
        case .done: if !wizard.criteria.drafted { draftDone(goal) }
        default: break
        }
    }

    private func change(_ goal: String, _ edit: (inout GoalWizard) -> Void) {
        guard var wizard = goals.wizard.wizard(of: goal) else { return }
        edit(&wizard)
        wizard.updatedAt = Clock.now
        goals.wizard.set(wizard)
        let saved = wizard
        goals.run { ops in try await ops.save(wizard: saved) }
        observeTutorNow()
    }

    private func busy(_ goal: String, _ what: String?) {
        goals.wizard.busy[goal] = what
        if what != nil { goals.wizard.problem[goal] = nil }
    }

    private func failed(_ goal: String, _ error: Error) {
        busy(goal, nil)
        let text = "\(error)"
        goals.wizard.problem[goal] = text
        say(text)
    }

    /// The step's calls through heed's model calls; scripted in the fake world.
    private var wizardCalls: WizardCalls {
        if isFixture { return WizardCalls(run: WizardFixtures.calls) }
        return WizardCalls { [weak self] request in
            guard let self else { throw LLMError.disabled }
            return try await runLLM(request)
        }
    }

    /// The big model's turns: your default agent on its strongest model, headless and read-only; scripted in the fake
    /// world.
    private func planTalker() -> PlanTalker? {
        if isFixture {
            return PlanTalker(agent: "claude", command: "claude", model: "opus", exec: WizardFixtures.planner)
        }
        let name = settings.defaultAgent
        guard let agent = settings.agent(name) else { return nil }
        let model = PlanTalk.strongest(agent: name)
        return PlanTalker(
            agent: name, command: agent.command, model: model, prices: config.usage.prices
        ) { arguments, stdin, directory in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-plan-\(UUID().uuidString)")
            try stdin.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let (path, pathVariable) = await ToolLocator.shared.executable(arguments[0])
            let result = try await ProcessRunner.run(
                path ?? arguments[0], Array(arguments.dropFirst()), in: directory,
                environment: ["PATH": pathVariable], timeout: .seconds(Int64(PlanTalk.timeout)), input: file,
                caller: "goals.wizard.plan"
            )
            guard result.succeeded || !result.stdout.isEmpty else {
                throw LLMOutputError(result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
                    ?? "exit \(result.status)")
            }
            return result.stdout
        }
    }

    /// The folders the planner reads: the goal's sessions' worktrees, and the repos the ask names.
    func planRepos(_ goal: String) -> [String] {
        let linked = goals.snapshot.links(of: goal).compactMap { link in
            sessions.first { $0.id == link.target && $0.host == nil }
        }
        .flatMap(\.worktreePaths)
        let doc = goals.snapshot.docs[goal]
        let ask = goals.wizard.wizard(of: goal)?.plan.turns.first?.text ?? ""
        let text = [doc?.title ?? "", doc?.goal ?? "", ask].joined(separator: " ")
        let records = repos.filter(\.location.isLocal).map { (slug: $0.repo.slug, path: $0.path) }
        return PlanTalk.repos(text: text, linked: linked, records: records)
    }

    // MARK: Step 1, Plan

    /// One turn: the planner reads the conversation (and the repos), asks its next question and updates the plan; the
    /// plan is saved as a GOAL.md version; a cheap call scores the meters.
    func runPlanTurn(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), let talker = planTalker() else {
            return say("no default agent to plan with: Settings › Agents")
        }
        let title = goals.snapshot.goal(goal)?.title ?? goal
        let statement = goals.snapshot.docs[goal]?.goal ?? ""
        let repos = planRepos(goal)
        let conversation = wizard.plan
        busy(goal, "heed is thinking")
        Task {
            do {
                let result = try await talker.turn(
                    title: title, statement: statement, conversation: conversation, repos: repos
                )
                await planTurnDone(goal, result)
            } catch {
                failed(goal, error)
            }
        }
    }

    private func planTurnDone(_ goal: String, _ result: PlanTurnResult) async {
        let reply = result.reply
        var plan = reply.plan
        if plan.title.isEmpty { plan.title = goals.snapshot.goal(goal)?.title ?? goal }
        let doc = plan.apply(to: goals.snapshot.docs[goal] ?? GoalDoc(title: plan.title))
        let now = Clock.now
        let saved = await withCheckedContinuation { continuation in
            goals.run { ops in
                try await ops.save(goal: goal, doc: doc, note: "plan", author: .heed, now: now)?.number
            } done: { result in
                continuation.resume(returning: (try? result.get()) ?? nil)
            }
        }
        change(goal) { wizard in
            wizard.plan.turns.append(PlanTurn(
                role: .heed, text: reply.question, options: reply.options, model: result.cost.model
            ))
            wizard.plan.add(plan, goalVersion: saved)
            wizard.spent(result.cost)
        }
        busy(goal, nil)
        if reply.complete { say("heed thinks the plan is complete enough: ⌘↩ moves on") }
        scorePlan(goal)
    }

    private func scorePlan(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), let plan = wizard.plan.current else { return }
        let calls = wizardCalls
        let turns = wizard.plan.turns
        Task {
            guard let (completeness, cost) = try? await calls.score(plan: plan, turns: turns) else { return }
            change(goal) { wizard in
                wizard.plan.completeness = completeness
                wizard.spent(cost)
            }
        }
    }

    /// `wizard.pick n`: Plan answers heed's question with option n; Done looks like highlights replacement n.
    func wizardPick(_ number: Int) {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current else { return }
        switch wizard.step {
        case .plan:
            guard goals.wizard.busy[goal] == nil else { return say("heed is still thinking") }
            var picked = wizard.plan
            guard picked.pick(number - 1) != nil else { return say("no option \(number) to pick") }
            change(goal) { $0.plan = picked }
            runPlanTurn(goal)
        case .done:
            let count = wizard.criteria.replacements(for: goals.wizard.row)?.count ?? 0
            guard number >= 1, number <= count else { return say("no replacement \(number)") }
            goals.wizard.pick = number - 1
        default:
            break
        }
    }

    /// `wizard.answer`: type an answer (Plan) or a message (talking to one persona).
    func beginWizardTyping() {
        guard let wizard = goals.wizard.current else { return }
        if goals.wizard.chat != nil {
            goals.wizard.typing = WizardBrowser.Typing(kind: .chat)
        } else if wizard.step == .plan {
            goals.wizard.typing = WizardBrowser.Typing(kind: .answer)
        } else {
            return
        }
        textInputActive = true
    }

    /// Keys while something is typed in the wizard: ↩ or ⌘↩ sends, ⎋ leaves it.
    func answerWizardText(_ stroke: KeyStroke) -> Bool {
        guard goals.wizard.typing != nil else { return false }
        switch stroke {
        case .escape:
            goals.wizard.typing = nil
            textInputActive = false
        case KeyStroke("CR", .command), KeyStroke("CR"): submitWizardTyping()
        default: return false
        }
        return true
    }

    func submitWizardTyping() {
        guard let goal = goals.wizard.open, let typing = goals.wizard.typing else { return }
        let text = typing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        goals.wizard.typing = nil
        textInputActive = false
        switch typing.kind {
        case .answer:
            guard !text.isEmpty else { return }
            if ["good enough", "enough", "done"].contains(text.lowercased()) { return wizardNext() }
            change(goal) { $0.plan.answer(text) }
            runPlanTurn(goal)
        case .chat:
            guard !text.isEmpty else { return }
            sendToPersona(goal, text)
        case .dropReason:
            dropGoal(goal, reason: text)
        }
        updateScope()
    }

    // MARK: ⌘↩

    /// `wizard.next`: Plan's good enough, Panel's worth it (take the fixes), Done's looks right; on a step with no
    /// screen yet, it counts as done.
    func wizardNext() {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current else { return }
        guard goals.wizard.busy[goal] == nil else { return say("\(goals.wizard.busy[goal] ?? "busy")…") }
        switch wizard.step {
        case .plan:
            guard wizard.plan.current != nil else { return say("no plan yet: answer heed's question first") }
            advance(goal)
        case .panel:
            guard !wizard.panel.rounds.isEmpty else { return readPanel(goal) }
            switch wizard.panel.next {
            case let .reread(fixes): takeFixes(goal, fixes)
            case .advance:
                change(goal) { wizard in
                    wizard.panel.decision = .worthIt
                    if let skeptic = wizard.panel.verdict(of: PanelInvites.skeptic.id), skeptic.kind != .happy {
                        wizard.panel.overruled = skeptic.quote
                    }
                }
                advance(goal)
            }
        case .done:
            guard wizard.criteria.drafted else { return draftDone(goal) }
            writeDoneWhen(goal)
            advance(goal)
        case .split, .careful, .go:
            advance(goal)
        }
    }

    private func advance(_ goal: String) {
        change(goal) { $0.advance(at: Clock.now) }
        goals.wizard.resetCursors()
        guard let wizard = goals.wizard.wizard(of: goal) else { return }
        if wizard.finished {
            goals.wizard.open = nil
            goals.show(.overview)
            say("the wizard is done: this is the goal's page")
        } else if !wizard.step.built {
            say("\(wizard.step.title) has no screen in the wizard yet: ↩ opens the goal's page that does it")
        }
        continueWizard(goal)
    }

    /// `wizard.step <prev|next|name>`.
    func showWizardStep(_ word: String) {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current else { return }
        let target: WizardStep? = switch word {
        case "prev": wizard.step.previous
        case "next": wizard.step.next
        default: WizardStep(word: word)
        }
        guard let target, target <= wizard.reach else { return say("not there yet: ⌘↩ moves on") }
        change(goal) { $0.show(target, at: Clock.now) }
        goals.wizard.resetCursors()
        continueWizard(goal)
    }

    // MARK: Step 2, Panel

    func readPanel(_ goal: String) {
        guard var wizard = goals.wizard.wizard(of: goal), let plan = wizard.plan.current else { return }
        if wizard.panel.seats.isEmpty {
            let library = Array(goals.personas.library.values)
            wizard.panel.seats = PanelInvites.invite(
                plan: plan, statement: wizard.plan.turns.first?.text ?? "",
                repos: planRepos(goal).map { URL(fileURLWithPath: $0).lastPathComponent },
                teamStyle: PanelInvites.teamStyle(in: library)
            )
            let seats = wizard.panel.seats
            change(goal) { $0.panel.seats = seats }
        }
        let seats = wizard.panel.seats
        let calls = wizardCalls
        busy(goal, "the panel reads the plan")
        Task {
            do {
                let (verdicts, cost) = try await calls.panel(plan: plan, seats: seats)
                change(goal) { wizard in
                    wizard.panel.rounds.append(verdicts)
                    wizard.spent(cost)
                }
                busy(goal, nil)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// The fixes into the plan (a new version, in GOAL.md too), and the panel reads it again.
    private func takeFixes(_ goal: String, _ fixes: [String]) {
        guard let plan = goals.wizard.wizard(of: goal)?.plan.current else { return }
        let calls = wizardCalls
        busy(goal, "the fixes go into the plan")
        Task {
            do {
                let (revised, cost) = try await calls.apply(fixes: fixes, to: plan)
                await revisePlan(goal, revised, cost: cost, note: "panel fixes")
                readPanel(goal)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// `wizard.smaller`: the plan cut down, and the panel reads it again while rounds are left.
    func panelSmaller() {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current, wizard.step == .panel,
              let plan = wizard.plan.current
        else { return }
        guard goals.wizard.busy[goal] == nil else { return }
        let hint = wizard.panel.verdict(of: PanelInvites.skeptic.id)?.fix
        let calls = wizardCalls
        busy(goal, "the plan gets smaller")
        Task {
            do {
                let (smaller, cost) = try await calls.smaller(plan, hint: hint)
                await revisePlan(goal, smaller, cost: cost, note: "smaller")
                if goals.wizard.wizard(of: goal)?.panel.canReread == true { readPanel(goal) }
            } catch {
                failed(goal, error)
            }
        }
    }

    private func revisePlan(_ goal: String, _ plan: WizardPlan, cost: WizardCost, note: String) async {
        let doc = plan.apply(to: goals.snapshot.docs[goal] ?? GoalDoc(title: plan.title))
        let now = Clock.now
        let saved = await withCheckedContinuation { continuation in
            goals.run { ops in
                try await ops.save(goal: goal, doc: doc, note: note, author: .heed, now: now)?.number
            } done: { result in
                continuation.resume(returning: (try? result.get()) ?? nil)
            }
        }
        change(goal) { wizard in
            wizard.plan.add(plan, goalVersion: saved)
            wizard.spent(cost)
        }
        busy(goal, nil)
    }

    /// `wizard.talk`: a chat with the persona under the cursor (again: close it).
    func talkToPersona() {
        if goals.wizard.chat != nil {
            goals.wizard.chat = nil
            return
        }
        guard let wizard = goals.wizard.current, wizard.step == .panel,
              wizard.panel.seats.indices.contains(goals.wizard.row)
        else { return }
        let seat = wizard.panel.seats[goals.wizard.row]
        var chat = PersonaChat(seat: seat)
        if let verdict = wizard.panel.verdict(of: seat.id) { chat.lines.append(.init(
            fromYou: false,
            text: verdict.quote
        )) }
        goals.wizard.chat = chat
        beginWizardTyping()
    }

    private func sendToPersona(_ goal: String, _ text: String) {
        guard var chat = goals.wizard.chat, let plan = goals.wizard.wizard(of: goal)?.plan.current else { return }
        chat.lines.append(.init(fromYou: true, text: text))
        goals.wizard.chat = chat
        let calls = wizardCalls
        let asked = chat
        busy(goal, "\(chat.seat.name) is answering")
        Task {
            do {
                let (reply, cost) = try await calls.reply(asked, plan: plan)
                goals.wizard.chat?.lines.append(.init(fromYou: false, text: reply))
                change(goal) { $0.spent(cost) }
                busy(goal, nil)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// `wizard.drop`: why not, typed (the Skeptic's words to start from); ↩ archives the goal.
    func beginDrop() {
        guard let wizard = goals.wizard.current, wizard.step == .panel else { return }
        let skeptic = wizard.panel.verdict(of: PanelInvites.skeptic.id)
        goals.wizard.typing = WizardBrowser.Typing(kind: .dropReason, text: skeptic?.quote ?? "")
        textInputActive = true
    }

    private func dropGoal(_ goal: String, reason: String) {
        let reason = reason.isEmpty ? "the panel said not to" : reason
        change(goal) { wizard in
            wizard.panel.decision = .drop
            wizard.dropped = reason
        }
        var edited = goals.snapshot.docs[goal] ?? GoalDoc(title: goal)
        edited.decisions.append(GoalDoc.Decision("Not doing it: \(reason)", source: "panel"))
        let doc = edited
        let now = Clock.now
        let active = goals.snapshot.goal(goal)?.status == .active
        goals.run { ops in
            try await ops.save(goal: goal, doc: doc, note: "dropped", author: .you, now: now)
            if active { _ = try await ops.archive(goal: goal, now: now) }
        } done: { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result { return say("not archived: \(error)") }
            goals.wizard.open = nil
            goals.wizard.resetCursors()
            updateScope()
            say("archived, with why in its GOAL.md")
        }
    }

    /// `wizard.invite [name]`: the `+` picker, or that persona straight on.
    func invitePersona(_ words: [String]) {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current, wizard.step == .panel else { return }
        if goals.wizard.inviting != nil, words.isEmpty {
            goals.wizard.inviting = nil
            return
        }
        let offered = PanelInvites.candidates(
            library: Array(goals.personas.library.values).sorted { $0.name < $1.name }, seated: wizard.panel.seats
        )
        if words.isEmpty {
            guard !offered.isEmpty else { return say("everyone heed knows is on the panel") }
            goals.wizard.inviting = offered
            goals.wizard.inviteRow = 0
            return
        }
        let name = words.joined(separator: " ").lowercased()
        guard let seat = offered.first(where: { $0.id == Persona.slug(name) || $0.name.lowercased() == name }) else {
            return say("no persona \(name) to invite")
        }
        invite(goal, seat: seat)
    }

    func pickInvite() {
        guard let goal = goals.wizard.open, let offered = goals.wizard.inviting,
              offered.indices.contains(goals.wizard.inviteRow)
        else { return }
        goals.wizard.inviting = nil
        invite(goal, seat: offered[goals.wizard.inviteRow])
    }

    private func invite(_ goal: String, seat: PanelSeat) {
        change(goal) { $0.panel.seats.append(seat) }
        say("\(seat.name) joins the panel: it reads the plan in the next round")
    }

    // MARK: Step 3, Done looks like

    func draftDone(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), let plan = wizard.plan.current else { return }
        let calls = wizardCalls
        let version = wizard.plan.versions.last?.number
        busy(goal, "heed drafts what done looks like")
        Task {
            do {
                let (draft, cost) = try await calls.draftDone(plan: plan, version: version)
                change(goal) { wizard in
                    wizard.criteria = draft
                    if draft.notTheGoal.isEmpty { wizard.criteria.notTheGoal = plan.outOfScope }
                    wizard.spent(cost)
                }
                busy(goal, nil)
                fetchReplacements(goal)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// Measurable replacements for every criterion nothing checks yet, once each.
    private func fetchReplacements(_ goal: String) {
        guard let wizard = goals.wizard.wizard(of: goal), let plan = wizard.plan.current else { return }
        let calls = wizardCalls
        for (index, criterion) in wizard.criteria.criteria.enumerated()
            where criterion.check.kind == .none && wizard.criteria.replacements(for: index) == nil
        {
            Task {
                guard let (options, cost) = try? await calls.replacements(for: criterion.text, plan: plan)
                else { return }
                change(goal) { wizard in
                    guard wizard.criteria.criteria.indices.contains(index),
                          wizard.criteria.criteria[index].text == criterion.text
                    else { return }
                    wizard.criteria.set(replacements: options, for: index)
                    wizard.spent(cost)
                }
            }
        }
    }

    /// `wizard.use`: the criterion under the cursor becomes the highlighted replacement ("drop it: …" drops it).
    func useReplacement() {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current, wizard.step == .done else { return }
        let row = goals.wizard.row
        guard let options = wizard.criteria.replacements(for: row), options.indices.contains(goals.wizard.pick) else {
            return say("nothing to use here: a criterion nothing checks gets replacements")
        }
        let chosen = options[goals.wizard.pick]
        change(goal) { wizard in
            if chosen.lowercased().hasPrefix("drop it") {
                wizard.criteria.drop(row)
            } else {
                wizard.criteria.replace(row, with: chosen)
            }
        }
        goals.wizard.pick = 0
        goals.wizard.row = min(row, max((goals.wizard.current?.criteria.criteria.count ?? 1) - 1, 0))
    }

    /// `wizard.define [n]`: "define it with an agent". Until heed opens an agent beside the step for this, the plan's
    /// read-only agent reads the repos and proposes checks it could run; they join the criterion's replacements.
    func defineCriterion(_ number: Int?) {
        guard let goal = goals.wizard.open, let wizard = goals.wizard.current else { return }
        if wizard.step != .done {
            change(goal) { $0.show(.done, at: Clock.now) }
            goals.wizard.tldr = nil
        }
        let index = number.map { $0 - 1 } ?? goals.wizard.row
        guard let fresh = goals.wizard.current, fresh.criteria.criteria.indices.contains(index),
              let talker = planTalker()
        else { return say("no criterion \(number.map(String.init) ?? "") to define") }
        goals.wizard.row = index
        let criterion = fresh.criteria.criteria[index].text
        let title = goals.snapshot.goal(goal)?.title ?? goal
        var conversation = fresh.plan
        conversation.answer(
            "Propose how to check this criterion with something you can run in these repos (a test, a CI step or a "
                + "command): \"\(criterion)\". Ask which one as your question; give each as an option."
        )
        let repos = planRepos(goal)
        busy(goal, "an agent reads the repo for a check")
        Task {
            do {
                let result = try await talker.turn(
                    title: title, statement: "", conversation: conversation, repos: repos
                )
                change(goal) { wizard in
                    let known = wizard.criteria.replacements(for: index) ?? []
                    wizard.criteria.set(replacements: Array((result.reply.options + known).prefix(4)), for: index)
                    var cost = result.cost
                    cost.step = .done
                    wizard.spent(cost)
                }
                goals.wizard.pick = 0
                busy(goal, nil)
            } catch {
                failed(goal, error)
            }
        }
    }

    /// The criteria into GOAL.md's Done when, as a new version.
    private func writeDoneWhen(_ goal: String) {
        guard let draft = goals.wizard.wizard(of: goal)?.criteria else { return }
        let doc = draft.apply(to: goals.snapshot.docs[goal] ?? GoalDoc(title: goal))
        let now = Clock.now
        goals.run { ops in
            try await ops.save(goal: goal, doc: doc, note: "done looks like", author: .heed, now: now)
        }
    }

    // MARK: Steps 4–6, until they have screens

    /// `wizard.later`: the goal's page that does the step today: the swarm's plan (Split), Reviewers' bars (How
    /// careful), the overview (Go). The wizard keeps its place.
    func openLaterStep() {
        guard let wizard = goals.wizard.current else { return }
        goals.wizard.open = nil
        switch wizard.step.fallback {
        case .swarm: goals.show(.plan)
        case .reviewers: goals.show(.reviewers)
        case .overview, .none: goals.show(.overview)
        }
        say("\(wizard.step.title) on the goal's page; :goal.wizard comes back to the wizard")
    }

    // MARK: TL;DR

    /// The goal the TL;DR is of: the wizard's, else the one under the cursor.
    private var tldrGoal: String? { goals.wizard.open ?? (view == .goals ? goals.selected?.id : nil) }

    /// What a TL;DR is written from; a goal that never went through the wizard is read from its GOAL.md.
    func tldrInputs(_ goal: String) -> TLDRInputs {
        let doc = goals.snapshot.docs[goal]
        let version = goals.snapshot.goal(goal)?.version ?? 1
        if let wizard = goals.wizard.wizard(of: goal) {
            return TLDRInputs.build(wizard, doc: doc, goalVersion: version)
        }
        var loose = GoalWizard(goal: goal, at: .distantPast)
        if let doc {
            loose.plan.add(WizardPlan.read(doc), goalVersion: version)
            loose.criteria.criteria = doc.doneWhen.map(DoneDraft.read)
        }
        // Its open points have nowhere to act yet: the wizard has not seen the goal.
        var inputs = TLDRInputs.build(loose, doc: doc, goalVersion: version)
        inputs.open = inputs.open.map { WizardOpenPoint($0.text) }
        return inputs
    }

    /// The TL;DR that shows: the cached one while it is fresh, else heed's own while the model writes.
    func shownTLDR(_ goal: String) -> WizardTLDR {
        let inputs = tldrInputs(goal)
        if let cached = goals.wizard.wizard(of: goal)?.tldr ?? goals.wizard.looseTLDRs[goal],
           cached.fresh(for: inputs)
        {
            return cached
        }
        return WizardTLDR.plain(inputs, at: Clock.now)
    }

    /// `goal.tldr`: opens the TL;DR (again, or ⎋: closes it). Written by a cheap model when what it is written from
    /// changed since it was last.
    func toggleTLDR() {
        if goals.wizard.tldr != nil {
            goals.wizard.tldr = nil
            return
        }
        guard let goal = tldrGoal else { return say("no goal here") }
        goals.wizard.tldr = goal
        let inputs = tldrInputs(goal)
        let seen = inputs.seen
        if goals.wizard.wizard(of: goal) != nil {
            if goals.wizard.wizard(of: goal)?.tldrSeen != seen { change(goal) { $0.tldrSeen = seen } }
        } else {
            goals.wizard.looseSeen[goal] = seen
        }
        let cached = goals.wizard.wizard(of: goal)?.tldr ?? goals.wizard.looseTLDRs[goal]
        guard cached?.fresh(for: inputs) != true, !goals.wizard.writing.contains(goal) else { return }
        let calls = wizardCalls
        goals.wizard.writing.insert(goal)
        Task {
            let now = Clock.now
            let written = await (try? calls.tldr(inputs, now: now))?.0 ?? WizardTLDR.plain(inputs, at: now)
            goals.wizard.writing.remove(goal)
            if goals.wizard.wizard(of: goal) != nil {
                change(goal) { $0.tldr = written }
            } else {
                goals.wizard.looseTLDRs[goal] = written
            }
        }
    }

    /// The TL;DR's entry for a goal: nil until there is something to summarise, else its news and open points.
    func tldrBadge(_ goal: String) -> TLDRBadge? {
        let wizard = goals.wizard.wizard(of: goal)
        guard TLDRInputs.available(wizard, doc: goals.snapshot.docs[goal]) else { return nil }
        return tldrInputs(goal).badge(since: wizard?.tldrSeen ?? goals.wizard.looseSeen[goal])
    }

    /// `tldr.copy`: the TL;DR as markdown on the clipboard.
    func copyTLDR() {
        guard let goal = goals.wizard.tldr else { return }
        let tldr = shownTLDR(goal)
        let title = tldrInputs(goal).title
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tldr.markdown(title: title), forType: .string)
        say("TL;DR copied as markdown")
    }

    /// `tldr.act`: the first open point's action (define a criterion, back to the panel or the plan).
    func actOnTLDR() {
        guard let goal = goals.wizard.tldr else { return }
        guard let action = shownTLDR(goal).open.compactMap(\.action).first else { return say("nothing open to act on") }
        goals.wizard.tldr = nil
        if goals.wizard.open != goal { startWizard(goal, firstMessage: nil) }
        let (name, arguments) = action.command
        perform(CommandInvocation(name: name, arguments: arguments))
    }

    // MARK: The fake world

    /// Shots: the designs' goal in the wizard at `step`, open.
    func loadWizardFixture(_ step: WizardStep) {
        guard isFixture else { return }
        let fixture = WizardFixtures.goal()
        var wizard = WizardFixtures.wizard(at: step)
        if step == .split {
            wizard.tldr = WizardTLDR.plain(
                TLDRInputs.build(wizard, doc: nil, goalVersion: fixture.goal.version), at: Clock.now
            )
        }
        goals.loadWizardFixture(fixture, wizard: wizard)
        view = .goals
        goals.point(to: fixture.goal.id)
        goals.wizard.open = fixture.goal.id
        goals.wizard.resetCursors()
        if step == .done { goals.wizard.row = 4 }
        updateScope()
    }
}

private extension WizardStepState {
    var isDone: Bool { self == .done }
}
