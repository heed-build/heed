import Foundation

/// What becomes a macOS notification when sessions start needing you: one per session state change, and a burst
/// (several agents stopping at once) collapsed into one summary. The app notes changes as they happen and drains the
/// batch a few seconds after the first, so a question that is answered or a prompt that clears before then is never
/// shown.
public struct Notices: Equatable, Sendable {
    /// A session that started needing you.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var title: String
        public var agent: String
        public var state: AgentState
        public var reason: String?

        public init(id: String, title: String, agent: String, state: AgentState, reason: String? = nil) {
            self.id = id
            self.title = title
            self.agent = agent
            self.state = state
            self.reason = reason
        }

        /// The notification's text under the title: `Blocked: Bash(rm -rf build)`, `Asking: asked a question`.
        public var body: String {
            let name = state.rawValue.prefix(1).uppercased() + state.rawValue.dropFirst()
            return reason.map { "\(name): \($0)" } ?? name
        }
    }

    public enum Notice: Equatable, Sendable {
        case one(Entry)
        /// Several at once, blocked first: one notification naming them all.
        case summary([Entry])

        public var title: String {
            switch self {
            case let .one(entry): entry.title
            case let .summary(entries): "\(entries.count) sessions need you"
            }
        }

        public var body: String {
            switch self {
            case let .one(entry): entry.body
            case let .summary(entries): entries.map { "\($0.title) · \($0.state.rawValue)" }.joined(separator: "\n")
            }
        }

        /// The session Open brings Heed forward on: the one, or the first (most urgent) of a summary.
        public var session: String? {
            switch self {
            case let .one(entry): entry.id
            case let .summary(entries): entries.first?.id
            }
        }
    }

    /// How long after the first change the batch is drained: long enough to collect a burst, short enough to matter.
    public static let window: TimeInterval = 3

    public private(set) var pending: [Entry] = []
    /// When the first pending change arrived; nil while nothing is pending.
    public private(set) var since: Date?

    public init() {}

    /// A session's state went from `old` to `new`. Entering a wanted Needs you state queues it (replacing what it had
    /// queued); anything else takes it out of the batch, since it no longer needs you.
    public mutating func note(
        id: String, title: String, agent: String, from old: AgentState, to new: ObservedState,
        settings: NotificationSettings, at now: Date
    ) {
        guard old != new.state else { return }
        pending.removeAll { $0.id == id }
        if settings.wants(new.state) {
            pending.append(Entry(id: id, title: title, agent: agent, state: new.state, reason: new.reason))
            if since == nil { since = now }
        }
        if pending.isEmpty { since = nil }
    }

    /// Whether the batch should be drained now.
    public func due(at now: Date) -> Bool {
        since.map { now.timeIntervalSince($0) >= Self.window } ?? false
    }

    /// Empties the batch into what to show, leaving out sessions `onScreen` says you are already looking at.
    public mutating func drain(onScreen: (String) -> Bool = { _ in false }) -> Notice? {
        let entries = pending.filter { !onScreen($0.id) }
        pending = []
        since = nil
        switch entries.count {
        case 0: return nil
        case 1: return .one(entries[0])
        default:
            let ordered = entries.filter { $0.state == .blocked } + entries.filter { $0.state != .blocked }
            return .summary(ordered)
        }
    }
}
