import Foundation
import HeedCore

/// Personas in sessions: quiet by default. While the agent works, a faint stack of the personas who may look sits on
/// its sidebar row; at a milestone (`SessionMilestones`) a line at the session's foot offers a look; `gL` says yes,
/// opens the verdict, or asks now. One cheap call reads the agent's last turn and the diff (`SessionLookCalls`); the
/// verdict reaches the agent only when you send it. A PR the agent opens waits for the panel through its permission
/// hook (`PRGate`). The domain is HeedCore's; this gathers the inputs and runs git and the call off the main actor.
extension AppModel {
    func performSessionPanel(_ command: CommandInvocation) -> Bool {
        let words = command.arguments
        switch command.name {
        case "panel.ask": askPanel(words, target: command.target)
        case "panel.notnow": offerAnswered(never: false)
        case "panel.never": offerAnswered(never: true)
        case "panel.send": sendPanelVerdict(all: words.first == "all")
        case "panel.open": sessionPanel.expanded.toggle()
        case "panel.talk": talkToPanelPersona()
        case "panel.say":
            guard sessionPanel.chat != nil else { return true }
            sessionPanel.typing = ""
            textInputActive = true
        case "panel.dismiss": dismissPanelVerdict()
        case "panel.close":
            // ⎋ closes the innermost thing: the reasoning read in place, then the popover.
            if sessionPanel.expanded { sessionPanel.expanded = false } else { closePanel() }
        case "panel.row":
            let count = panelPopoverRows
            sessionPanel.row = count == 0 ? 0 : min(max(sessionPanel.row + (Int(words.first ?? "") ?? 1), 0), count - 1)
        case "panel.pr": choosePR(words.first ?? "")
        case "personas.sessions":
            personaUI.inSessions.toggle()
            personaUI.signal = 0
        case "personas.signal":
            let step = Int(words.first ?? "") ?? 1
            personaUI.signal = min(max(personaUI.signal + step, 0), SessionMilestone.Kind.signals.count - 1)
        case "personas.signal.toggle": toggleSignal(SessionMilestone.Kind.signals[personaUI.signal])
        default: return false
        }
        updateScope()
        return true
    }

    // MARK: Who looks

    /// The repos a session's personas are scoped by.
    func panelRepos(_ session: Session) -> [String] { session.involvedRepos.map(\.slug) }

    /// The personas who may look at a session (its sidebar row's faint stack): at most three, most relevant first.
    func panelAvatars(for session: Session) -> [Persona] {
        session.isChat ? [] : SessionPanelInvites.relevant(personaLibrary, repos: panelRepos(session))
    }

    /// What the panel's line at the session's foot shows.
    func panelLine(for session: Session) -> SessionPanelLine? {
        SessionPanelLine.of(
            record: sessionPanel.records[session.id], looking: sessionPanel.looking[session.id],
            hold: sessionPanel.holds[session.id]
        )
    }

    /// The key scope while the popover is open (or a chat in it); nil otherwise.
    var panelPopoverScope: String? {
        guard view == .sessions, let id = currentSession?.id, sessionPanel.open == id else { return nil }
        if sessionPanel.chat != nil { return "sessionspanelchat" }
        return sessionPanel.holds[id]?.look != nil ? "sessionspanelpr" : "sessionspanel"
    }

    /// The offer line's scope (x not now, N never here) while it shows on the session you are on.
    var panelOfferScope: String? {
        guard view == .sessions, let session = currentSession, case .offer = panelLine(for: session) else { return nil }
        return "sessionsoffer"
    }

    /// The look the popover shows: a held PR's, else the session's last.
    func panelLook(_ id: String) -> SessionLook? {
        sessionPanel.holds[id]?.look ?? sessionPanel.records[id]?.look
    }

    private var panelPopoverRows: Int {
        guard let id = sessionPanel.open else { return 0 }
        return panelLook(id)?.verdicts.count ?? 0
    }

    var sessionLookCalls: SessionLookCalls {
        if isFixture { return SessionLookCalls(run: SessionPanelFixtures.calls, read: SessionPanelFixtures.read) }
        return SessionLookCalls(run: { [weak self] request in
            guard let self else { throw LLMError.disabled }
            return try await runLLM(request)
        }, read: panelReader())
    }

