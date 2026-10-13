import Foundation

/// One hook event, for the inspector's event list.
public struct AgentEvent: Hashable, Sendable {
    public let at: Date
    public let state: AgentState
    public let reason: String?

    public init(at: Date, state: AgentState, reason: String?) {
        self.at = at
        self.state = state
        self.reason = reason
    }

    /// The list, newest first, with `event` added. A turn's working steps are only interesting while it runs: when
    /// anything else arrives (done, blocked, asking…) the working events before it fold away, so what is left is what
    /// happened and what is still going on.
    public static func log(_ log: [AgentEvent], adding event: AgentEvent, limit: Int = 20) -> [AgentEvent] {
        var log = log
        if event.state != .working {
            log = Array(log.drop { $0.state == .working })
        }
        log.insert(event, at: 0)
        return Array(log.prefix(limit))
    }
}
