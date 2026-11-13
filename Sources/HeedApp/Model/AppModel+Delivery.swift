import Foundation
import HeedCore

/// How heed hands an agent a message: through the agent's own channel when it has one heed may use (Claude's inbox,
/// codex's queue), else typed into its pane when `Delivery.verdict` allows. See docs/agents/messages.md.
extension AppModel {
    /// The channel the agent in `pane` takes messages on, if its hooks said and it is a local pane.
    func inbox(forPane pane: String) -> AgentInbox? { inboxes[pane] }

    /// Learns or forgets a pane's channel from one hook message.
    func noteInbox(_ message: HookMessage, pane: String) {
        switch message.kind {
        case let .inbox(socket):
            inboxes[pane] = .claude(socket: socket)
        case let .agentSession(id, agent) where agent == "codex":
            inboxes[pane] = .codex(thread: id)
        case .state(.exited, _):
            inboxes[pane] = nil
        default:
            break
        }
    }

    /// Hands `text` to the agent in `pane`. `typed`: what is typed when it comes to that, when it must differ (one
    /// line). `typingGrace`: as `Delivery.verdict`'s. Returns where it ended up; `.waiting` means nothing was sent.
    func sendToAgent(
        _ text: String, typed: String? = nil, pane: String, state: AgentState, lastTyped: Date?,
        typingGrace: TimeInterval = 20
    ) async -> DeliveryOutcome {
        let inbox = inbox(forPane: pane)
        switch Delivery.route(
            state: state, lastTyped: lastTyped, inbox: inbox, settings: settings.channels, now: Clock.now,
            typingGrace: typingGrace
        ) {
        case let .wait(reason):
            return .waiting(reason)
        case .type:
            TerminalSurfaces.shared.typeLine(typed ?? text, paneID: pane)
            return .typed(fallback: nil)
        case let .channel(inbox):
            let result = await channels.send(text, to: inbox)
            let resolved = Delivery.resolve(
                result, via: inbox, state: state, lastTyped: lastTyped, now: Clock.now, typingGrace: typingGrace
            )
            if resolved.forget, inboxes[pane] == inbox { inboxes[pane] = nil }
            if resolved.typeNow { TerminalSurfaces.shared.typeLine(typed ?? text, paneID: pane) }
            return resolved.outcome
        }
    }

    /// Tells a session's agent something, from heed itself (a helper fixing its PR, say): through its channel, or
    /// typed when it is idle and you are not typing there. Recorded on the session either way; `.waiting` and
    /// `.failed` mean it was not sent, and nothing retries it.
    @discardableResult
    func notify(session id: String, text: String) async -> DeliveryOutcome {
        guard let session = sessions.first(where: { $0.id == id }) else { return .failed("no session \(id)") }
        guard let layout = layouts[id], let (_, pane) = agentPane(in: layout) else {
            return .failed("\(session.title) has no agent pane")
        }
        let outcome = await sendToAgent(text, pane: pane, state: session.state.state, lastTyped: lastTyped[id])
        if outcome.sent, var told = sessions.first(where: { $0.id == id }) {
            told.record("told \(told.agent): \(text.prefix(80)) · \(outcome.summary)")
            commit(.sessionUpserted(told))
        }
        return outcome
    }

    /// What a session's inbox said after its message was taken as delivered (a held message you denied there, or
    /// that expired): on the session's log, and in the status line.
    func startDeliveryReceipts() {
        let late = channels.lateResults
        Task { [weak self] in
            for await (socket, result) in late {
                self?.lateReceipt(socket: socket, result: result)
            }
        }
    }

    private func lateReceipt(socket: String, result: ChannelResult) {
        guard let pane = inboxes.first(where: { $0.value == .claude(socket: socket) })?.key,
              var session = sessions.first(where: { session in
                  layouts[session.id]?.tabs.contains { $0.tree.panes.contains { $0.id == pane } } == true
              })
        else { return }
        let words = switch result {
        case .accepted: "Claude's inbox delivered heed's held message"
        case let .queued(why): "Claude's inbox: \(why)"
        case let .refused(why), let .unreachable(why): "Claude's inbox did not deliver heed's message: \(why)"
        }
        session.record(words)
        commit(.sessionUpserted(session))
        flash = "\(session.title): \(words)"
    }
}