    /// The strong look's run: the same headless, read-only run as the goal wizard's planner, by your default agent on
    /// its strongest model. nil when that agent cannot run that way (only claude and codex can): the look is then
    /// made at standard.
    private func panelReader() -> SessionLookCalls.Read? {
        let name = settings.defaultAgent
        guard let agent = settings.agent(name) else { return nil }
        let talker = PlanTalker(
            agent: name, command: agent.command, model: LLMTier.strong.model(agent: name),
            prices: config.usage.prices, exec: headlessExec(caller: SessionLookCalls.caller)
        )
        guard talker.canRead else { return nil }
        return { system, prompt, repos in try await talker.read(system: system, prompt: prompt, repos: repos) }
    }

    /// The folders a strong look reads: the session's own worktrees on this Mac (a remote session has none here).
    func panelReadRepos(_ session: Session) -> [String] {
        session.host == nil ? session.worktreePaths : []
    }

    // MARK: Milestones

    /// After the domain changed: a session's turn ended or its size was measured. Milestones found offer a look (or
    /// look, or nothing, as `[personas] offers` says). A session seen for the first time counts from where it is.
    func noticeSessionPanel(before: Domain, after: Domain) {
        guard !isFixture else { return }
        let settings = config.personas
        let earlier = Dictionary(before.sessions.map { ($0.id, $0.lastMessage) }) { first, _ in first }
        let now = Clock.now
        for session in after.sessions where !session.isChat && !session.parked {
            let ended = earlier[session.id].map { $0 != session.lastMessage && session.lastMessage != nil } ?? false
            let work = SessionWork.of(session, worktrees: after.worktrees, turnEnded: ended)
            guard let record = sessionPanel.records[session.id] else {
                // Not measured yet, and not new: wait for its size, so work done before is no milestone.
                if work.files != nil || now.timeIntervalSince(session.createdAt) < 600 {
                    sessionPanel.records[session.id] = .start(work, at: now)
                }
                continue
            }
            guard record.offer == nil, sessionPanel.looking[session.id] == nil, sessionPanel.holds[session.id] == nil,
                  let milestone = SessionMilestones.detect(work, record: record, settings: settings, now: now)
            else { continue }
            let personas = panelAvatars(for: session)
            switch SessionPanelPolicy.action(milestone, settings: settings, record: record, relevant: personas.count) {
            case .nothing:
                continue
            case .offer:
                sessionPanel.change(session.id) { $0.offering(milestone) }
            case .look:
                sessionPanel.change(session.id) { $0.offered.insert(milestone.key) }
                Task { _ = await lookNow(session.id, personas: personas, milestone: milestone) }
            }
        }
        updateScope()
    }

    /// The session a panel command acts on: a right-click's, else the one you are on in Sessions.
    private func panelSubject(_ target: CommandTarget?) -> Session? {
        if case let .session(id) = target { return sessions.first { $0.id == id } }
        return view == .sessions ? currentSession : nil
    }

    // MARK: Asking

    /// `panel.ask` (`gL`): on a held PR or a verdict, its popover (again: closed); on an offer, yes; otherwise ask now
    /// without a milestone. With names, only those personas look.
    func askPanel(_ names: [String], target: CommandTarget?) {
        guard let session = panelSubject(target) else { return say("no session here for the panel to look at") }
        guard !session.isChat else { return say("a chat has no diff for the panel: :promote makes it work") }
        if view != .sessions { view = .sessions }
        if currentSession?.id != session.id { select(sessionID: session.id) }
        let id = session.id
        let repos = panelRepos(session)
        if !names.isEmpty {
            let personas = SessionPanelInvites.asked(personaLibrary, repos: repos, picked: names)
            return startLook(session, personas: personas, milestone: asked())
        }
        if sessionPanel.looking[id] != nil { return say("the panel is reading…") }
        if sessionPanel.holds[id]?.look != nil || sessionPanel.records[id]?.look != nil,
           sessionPanel.records[id]?.offer == nil
        {
            if sessionPanel.open == id { return closePanel() }
            sessionPanel.open = id
            sessionPanel.row = 0
            sessionPanel.expanded = false
            return
        }
        if let offer = sessionPanel.records[id]?.offer {
            return startLook(session, personas: panelAvatars(for: session), milestone: offer)
        }
        startLook(session, personas: SessionPanelInvites.asked(personaLibrary, repos: repos), milestone: asked())
    }

