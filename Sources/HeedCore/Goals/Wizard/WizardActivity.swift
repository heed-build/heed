import Foundation

/// What the goal wizard is doing in the background for a goal: nothing, a plan turn (its id), or discarding the goal.
/// Discarding stops the turn, and a turn's reply arriving after that is dropped, so nothing writes to a goal that is
/// being (or was) deleted.
public enum WizardActivity: Equatable, Sendable {
    case idle
    case thinking(UUID)
    case discarding

    /// A plan turn starts: its id, or nil while the goal is being discarded.
    public mutating func think() -> UUID? {
        guard self != .discarding else { return nil }
        let id = UUID()
        self = .thinking(id)
        return id
    }

    /// The turn `id` ended: true when it may apply what it brought (it is still the turn running).
    public mutating func thought(_ id: UUID) -> Bool {
        guard self == .thinking(id) else { return false }
        self = .idle
        return true
    }

    /// Discarding begins: the turn to cancel, if one runs. Nil `allowed` when it is already being discarded.
    public mutating func discard() -> (allowed: Bool, cancel: UUID?) {
        switch self {
        case .discarding: return (false, nil)
        case let .thinking(id):
            self = .discarding
            return (true, id)
        case .idle:
            self = .discarding
            return (true, nil)
        }
    }

    /// The discard failed (or was refused): back to idle, so the wizard can go on.
    public mutating func discardFailed() {
        if self == .discarding { self = .idle }
    }
}
