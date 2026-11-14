import Foundation

/// What waits for a swarm worker that runs as a helper (an answer, a message from you or the lead), and how it gets
/// there over ACP. ACP v1 has no way to add to a turn under way: a prompt starts a turn. So mail for a helper at work
/// waits for its turn to end and goes as the next prompt; only your own steering is urgent enough to cancel the turn
/// and go at once, as the helper split's steer box does. An answer its `heed goal ask` is waiting on never comes here:
/// the ask reads it itself.
public enum HelperMail {
    public enum Route: Equatable, Sendable {
        /// It is between turns: a prompt now.
        case promptNow
        /// It is at work: the next prompt, once its turn ends.
        case afterTurn
        /// Yours, and it is at work: its turn is cancelled and this starts the next.
        case steerNow
        /// It cannot take it (starting, gone): why.
        case wait(String)
    }

    /// The route for mail to a helper in `phase`; `urgent`: a message from you.
    public static func route(_ phase: HelperRun.Phase, urgent: Bool, connected: Bool) -> Route {
        guard connected else { return .wait("its agent is gone") }
        switch phase {
        case .starting: return .wait("it is starting")
        case .working, .asking: return urgent ? .steerNow : .afterTurn
        case .paused, .done, .stopped: return .promptNow
        case let .failed(why), let .closed(why): return .wait("it is \(why)")
        }
    }

    /// What the delivery log records for a route.
    public static func outcome(_ route: Route) -> DeliveryOutcome {
        switch route {
        case .promptNow: .delivered(.acp)
        case .steerNow: .delivered(.acp)
        case .afterTurn: .queued(.acp, "the next prompt, after its turn")
        case let .wait(why): .waiting(why)
        }
    }

    /// Mail held for a helper's next turn, as one prompt: each line, then how to carry on.
    public static func prompt(_ lines: [String]) -> String {
        lines.joined(separator: "\n\n")
            + "\n\n(From the swarm, through heed. Carry on with your part, and end as before.)"
    }

    /// A message to the worker is urgent when you sent it.
    public static func urgent(_ row: SwarmSteer) -> Bool { row.kind == .message && row.actor == .you }
}