    private func asked() -> SessionMilestone {
        SessionMilestone(kind: .asked, key: "asked@\(Int(Clock.now.timeIntervalSince1970))", at: Clock.now)
    }

    private func startLook(_ session: Session, personas: [Persona], milestone: SessionMilestone) {
        guard !personas.isEmpty else {
            return say("no persona may look at \(session.title): Settings › Personas (s: In sessions)")
        }
        say("asking \(personas.map(\.name).joined(separator: ", ")) for a look…")
        Task { _ = await lookNow(session.id, personas: personas, milestone: milestone) }
    }

    /// One look: the session's diff from git, then one cheap call for every persona. The verdict goes on the line
    /// (and the record); nil when it could not look.
    func lookNow(_ id: String, personas: [Persona], milestone: SessionMilestone) async -> SessionLook? {
        guard let session = sessions.first(where: { $0.id == id }), sessionPanel.looking[id] == nil else { return nil }
        sessionPanel.looking[id] = milestone
        updateScope()
        let seats = SessionPanelInvites.seats(personas)
        let owned = worktrees.filter { session.owns($0) }
        let task = session.prompt.isEmpty ? session.title : session.prompt
        let calls = sessionLookCalls
        let tier = config.personas.lookModel
        let repos = panelReadRepos(session)
        let fixture = isFixture
        let (diff, stat) = fixture ? ("", DiffStat(files: 14, added: 612, removed: 88)) : await SessionDiff.read(owned)
        defer {
            sessionPanel.looking[id] = nil
            updateScope()
        }
        do {
            let look = try await calls.look(
                milestone: milestone, task: task, lastTurn: session.lastMessage, diff: diff, stat: stat, seats: seats,
                now: Clock.now, tier: tier, repos: repos
            )
            if tier == .strong, look.tier != .strong {
                say("the panel read the diff only (a strong look needs claude or codex, and a worktree on this Mac)")
            }
            let work = SessionWork.of(session, worktrees: worktrees, turnEnded: false)
            if sessionPanel.records[id] == nil { sessionPanel.records[id] = .start(work, at: Clock.now) }
            sessionPanel.change(id) { $0.looked(look, work: work) }
            return look
        } catch {
            say("the panel could not look: \(error)")
            return nil
        }
    }

    // MARK: The offer

    /// Not now (the next milestone offers again), or never here.
    private func offerAnswered(never: Bool) {
        guard let session = panelSubject(commandTarget), sessionPanel.records[session.id]?.offer != nil else { return }
        let work = SessionWork.of(session, worktrees: worktrees, turnEnded: false)
        sessionPanel.change(session.id) { record in
            if never { record.never() } else { record.notNow(work, at: Clock.now) }
        }
        if never { say("no more offers in \(session.title): \(keyText(for: "panel.ask")) still asks") }
    }

    // MARK: The verdict

    /// Send to the agent: the full reasoning of the persona under the cursor, or of all of them, through its inbox
    /// (typed only under the usual rules). Personas never type.
    private func sendPanelVerdict(all: Bool) {
        guard let session = panelSubject(commandTarget), let look = panelLook(session.id) else { return }
        guard sessionPanel.holds[session.id] == nil else { return choosePR("concern") }
        let seat = look.verdicts.indices.contains(sessionPanel.row) ? look.verdicts[sessionPanel.row].seat : nil
        guard let message = all ? look.message(everyone: true) : seat.flatMap({ look.message(seat: $0) }) else {
            return say("nothing to send")
        }
        let id = session.id
        let what = all ? "the panel's reasoning" : look.seat(seat ?? "")?.name ?? "the persona"
        Task {
            let outcome = await notify(session: id, text: .owner(message))
            if outcome.sent { sessionPanel.change(id) { $0.look?.sent = true } }
            say("\(what): \(outcome.summary)")
        }
        closePanel()
    }

    private func dismissPanelVerdict() {
        guard let session = panelSubject(commandTarget) else { return }
        guard sessionPanel.holds[session.id] == nil else { return say("the PR waits for you: ↩ s or h") }
        sessionPanel.change(session.id) { $0.look = nil }
        closePanel()
    }

