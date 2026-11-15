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
            presence: agentPresence, conversationOnDisk: conversationOnDisk[session.id] ?? false
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

    /// What a hook said about a pane's agent: it is there, or it is gone.
    func noteAgent(_ kind: HookMessage.Kind, pane: String?, session: Session) {
        guard let pane else { return }
        switch kind {
        case let .state(state, _), let .guess(state, _):
            agentPresence.observed(state, in: pane)
            if state == .exited { checkConversations(of: [session.id]) }
        case .atPrompt:
            agentPresence.observed(.idle, in: pane)
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
        Task.detached(priority: .utility) {
            let found = targets.map { ($0.id, Self.agentHasConversation($0, in: domain) != false) }
            await MainActor.run { [found] in
                for (id, exists) in found {
                    self.conversationOnDisk[id] = exists
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

    /// `agent.resume` and `agent.fresh`: the same code as the launch dialog's, for one session, now. Resume continues
    /// the agent's conversation; if the agent has lost it, this says so and starts fresh from the original prompt, as
    /// the dialog does. Fresh always starts again from the prompt.
    func resumeAgent(_ target: CommandTarget?, fresh: Bool) {
        guard let session = bannerSession(target) else { return flash = "no session to resume" }
        guard resumeOffer(for: session) != nil else {
            return flash = "\(session.title): its agent is running, or has no conversation to resume"
        }
        guard !isFixture else { return flash = "fixture: no IO" }
        let domain = currentDomain, settings = settings, integration = integration
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
                if !fresh { conversationOnDisk[session.id] = false }
                flash = fresh ? "\(session.agent) started fresh in \(session.title)"
                    : "\(session.agent) no longer has that conversation: started fresh from the original prompt"
            } else {
                flash = "resumed \(session.agent)'s conversation in \(session.title)"
            }
        }
    }

    /// `agent.resume.dismiss`: the banner goes until heed restarts. The keys and menu items still resume.
    func dismissResumeBanner(_ target: CommandTarget?) {
        guard let session = bannerSession(target) else { return }
        resumeBannerDismissed.insert(session.id)
        flash = "\(keyText(for: "agent.resume", asIn: "sessions")) still resumes \(session.agent) in \(session.title)"
    }
}
