import Foundation
import HeedCore

/// Panes heed cannot hear (`Unheard`): restarting one so its agent reports again, and the session key's read, which
/// decides whether panes started now are heard after a restart.
extension AppModel {
    /// `session.reconnect` (gk): restarts the agent of a session heed cannot hear, as resume starts it: after you
    /// confirm, its pane's process ends (its zmx session too, here or on its host) and the agent resumes its
    /// conversation in a new terminal with this run's token; an agent that lost it starts fresh from the prompt.
    func reconnect(_ target: CommandTarget?) {
        let found: Session? = if case let .session(id) = target {
            sessions.first { $0.id == id }
        } else {
            currentSession
        }
        guard let session = found else { return flash = "no session to reconnect" }
        guard let unheard = session.unheard else {
            return flash = "heed hears \(session.title)'s pane: nothing to reconnect"
        }
        guard !isFixture, tutor == nil else { return flash = "fixture: no IO" }
        guard let layout = layouts[session.id], agentPane(in: layout) != nil else {
            return flash = "\(session.title) has no pane to start \(session.agent) in"
        }
        let domain = currentDomain, settings = settings, integration = integration
        Task { @MainActor in
            let candidate = await Task.detached(priority: .userInitiated) {
                Resume.candidate(for: session, domain: domain, settings: settings, integration: integration) {
                    Self.agentHasConversation($0, in: domain)
                }
            }.value
            guard let candidate else { return flash = "\(session.title): heed has no \(session.agent) to restart" }
            let persistent = session.host != nil || TerminalSurfaces.shared.persist == .zmx
            ask(Confirmation(
                title: "Restart \(session.agent) in \(session.title)?",
                lines: [
                    "heed can't hear this pane: \(unheard.reason.text)",
                    persistent ? "Its zmx session ends, and with it \(session.agent) and anything else running there"
                        : "\(session.agent) and anything else running in the pane stop",
                    candidate.startsFresh
                        ? "\(session.agent) no longer has the conversation: it starts again from the original prompt"
                        : "\(session.agent) resumes its conversation in a new terminal heed hears",
                ],
                accept: "Restart"
            ) { [weak self] in
                guard let self else { return }
                resumeSessions([candidate], restarting: true)
                flash = "restarting \(session.agent) in \(session.title)"
            })
        }
    }

    /// The session key as read at launch, once: a key that could not be read or kept goes in the call log, and
    /// Settings says so for the rest of the run.
    func noteSessionKey() {
        guard !isFixture else { return }
        Task { @MainActor in
            let read = await Task.detached(priority: .userInitiated) { PaneTokens.read }.value
            guard let notice = read.notice else { return }
            if let call = read.logged(signing: PaneTokens.signing, at: Clock.now) { CallLog.record(call) }
            sessionKeyNotice = notice
        }
    }
}