    func closePanel() {
        sessionPanel.open = nil
        sessionPanel.expanded = false
        sessionPanel.chat = nil
        endPanelTyping()
    }

    /// The popover closes when you move to another session; the offer line's keys follow the session you are on.
    func panelSessionMoved() {
        if let open = sessionPanel.open, open != currentSession?.id { closePanel() }
        updateScope()
    }

    // MARK: Talking to one

    /// `panel.talk` (`i`): a small chat with the persona under the cursor; again (or ⎋) closes it.
    private func talkToPanelPersona() {
        if sessionPanel.chat != nil {
            sessionPanel.chat = nil
            return endPanelTyping()
        }
        guard let id = sessionPanel.open, let look = panelLook(id), look.verdicts.indices.contains(sessionPanel.row),
              let seat = look.seat(look.verdicts[sessionPanel.row].seat)
        else { return }
        var chat = PersonaChat(seat: seat)
        let verdict = look.verdicts[sessionPanel.row]
        // It opens with what it said: the full reasoning when it gave one, else its line.
        chat.lines.append(.init(
            fromYou: false,
            text: verdict.reasoning.map { verdict.quote + "\n\n" + $0 }
                ?? verdict.quote + (verdict.fix.map { " (\($0))" } ?? "")
        ))
        sessionPanel.chat = chat
        sessionPanel.typing = ""
        textInputActive = true
    }

    /// The chat's field: what you typed goes to the persona, which answers in one cheap call.
    func submitPanelTyping() {
        let text = (sessionPanel.typing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        endPanelTyping()
        guard !text.isEmpty, var chat = sessionPanel.chat, let id = sessionPanel.open, let look = panelLook(id),
              let session = sessions.first(where: { $0.id == id })
        else { return updateScope() }
        chat.lines.append(.init(fromYou: true, text: text))
        sessionPanel.chat = chat
        sessionPanel.replying = true
        let calls = sessionLookCalls
        let tier = config.personas.lookModel
        let repos = panelReadRepos(session)
        let task = session.prompt.isEmpty ? session.title : session.prompt
        Task {
            defer { sessionPanel.replying = false }
            do {
                let reply = try await calls.reply(chat, look: look, task: task, tier: tier, repos: repos)
                guard sessionPanel.chat?.seat.id == chat.seat.id else { return }
                sessionPanel.chat?.lines.append(.init(fromYou: false, text: reply))
            } catch {
                say("\(chat.seat.name) could not answer: \(error)")
            }
        }
        updateScope()
    }

    func endPanelTyping() {
        guard sessionPanel.typing != nil else { return }
        sessionPanel.typing = nil
        textInputActive = false
    }

    // MARK: Before a PR opens

    /// The agent's `gh pr create`, from its permission hook: held while the panel looks. Everyone happy (or no
    /// one may look, or it is off), nil: the ask goes on to the approvals as it would have. A concern: it waits for
    /// your choice up to `[personas] hold_seconds`, then goes on. Never answered by heed on its own.
    func panelGate(_ ask: PermissionAsk) async -> PermissionAnswer? {
        let settings = config.personas
        guard !isFixture, settings.beforePR, settings.offers != .never, settings.holdSeconds > 0, PRGate.opensPR(ask),
              let session = sessions.first(where: { $0.id == ask.session }),
              sessionPanel.records[session.id]?.neverHere != true
        else { return nil }
        let personas = SessionPanelInvites.relevant(personaLibrary, repos: panelRepos(session), for: .beforePR)
        guard !personas.isEmpty else { return nil }
        if let running = sessionPanel.gates[ask.id] { return await running.value }
        let gate = Task { await holdPR(ask, session: session.id, personas: personas, seconds: settings.holdSeconds) }
        sessionPanel.gates[ask.id] = gate
        let answer = await gate.value
        sessionPanel.gates[ask.id] = nil
        return answer
    }

    private func holdPR(_ ask: PermissionAsk, session id: String, personas: [Persona], seconds: Int) async
        -> PermissionAnswer?
    {
        // The hook hears heed has it, so it waits instead of letting the agent ask in its pane.
        ControlServer.receipt(ask.id)
        let since = Date()
        sessionPanel.holds[id] = PRHold(ask: ask, since: since, until: since.addingTimeInterval(Double(seconds)))
        updateScope()
        defer {
            sessionPanel.holds[id] = nil
            if sessionPanel.open == id { closePanel() }
            updateScope()
        }
        let milestone = SessionMilestone(kind: .beforePR, key: "pr@\(ask.id)", at: Clock.now)
        guard let look = await lookNow(id, personas: personas, milestone: milestone), PRGate.holds(look),
              Date() < since.addingTimeInterval(Double(seconds))
        else { return nil }
        sessionPanel.holds[id]?.look = look
        updateScope()
        let deadline = since.addingTimeInterval(Double(seconds))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            self?.sessionPanel.choose(ask.id, nil)
        }
        let choice: PRGate.Choice? = await withCheckedContinuation { continuation in
            sessionPanel.choices[ask.id] = continuation
        }
        guard let choice else { return nil }
        if choice != .letOpen, let session = sessions.first(where: { $0.id == id }) {
            say(choice == .hold ? "\(session.title)'s PR is held: the agent was told to wait for you"
                : "the concern went to \(session.agent) first")
        }
        if choice == .sendConcern { sessionPanel.change(id) { $0.look?.sent = true } }
        return PRGate.answer(choice, look: look)
    }

