import Foundation

/// Where a Hunch training run stands: none, starting (the model loading), running (how far), or stopping (asked to
/// stop, waiting for the run to notice). A run asked to stop never adopts its head, even when it finishes anyway.
public enum HunchTrainingRun: Equatable, Sendable {
    case idle
    case starting
    case running(Double)
    case stopping

    /// How a run ended, as the record takes it.
    public enum End: Equatable, Sendable {
        /// It finished and was not stopped: its verdict (adopt or keep) goes on the record.
        case finished
        /// It failed: the error goes on the record.
        case failed
        /// It was stopped (or cancelled): the record is left as it was and the new head deleted.
        case stopped
    }

    public var isActive: Bool { self != .idle }

    /// What the pane's bar shows: nil when no run is going, `.some(nil)` while it has no fraction yet.
    public var progress: Double?? {
        switch self {
        case .idle: nil
        case .starting, .stopping: .some(nil)
        case let .running(fraction): .some(fraction)
        }
    }

    /// Starts a run; false while one is going.
    public mutating func start() -> Bool {
        guard self == .idle else { return false }
        self = .starting
        return true
    }

    /// A step done. Ignored once the run is stopping or over (a late report).
    public mutating func progressed(_ fraction: Double) {
        switch self {
        case .starting, .running: self = .running(fraction)
        case .idle, .stopping: break
        }
    }

    /// Asked to stop; false when no run is going (or it is already stopping).
    public mutating func stop() -> Bool {
        switch self {
        case .starting, .running:
            self = .stopping
            return true
        case .idle, .stopping:
            return false
        }
    }

    /// The run returned (`succeeded`, or `cancelled`): how the record takes it. Back to idle.
    public mutating func finish(succeeded: Bool, cancelled: Bool) -> End {
        let stopped = self == .stopping || cancelled
        self = .idle
        if stopped { return .stopped }
        return succeeded ? .finished : .failed
    }
}
