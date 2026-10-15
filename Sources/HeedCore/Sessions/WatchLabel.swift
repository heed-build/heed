/// What a session row in Watching or Stalled says instead of the agent's line: what heed is doing about its PR, in
/// a few words.
public enum WatchLabel {
    public static func text(
        status: PilotStatus, effective: PullFeedback.Effective, agent: String, agentState: AgentState
    ) -> String? {
        switch status {
        case let .stalled(rounds):
            "stalled · \(rounds) rounds without a new approval"
        case .feeding:
            agentState == .working
                ? "getting it green · \(agent) is fixing it" : "getting it green · waiting for a push"
        case let .failing(count) where effective.green == .auto:
            "getting it green · \(count) check\(count == 1 ? "" : "s") failing"
        case let .changes(count) where effective.green == .auto:
            "getting it green · \(count) thread\(count == 1 ? "" : "s") to address"
        case let .conflicted(what) where effective.green == .auto:
            "getting it green · \(what.hasPrefix("behind") ? "behind its base" : "conflicts")"
        case .pending where effective.merge != .off:
            "getting it merged · waiting for checks"
        case .passing where effective.merge != .off, .green where effective.merge != .off:
            effective.merge == .auto
                ? "getting it merged · auto-merge on"
                : "getting it merged · next run"
        default:
            nil
        }
    }
}