    /// `panel.pr open|concern|hold`: your choice for the session's held PR.
    private func choosePR(_ word: String) {
        let choice: PRGate.Choice? = switch word {
        case "open": .letOpen
        case "concern": .sendConcern
        case "hold": .hold
        default: nil
        }
        guard let choice, let session = panelSubject(commandTarget), let hold = sessionPanel.holds[session.id],
              hold.look != nil
        else { return say("no PR waits for the panel here") }
        sessionPanel.choose(hold.ask.id, choice)
    }

    // MARK: Settings › Personas › In sessions

    private func toggleSignal(_ kind: SessionMilestone.Kind) {
        guard let key = kind.configKey else { return }
        setConfig(["personas", key], .bool(!config.personas.isOn(kind)))
    }
}

extension SessionMilestone.Kind {
    /// Settings' rows, in order.
    static let signals: [SessionMilestone.Kind] = [.built, .saysDone, .beforePR, .secondRepo, .long]

    /// Its switch in `[personas]`.
    var configKey: String? {
        switch self {
        case .built: "built"
        case .saysDone: "says_done"
        case .beforePR: "before_pr"
        case .secondRepo: "second_repo"
        case .long: "long"
        case .asked: nil
        }
    }
}

// MARK: The fake world

extension AppModel {
    enum PanelFixture { case quiet, offer, verdict, pr }

    /// The anchors session with the panel's personas in the library, at one of the designs' moments: quiet (only the
    /// faint stack), an offer after a lot got built, the verdict, a PR held with a concern.
    func loadSessionPanelFixture(_ moment: PanelFixture) {
        let files = SessionPanelFixtures.files
        goals.run { ops in
            for (id, text) in files {
                try await ops.saveLibrary(text: text, id: id)
            }
        }
        let id = SessionPanelFixtures.session
        guard var session = sessions.first(where: { $0.id == id }) else { return }
        let now = Clock.now
        if moment != .quiet {
            session.lastMessage = SessionPanelFixtures.lastMessage
            session.state = ObservedState(moment == .pr ? .blocked : .done)
            commit(.sessionUpserted(session))
        }
        select(sessionID: id)
        let library = SessionPanelFixtures.library()
        let repos = panelRepos(session)
        var record = SessionPanelRecord.start(SessionWork(), at: now)
        switch moment {
        case .quiet:
            break
        case .offer:
            record.offering(SessionPanelFixtures.built(at: now))
        case .verdict:
            record.look = SessionPanelFixtures.look(SessionPanelFixtures.built(at: now), library: library, repos: repos)
        case .pr:
            let milestone = SessionMilestone(kind: .beforePR, key: "pr@fixture", at: now)
            sessionPanel.holds[id] = PRHold(
                ask: SessionPanelFixtures.prAsk(at: now), since: now, until: now.addingTimeInterval(120),
                look: SessionPanelFixtures.look(milestone, library: library, repos: repos)
            )
        }
        sessionPanel.records[id] = record
        updateScope()
    }
}
