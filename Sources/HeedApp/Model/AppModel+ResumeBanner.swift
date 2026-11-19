import AppKit
import Foundation
import HeedCore

/// Picking an agent's conversation up again after launch (`ResumeBanner`): the banner over a session whose agent is not
/// running, its keys, and what feeds the rule.
extension AppModel {
    /// The offer for a session, or nil: its agent runs, there is nothing to resume, or this is not the place (the
    /// tutor's scripted sessions, the resume dialog still open).
    func resumeOffer(for session: Session) -> ResumeBanner.Offer? {
        guard tutor == nil, resume == nil else { return nil }
        return ResumeBanner.offer(
            session: session, layout: layouts[session.id], agent: settings.agent(session.agent),
            presence: agentPresence, conversation: conversationChecks[session.id]
        )
    }

    /// The banner over the session's panes: its offer, until you dismiss it.
    func resumeBanner(for session: Session) -> ResumeBanner.Offer? {
        resumeBannerDismissed.contains(session.id) ? nil : resumeOffer(for: session)
    }

    /// Panes whose zmx session survived heed's restart still have their agent, unless it had ended before.
    func noteLivePanes(in domain: Domain) {
        guard !isFixture else { return }
        let live = TerminalSurfaces.shared.livePanes
        for session in domain.sessions {
            for pane in domain.layouts[session.id]?.tabs.flatMap(\.tree.panes) ?? [] where live.contains(pane.id) {
                agentPresence.reattached(pane.id, sessionState: session.state.state)
            }
        }
    }

    /// What a hook or the screen says of a pane's agent, written only when it changes who runs: every hook says it,
    /// and each write would redraw what reads `agentPresence`.
    func observePresence(_ state: AgentState, in pane: String) {
        guard agentPresence.changes(observing: state, in: pane) else { return }
        agentPresence.observed(state, in: pane)
    }

    /// What a hook said about a pane's agent: it is there, or it is gone.
    func noteAgent(_ kind: HookMessage.Kind, pane: String?, session: Session) {
        guard let pane else { return }
        switch kind {
        case let .state(state, _), let .guess(state, _):
            observePresence(state, in: pane)
            if state == .exited { checkConversations(of: [session.id]) }
        case .atPrompt:
            observePresence(.idle, in: pane)
        default:
            break
        }
    }

    /// Whether the agent still has a session's conversation, read off the main actor: all sessions at launch, one when
    /// its agent says its id or ends. Where heed cannot tell (not claude), it assumes the agent does.
    func checkConversations(of ids: Set<String>? = nil) {
        guard !isFixture else { return }
        let domain = currentDomain
        let targets = domain.sessions.filter { ids?.contains($0.id) ?? true }.filter { $0.agentSessionID != nil }
        guard !targets.isEmpty else { return }
        // Checks run in any order: a report from one older than the session's latest check is ignored.
        let generation = conversationChecks.begin(targets.map(\.id))
        Task.detached(priority: .utility) {
            let found = targets.map { ($0.id, Self.agentHasConversation($0, in: domain) != false) }
            await MainActor.run { [found] in
                for (id, exists) in found {
                    self.conversationChecks.report(id, exists: exists, generation: generation)
                }
            }
        }
    }

    /// As the launch dialog asks it: the agent's own files, in the directory of the session's first pane.
    nonisolated static func agentHasConversation(_ session: Session, in domain: Domain) -> Bool? {
        let directory = domain.layouts[session.id]?.tabs.first?.tree.panes.first?.directory ?? ""
        return AgentIntegration.hasSession(
            agent: session.agent, id: session.agentSessionID ?? "", directory: directory
        )
    }

    private func bannerSession(_ target: CommandTarget?) -> Session? {
        if case let .session(id) = target { return sessions.first { $0.id == id } }
        return currentSession
    }

    /// What the menus and keys do for a session now (`ResumePlan`).
    func resumeDecision(_ purpose: ResumePlan.Purpose, for session: Session) -> ResumePlan.Decision {
        ResumePlan.decide(
            purpose, session: session, layout: layouts[session.id], agent: settings.agent(session.agent),
            presence: agentPresence, conversationOnDisk: conversationChecks[session.id].onDisk
        )
    }

