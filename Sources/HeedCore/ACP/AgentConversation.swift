import Foundation

/// A read-only conversation with an agent over ACP, as "define with an agent" holds one (a goal's part, a persona):
/// connecting, ready for a turn, in a turn (its reply gathering), or failed. Each has its own id: what arrives for an
/// earlier one (an event, a reply, a client connected after it was closed) is dropped, and its client closed.
public struct AgentConversation: Identifiable, Sendable {
    public enum Phase: Equatable, Sendable {
        case connecting
        case ready(session: String)
        /// A turn is running: the agent's message so far.
        case turn(session: String, buffer: String)
        case failed(String)
    }

    public let id: UUID
    public private(set) var phase: Phase = .connecting
    /// The client, once made: closed with the conversation, whatever its phase.
    public private(set) var client: ACPClient?
    /// The directory it reads in; paths it read are shown relative to it.
    public let root: String?
    /// What it read, in order.
    public private(set) var paths: [String] = []

    public init(id: UUID = UUID(), root: String?) {
        self.id = id
        self.root = root
    }

    /// The client made for it, before it is started.
    public mutating func attach(_ client: ACPClient) {
        self.client = client
    }

    /// The agent's session is open.
    public mutating func connected(session: String) {
        guard phase == .connecting else { return }
        phase = .ready(session: session)
    }

    /// Starts a turn from `ready`: the client and session to prompt, or nil when there is no session (yet).
    public mutating func beginTurn() -> (client: ACPClient, session: String)? {
        guard case let .ready(session) = phase, let client else { return nil }
        phase = .turn(session: session, buffer: "")
        return (client, session)
    }

    /// A chunk of the agent's message, kept while a turn runs.
    public mutating func received(_ chunk: String) {
        guard case let .turn(session, buffer) = phase else { return }
        phase = .turn(session: session, buffer: buffer + chunk)
    }

    /// The turn ended: its reply, and back to ready. Nil when no turn was running.
    public mutating func endTurn() -> String? {
        guard case let .turn(session, buffer) = phase else { return nil }
        phase = .ready(session: session)
        return buffer
    }

    /// Something it read (a read or search tool call).
    public mutating func read(_ more: [String]) {
        paths += more
    }

    public mutating func failed(_ why: String) {
        phase = .failed(why)
    }

    /// Whether the agent exiting now is a failure to report: it was connecting or answering.
    public var exitInterrupts: Bool {
        switch phase {
        case .connecting, .turn: true
        case .ready, .failed: false
        }
    }
}

public extension AgentConversation {
    /// Closes `current`: the client to close (nil when none was made yet; one made later finds the conversation gone
    /// and closes itself).
    static func close(_ current: inout AgentConversation?) -> ACPClient? {
        let client = current?.client
        current = nil
        return client
    }

    /// Applies `change` when `current` is still the conversation `id`: false when it was closed or replaced.
    @discardableResult
    static func update(
        _ current: inout AgentConversation?, _ id: UUID, _ change: (inout AgentConversation) -> Void
    ) -> Bool {
        guard current?.id == id, var conversation = current else { return false }
        change(&conversation)
        current = conversation
        return true
    }
}
