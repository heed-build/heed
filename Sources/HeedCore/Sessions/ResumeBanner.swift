import Foundation

/// Which panes have an agent running in them right now, as heed has seen it since it launched. A pane restored from the
/// cache is a plain shell, so a session's saved state (working, done) says nothing about whether its agent runs: only
/// this does. An agent heed started, a hook or the screen reading that says one is there, and a zmx session that kept
/// its agent through a restart put a pane in; the agent exiting, or the pane closing, takes it out.
public struct AgentPresence: Equatable, Sendable {
    /// Off for fixtures, the tutor and shots, whose panes are scripted: there every agent counts as running, so nothing
    /// is offered to resume.
    public var tracking = true
    private var live: Set<String> = []

    public init(tracking: Bool = true) { self.tracking = tracking }

    public func isRunning(_ pane: String) -> Bool { !tracking || live.contains(pane) }

    /// Heed started a command in the pane (a new session, a resume, a hand-off).
    public mutating func started(_ pane: String) { live.insert(pane) }

    /// A pane that reattached to its zmx session: its agent runs on unless it had ended before heed quit.
    public mutating func reattached(_ pane: String, sessionState: AgentState) {
        if sessionState != .exited { live.insert(pane) }
    }

    /// A hook or the screen reading said what the agent in the pane is doing; `.exited` is the agent gone.
    public mutating func observed(_ state: AgentState, in pane: String) {
        if state == .exited { live.remove(pane) } else { live.insert(pane) }
    }

    public mutating func forget(_ pane: String) { live.remove(pane) }
}

/// The banner over a session whose agent is not running but could be picked up again.
public enum ResumeBanner {
    public struct Offer: Equatable, Sendable {
        public let sessionID: String
        public let agent: String
        /// The agent's own session id that `resume` would continue.
        public let conversation: String
    }

    /// A session is offered a resume when all of these hold:
    ///
    /// 1. it is not parked, not on a host (a host's agents are left to zmx there) and has an agent that is not a plain
    ///    shell, whose profile can resume at all;
    /// 2. heed kept the agent's session id, and the agent still has that conversation (`conversationOnDisk`, which is
    ///    true where heed cannot tell; false for a claude session whose transcript is not there, as when the agent
    /// never
    ///    got as far as a first turn);
    /// 3. none of its agent or shell panes (not a task's or a helper's) has an agent running (`AgentPresence`);
    /// 4. it has a pane to start the agent in.
    ///
    /// Dismissing the banner hides the strip, not the offer: the keys and menu items keep working.
    ///
    /// A chat is a session like any other here: one with a conversation to continue is offered, one without is not.
    public static func offer(
        session: Session, layout: SessionLayout?, agent: AgentProfile?, presence: AgentPresence,
        conversationOnDisk: Bool
    ) -> Offer? {
        guard !session.parked, session.host == nil, session.agent != "shell",
              let agent, agent.resumeArguments != nil,
              let conversation = session.agentSessionID, !conversation.isEmpty, conversationOnDisk,
              let panes = layout?.tabs.flatMap(\.tree.panes), !panes.isEmpty
        else { return nil }
        let agentPanes = panes.filter { $0.role == .agent || $0.role == .shell }
        guard !agentPanes.contains(where: { presence.isRunning($0.id) }) else { return nil }
        return Offer(sessionID: session.id, agent: agent.name, conversation: conversation)
    }
}
