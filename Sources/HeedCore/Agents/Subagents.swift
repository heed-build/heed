import Foundation

/// A subagent the session's agent spawned and has not seen finish (Claude's and Codex's `SubagentStart`).
public struct LiveSubagent: Hashable, Sendable, Identifiable {
    /// The agent's own id for it (`agent_id`).
    public let id: String
    /// Its name (`agent_type`: `Explore`, `general-purpose`, a custom agent), when the hook said.
    public var type: String?
    public let startedAt: Date
    /// Its start or its latest tool event: what staleness is measured from.
    public var lastSeen: Date

    public init(id: String, type: String?, startedAt: Date, lastSeen: Date? = nil) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
        self.lastSeen = lastSeen ?? startedAt
    }
}

/// The subagents running in one session, and what they may do to its state. Kept in memory only: a subagent does not
/// outlive the agent process, and the next launch starts with none.
public struct Subagents: Hashable, Sendable {
    /// In the order they started.
    public private(set) var live: [LiveSubagent] = []
    /// The subagent whose permission prompt (or question) the session's blocked or asking state is: only its own next
    /// step moves the session on from it. Nil when the main thread put it there.
    public private(set) var blockedBy: String?

    /// A subagent not heard from in this long finished without saying so (a missed `SubagentStop`).
    public static let staleAfter: TimeInterval = 2 * 3600

    public init(_ live: [LiveSubagent] = []) {
        self.live = live
    }

    public var count: Int { live.count }
    public var isEmpty: Bool { live.isEmpty }

    /// `SubagentStart`.
    public mutating func start(id: String, type: String?, at date: Date) {
        if let index = live.firstIndex(where: { $0.id == id }) {
            live[index].type = type ?? live[index].type
            live[index].lastSeen = date
        } else {
            live.append(LiveSubagent(id: id, type: type, startedAt: date))
        }
    }

    /// A hook fired inside it: it is alive, even when its start was missed (heed launched after it).
    public mutating func seen(id: String, type: String?, at date: Date) {
        start(id: id, type: type, at: date)
    }

    /// `SubagentStop`.
    public mutating func stop(id: String) {
        live.removeAll { $0.id == id }
        if blockedBy == id { blockedBy = nil }
    }

    /// The agent exited, or its turn ended with nothing left in the background.
    public mutating func clear() {
        live = []
        blockedBy = nil
    }

    /// Forgets subagents not heard from in `staleAfter`.
    public mutating func dropStale(now: Date) {
        live.removeAll { now.timeIntervalSince($0.lastSeen) > Self.staleAfter }
        if let blockedBy, !live.contains(where: { $0.id == blockedBy }) { self.blockedBy = nil }
    }

    /// "2 subagents running": the reason a session keeps working after its main thread stopped.
    public static func running(_ count: Int) -> String {
        "\(count) subagent\(count == 1 ? "" : "s") running"
    }

    /// What a state the main thread reported becomes. Its turn ending (done or idle) while subagents still run (in the
    /// background) leaves the session working; anything it reports takes over from a subagent's prompt.
    public mutating func main(_ state: AgentState, reason: String?) -> (state: AgentState, reason: String?) {
        blockedBy = nil
        if state == .exited { clear() }
        guard !live.isEmpty, state == .done || state == .idle else { return (state, reason) }
        return (.working, Self.running(live.count))
    }

    /// What a state reported from inside subagent `id` does to the session's `current` state; nil when it keeps it.
    /// A permission prompt or a question is real and needs you whoever raised it. A subagent's next step clears only
    /// its own prompt, never the main thread's or another subagent's. Its turn ending is for its parent, not you.
    public mutating func fromSubagent(
        _ state: AgentState, reason: String?, id: String, current: ObservedState
    ) -> ObservedState? {
        switch state {
        case .blocked, .asking:
            blockedBy = id
            return ObservedState(state, reason: reason)
        case .working:
            if current.state == .exited { return nil }
            if current.state.needsYou {
                guard blockedBy == id else { return nil }
                blockedBy = nil
            }
            return ObservedState(.working, reason: reason)
        case .idle, .done, .limited, .exited:
            return nil
        }
    }
}
