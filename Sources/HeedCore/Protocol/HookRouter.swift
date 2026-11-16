import Foundation

/// Where one hook message belongs and what follows from it, decided from the message and the little of the app it
/// needs: which panes are a reviewer's, a swarm worker's or a run's, and the state their runs and sessions are in.
/// The app applies what it says; nothing here does any IO.
public enum HookRouter {
    /// Whose message it is.
    public enum Route: Equatable, Sendable {
        /// Its token is not heed's for that session and pane: not taken (`Unheard`).
        case unheard
        /// The agent a handoff stopped, on its way out: heard, but the session is the new agent's now.
        case retired
        /// A reviewer's pane: its turn over ends the review.
        case review(pane: String)
        /// A swarm worker's pane: its own state and usage.
        case worker(pane: String)
        /// A get it green or merged run's pane: its own state, not the session's.
        case run(pane: String)
        /// The session's own agent.
        case session
    }

    /// The panes heed knows to be someone else's than the session's agent. A pane is in at most one of the three in
    /// practice; when it is in more, a reviewer wins over a worker, and a worker over a run.
    public struct Panes: Equatable, Sendable {
        public var retired: Set<String>
        public var reviews: Set<String>
        public var workers: Set<String>
        public var runs: Set<String>

        public init(
            retired: Set<String> = [], reviews: Set<String> = [], workers: Set<String> = [], runs: Set<String> = []
        ) {
            self.retired = retired
            self.reviews = reviews
            self.workers = workers
            self.runs = runs
        }
    }

    public static func route(verified: Bool, pane: String?, panes: Panes) -> Route {
        guard verified else { return .unheard }
        guard let pane else { return .session }
        if panes.retired.contains(pane) { return .retired }
        if panes.reviews.contains(pane) { return .review(pane: pane) }
        if panes.workers.contains(pane) { return .worker(pane: pane) }
        if panes.runs.contains(pane) { return .run(pane: pane) }
        return .session
    }

    /// The state a reviewer's or run's hook reports: its turn's guess is a finished turn, sitting at its prompt is
    /// idle. Anything else reports none.
    public static func reported(_ kind: HookMessage.Kind) -> AgentState? {
        switch kind {
        case let .state(state, _): state
        case .guess: .done
        case .atPrompt: .idle
        default: nil
        }
    }

    /// What a reviewer's or run's reported state does: the state to show, whether it has worked now, and whether its
    /// turn is over (idle after working, or exited), which ends it.
    public struct Turn: Equatable, Sendable {
        public var state: AgentState
        public var worked: Bool
        public var ended: Bool

        public init(state: AgentState, worked: Bool, ended: Bool) {
            self.state = state
            self.worked = worked
            self.ended = ended
        }
    }

    static func turn(_ state: AgentState, worked: Bool) -> Turn {
        let worked = worked || state == .working
        return Turn(state: state, worked: worked, ended: Runs.ended(state, worked: worked))
    }

    /// What a reviewer's hook does to its review.
    public enum ReviewStep: Equatable, Sendable {
        /// Nothing the review keeps.
        case ignore
        /// Its pane exited non-zero: the reviewer never started.
        case didNotStart
        case turn(Turn)
    }

    public static func review(_ kind: HookMessage.Kind, worked: Bool) -> ReviewStep {
        if case let .taskExit(code) = kind, code != 0 { return .didNotStart }
        return reported(kind).map { .turn(turn($0, worked: worked)) } ?? .ignore
    }

    /// What a run's hook does to its run.
    public enum RunStep: Equatable, Sendable {
        /// Nothing the run keeps.
        case ignore
        /// Its pane exited non-zero: only its setup reports an exit code, so the agent never started.
        case setupFailed
        /// What its agent used, on the run's record (not the session's).
        case usage(AgentUsage)
        case turn(Turn)
    }

    /// `recorded` is the run's record when it has one: usage goes on it, and a report that changes nothing is
    /// ignored. Without a record, usage is nobody's.
    public static func run(_ kind: HookMessage.Kind, worked: Bool, recorded: AgentUsage??) -> RunStep {
        if case let .taskExit(code) = kind, code != 0 { return .setupFailed }
        if case let .usage(report) = kind, let recorded {
            let usage = (recorded ?? AgentUsage()).applying(report)
            return usage == recorded ? .ignore : .usage(usage)
        }
        return reported(kind).map { .turn(turn($0, worked: worked)) } ?? .ignore
    }

    /// Another agent took over the pane (you quit one and started another there): the agent the session follows
    /// now, when it is a different one heed knows.
    public static func takeover(by agent: String?, current: String, known: (String) -> Bool) -> String? {
        guard let agent, agent != current, known(agent) else { return nil }
        return agent
    }

    /// What a state, guess or at-prompt report makes of a session's state.
    public struct SessionTurn: Equatable, Sendable {
        public var state: ObservedState
        /// Idle or done: what waited for its turn to end (feedback, notes) goes now.
        public var settles: Bool { state.state == .idle || state.state == .done }
        /// Idle: a queued continue is typed.
        public var continues: Bool { state.state == .idle }

        public init(state: ObservedState) {
            self.state = state
        }
    }

    /// The session's next state from a report, or nil when it is not news: a report its current state overrides
    /// (an idle prompt over a finished turn, cursor's done after the reply that asked you), or a guess or at-prompt
    /// that changes nothing. A state report that changes nothing (the next tool of a working turn) still is news.
    /// Rate limited, with when it lifts known (`resets`), says so in its reason. Nil for any other kind.
    public static func session(
        _ kind: HookMessage.Kind, current: ObservedState, resets: @autoclosure () -> String?
    ) -> SessionTurn? {
        var next: ObservedState
        switch kind {
        case let .state(state, reason):
            next = current.accepting(ObservedState(state, reason: reason))
            guard next.state == state else { return nil }
        case let .guess(state, reason):
            next = current.guessing(state, reason: reason)
            guard next != current else { return nil }
        case .atPrompt:
            next = current.atPrompt()
            guard next != current else { return nil }
        default:
            return nil
        }
        if case .state(.limited, _) = kind, let resets = resets() {
            next.reason = "\(next.reason ?? "rate limited") · \(resets)"
        }
        return SessionTurn(state: next)
    }
}