    /// Why the session's resume items are greyed out, for its menus; nil when they can run.
    func resumeBlocked(_ purpose: ResumePlan.Purpose, for session: Session) -> String? {
        resumeDecision(purpose, for: session).reason
    }

    /// `agent.resume` and `agent.fresh`: the same code as the launch dialog's, for one session, now. Resume continues
    /// the agent's conversation: with the banner's offer that is `Resume.candidate` (a conversation the agent lost
    /// starts fresh from the original prompt, as the dialog does); without it, a forced resume of the kept id, or of
    /// the latest conversation in the directory when none was kept. Never while an agent runs in the session: that
    /// only says so. Fresh always starts again from the prompt.
    func resumeAgent(_ target: CommandTarget?, fresh: Bool) {
        guard let session = bannerSession(target) else { return flash = "no session to resume" }
        let decision = resumeDecision(fresh ? .fresh : .resume, for: session)
        if let reason = decision.reason { return flash = "\(session.title): \(reason)" }
        guard !isFixture else { return flash = "fixture: no IO" }
        let domain = currentDomain, settings = settings, integration = integration
        switch decision {
        case .nothingToResume:
            flash = "\(session.agent) has no conversation id kept here and no \"latest\" form: "
                + "\(keyText(for: "agent.fresh", asIn: "sessions")) starts it fresh"
        case .forcedResume, .forcedLatest:
            guard let command = ResumePlan.command(
                decision,
                session: session,
                settings: settings,
                integration: integration
            )
            else { return flash = "\(session.title) has no pane to start \(session.agent) in" }
            resumeBannerDismissed.remove(session.id)
            resumeSessions([ResumeCandidate(session: session, mode: .resumeOnly, command: command, paneCount: 1)])
            flash = decision == .forcedLatest
                ? "continuing \(session.agent)'s latest conversation in this directory (heed kept no id)"
                : "resumed \(session.agent)'s kept id; heed did not find the conversation, the agent says if it is gone"
        default:
            Task { @MainActor in
                let candidate = await Task.detached(priority: .userInitiated) {
                    Resume.candidate(for: session, domain: domain, settings: settings, integration: integration) {
                        fresh ? false : Self.agentHasConversation($0, in: domain)
                    }
                }.value
                guard let candidate else { return flash = "\(session.title) has no pane to start \(session.agent) in" }
                resumeBannerDismissed.remove(session.id)
                resumeSessions([candidate])
                if candidate.startsFresh {
                    if !fresh { conversationChecks.set(session.id, exists: false) }
                    flash = fresh ? "\(session.agent) started fresh in \(session.title)"
                        : "\(session.agent) no longer has that conversation: started fresh from the original prompt"
                } else {
                    flash = "resumed \(session.agent)'s conversation in \(session.title)"
                }
            }
        }
    }

    /// `agent.resume.copy`: the line `agent.resume` would run, on the clipboard (`ResumeCopy`). Allowed while the agent
    /// runs, since it only copies text.
    func copyResumeCommand(_ target: CommandTarget?) {
        guard let session = bannerSession(target) else { return flash = "no session to copy a resume command for" }
        let decision = resumeDecision(.copy, for: session)
        if let reason = decision.reason { return flash = "\(session.title): \(reason)" }
        guard let command = ResumePlan.command(decision, session: session, settings: settings, integration: integration)
        else {
            return flash = "\(session.agent) has no conversation id kept here and no \"latest\" form: nothing to copy"
        }
        let directory = layouts[session.id].flatMap { layout in
            agentPane(in: layout)
                .flatMap { _, id in layout.tabs.flatMap(\.tree.panes).first { $0.id == id }?.directory }
        }
        let line = ResumeCopy.line(command: command, directory: directory, shell: PaneShell.login())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.text, forType: .string)
        let left = line.excluded.isEmpty ? "" : " (left off: \(line.excluded.joined(separator: ", ")))"
        flash = "copied: \(line.text)\(left)"
    }

    /// `agent.resume.dismiss`: the banner goes until heed restarts. The keys and menu items still resume.
    func dismissResumeBanner(_ target: CommandTarget?) {
        guard let session = bannerSession(target) else { return }
        resumeBannerDismissed.insert(session.id)
        flash = "\(keyText(for: "agent.resume", asIn: "sessions")) still resumes \(session.agent) in \(session.title)"
    }
}
