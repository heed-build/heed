import Foundation

/// Whether the agent still has a session's conversation on disk, as heed last checked: not checked, being checked
/// (with what the last check found), there, or gone.
public enum ConversationCheck: Equatable, Sendable {
    case unknown
    case checking(generation: Int, last: Bool?)
    case present
    case missing

    /// What the resume offer goes on: there, or there when last checked. Unknown is not there (no offer until a check
    /// says so).
    public var onDisk: Bool {
        switch self {
        case .present, .checking(_, last: true): true
        case .unknown, .missing, .checking: false
        }
    }
}

/// The checks of every session, read off the main actor and reported back in any order: a report from a check
/// started before the latest one for that session is ignored, so an old answer never overwrites a newer one.
public struct ConversationChecks: Equatable, Sendable {
    public private(set) var checks: [String: ConversationCheck] = [:]
    private var generation = 0

    public init() {}

    public subscript(id: String) -> ConversationCheck {
        checks[id] ?? .unknown
    }

    /// Checks of `ids` start: the generation their reports carry.
    public mutating func begin(_ ids: [String]) -> Int {
        generation += 1
        for id in ids {
            let last: Bool? = switch self[id] {
            case .present: true
            case .missing: false
            case let .checking(_, last): last
            case .unknown: nil
            }
            checks[id] = .checking(generation: generation, last: last)
        }
        return generation
    }

    /// A check of `generation` found the conversation there or not. False (and nothing changes) when a newer check of
    /// the session started meanwhile, or it was set or forgotten since.
    @discardableResult
    public mutating func report(_ id: String, exists: Bool, generation: Int) -> Bool {
        guard case let .checking(current, _) = self[id], current == generation else { return false }
        checks[id] = exists ? .present : .missing
        return true
    }

    /// Known without a check (the agent said it lost it; a fixture).
    public mutating func set(_ id: String, exists: Bool) {
        checks[id] = exists ? .present : .missing
    }

    /// The session's agent conversation changed: nothing is known of the new one until it is checked.
    public mutating func forget(_ id: String) {
        checks[id] = nil
    }
}
