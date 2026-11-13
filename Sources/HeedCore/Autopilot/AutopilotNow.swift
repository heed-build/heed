import Foundation

/// A PR as Autopilot's Now sorts it: its state and what the pilot does for it.
public struct AutopilotPull: Hashable, Sendable {
    public var ref: PullRef
    public var status: PilotStatus
    public var merge: MergeMode
    /// Copilot was asked about it and that is not resolved yet.
    public var copilotAsked: Bool

    public init(ref: PullRef, status: PilotStatus, merge: MergeMode, copilotAsked: Bool = false) {
        self.ref = ref
        self.status = status
        self.merge = merge
        self.copilotAsked = copilotAsked
    }
}

/// Now's cards: stalled first (heed stopped and says why), then each capability with the PRs it is working on.
public enum AutopilotNow {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case stalled, green, merge, copilot, unwatched

        public var title: String {
            switch self {
            case .stalled: "Stalled"
            case .green: "Green"
            case .merge: "Merge"
            case .copilot: "Copilot"
            case .unwatched: "Not watched"
            }
        }

        public var capability: Capability? {
            switch self {
            case .green: .green
            case .merge: .merge
            case .copilot: .copilot
            case .stalled, .unwatched: nil
            }
        }
    }

    /// The card a PR is on; nil once it is merged or closed (Done has it then).
    public static func section(of pull: AutopilotPull) -> Section? {
        switch pull.status {
        case .stalled, .stuck: return .stalled
        case .unwatched: return .unwatched
        case .closed: return nil
        default: break
        }
        if pull.copilotAsked { return .copilot }
        switch pull.status {
        case .green, .passing: return pull.merge == .off ? .green : .merge
        case .pending: return pull.merge == .off ? .green : .merge
        default: return .green
        }
    }

    /// The PRs in Now's order: by card, each card's in the order given.
    public static func ordered(_ pulls: [AutopilotPull]) -> [AutopilotPull] {
        let order = Section.allCases
        return pulls.enumerated().compactMap { index, pull in section(of: pull).map { (index, $0, pull) } }
            .sorted { left, right in
                let (a, b) = (order.firstIndex(of: left.1)!, order.firstIndex(of: right.1)!)
                return a != b ? a < b : left.0 < right.0
            }
            .map(\.2)
    }

    /// Now's tab count: what is running or stalled (not what is merely watched or left alone).
    public static func activeCount(_ pulls: [AutopilotPull]) -> Int {
        pulls.count { pull in
            guard let section = section(of: pull) else { return false }
            switch section {
            case .stalled, .copilot: return true
            case .unwatched: return false
            case .green:
                switch pull.status {
                case .feeding, .failing, .changes, .conflicted: return true
                default: return false
                }
            case .merge: return true
            }
        }
    }

    /// Why a stalled PR stopped, in one line.
    public static func why(_ status: PilotStatus) -> String {
        switch status {
        case let .stalled(rounds): "\(rounds) rounds without a new approval: heed stopped sending"
        case let .stuck(reason): "feedback waits: \(reason)"
        default: ""
        }
    }
}
