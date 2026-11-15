import Foundation

/// Make it a goal asking the session's agent for a handoff (`SessionHandoff`) before the Plan step opens: where the
/// ask stands, and what the promotion does next. Pure: the app sends the ask, heed's control socket brings the
/// handoff back (`heed goal handoff`), and this decides what each of them means.
///
/// The ask is delivered as every message of heed's is: through the agent's own inbox where it has one, which holds it
/// until the agent can read it, else typed into its pane, and only while the agent is idle or done and you are not
/// typing there (`Delivery.route`). Until it can be, it waits, with why. Whatever happens, the promotion ends: with
/// the handoff, or without it as `GoalPromotion` always was, and a note saying why.
public struct HandoffAsk: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Not sent yet: why ("" for the first moment).
        case waiting(String)
        /// Sent: how it went ("through Claude's inbox"). The agent is writing it.
        case asked(String)
        case received(SessionHandoff)
        /// "Start without it".
        case skipped
        case timedOut
        /// Nobody to ask: why.
        case unavailable(String)
    }

    /// What the promotion goes on with.
    public enum Resolution: Equatable, Sendable {
        case handoff(SessionHandoff)
        /// No handoff: the note to say why (nil when you chose it).
        case without(String?)
    }

    public var session: String
    public var agent: String
    public var startedAt: Date
    /// How long to wait, from the start (`[goals] handoff_timeout`).
    public var timeout: TimeInterval
    public private(set) var phase: Phase
    /// What was wrong with the last handoff the agent sent, while it can still send another.
    public private(set) var problem: String?

    /// The ask for `session` whose agent is `agent`, in `state`. Nil when `timeout` is 0 (asking is off). It is
    /// `unavailable` at once when there is nothing to ask: no agent pane running, the agent exited, or it runs on
    /// another host (its `heed` cannot reach this one).
    public static func begin(
        session: String, agent: String, state: AgentState, hasAgentPane: Bool, host: String?, timeout: TimeInterval,
        now: Date
    ) -> HandoffAsk? {
        guard timeout > 0 else { return nil }
        var ask = HandoffAsk(
            session: session, agent: agent, startedAt: now, timeout: timeout, phase: .waiting(""), problem: nil
        )
        if let host {
            ask.phase = .unavailable("its agent runs on \(host), where heed cannot reach it")
        } else if !hasAgentPane {
            ask.phase = .unavailable("its agent isn't running (no agent pane)")
        } else if state == .exited {
            ask.phase = .unavailable("its agent has exited")
        }
        return ask
    }

    /// The ask is still open: nothing decided how it ends.
    public var isOpen: Bool {
        switch phase {
        case .waiting, .asked: true
        case .received, .skipped, .timedOut, .unavailable: false
        }
    }

    /// Not sent yet, so it is still to be tried.
    public var unsent: Bool {
        if case .waiting = phase { return true }
        return false
    }

    /// How the promotion goes on; nil while the ask is open.
    public var resolution: Resolution? {
        switch phase {
        case .waiting, .asked: nil
        case let .received(handoff): .handoff(handoff)
        case .skipped: .without(nil)
        case .timedOut:
            .without(
                "\(agent) did not hand off within \(PilotDuration.text(timeout))"
                    + (problem.map { " (its last try: \($0))" } ?? "") + ": started without a handoff"
            )
        case let .unavailable(why): .without("\(why): started without a handoff")
        }
    }

    // MARK: Moves

    /// What delivering the ask came to: sent (or held by the agent's inbox) it waits for the handoff, not sent yet it
    /// waits to try again, failed there is nobody to ask.
    public mutating func delivered(_ outcome: DeliveryOutcome) {
        guard isOpen else { return }
        switch outcome {
        case .delivered, .queued, .typed: phase = .asked(outcome.summary)
        case let .waiting(why): if unsent { phase = .waiting(why) }
        case let .failed(why): phase = .unavailable(why)
        }
    }

    /// The agent handed something back (`heed goal handoff`). A handoff heed can read ends the ask; one it cannot is
    /// refused with why, so the agent can try again within the time. Nothing after the ask ended counts.
    @discardableResult
    public mutating func receive(_ text: String) -> Result<SessionHandoff, SessionHandoff.Problem> {
        guard isOpen else { return .failure(.missing("heed is not waiting for a handoff from this session")) }
        switch SessionHandoff.read(text) {
        case let .success(handoff):
            phase = .received(handoff)
            problem = nil
            return .success(handoff)
        case let .failure(why):
            problem = why.description
            return .failure(why)
        }
    }

    /// "Start without it".
    public mutating func skip() {
        if isOpen { phase = .skipped }
    }

    /// Time passes: the wait ends once `timeout` is up.
    public mutating func tick(now: Date) {
        if isOpen, now.timeIntervalSince(startedAt) >= timeout { phase = .timedOut }
    }

    // MARK: Delivery

    /// What to do with the ask for an agent in `state`. Exactly heed's rule for every message: the agent's inbox when
    /// it has one (it holds the message until the agent reads it, so nothing is typed under your fingers); else it is
    /// typed only while the agent is idle or done and you have not typed there for `typingGrace`, and waits otherwise.
    /// Never types into a session that works, is blocked, asks, is limited or has exited.
    public static func route(
        state: AgentState, lastTyped: Date?, inbox: AgentInbox?, settings: ChannelSettings, now: Date,
        typingGrace: TimeInterval = 20
    ) -> DeliveryRoute {
        Delivery.route(
            state: state, lastTyped: lastTyped, inbox: inbox, settings: settings, now: now, typingGrace: typingGrace
        )
    }

    // MARK: Words

    /// The line under the promotion's title while it waits.
    public var headline: String { "Asking \(agent) for a handoff…" }

    /// What is going on, for that line: why it waits, or that the agent is writing.
    public var detail: String {
        switch phase {
        case let .waiting(why): why.isEmpty ? "sending the ask" : "waiting: \(why)"
        case let .asked(how): "asked \(how): it is writing it"
        case .received: "got it"
        case .skipped: "starting without it"
        case .timedOut: "no handoff in time"
        case let .unavailable(why): why
        }
    }
}
