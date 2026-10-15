/// `[pilot] send_to = "tab"`: a dedicated agent in its own tab gets a PR green or merged, and the tab closes once
/// that is done. Which tab a PR needs, and when its tab is done.
public enum HelperGoal: String, Hashable, Sendable {
    case green = "get it green"
    case merged = "get it merged"
}

public enum HelperTabs {
    /// What a PR needs a helper for: its checks and reviews (get it green), or its conflicts with the base (get it
    /// merged). Nil when nothing is wrong, or heed has nothing it could send.
    public static func goal(for status: PilotStatus) -> HelperGoal? {
        switch status {
        case .failing, .changes, .feeding: .green
        case .conflicted: .merged
        case .stuck, .stalled, .pending, .draft, .green, .passing, .paused, .closed, .unwatched: nil
        }
    }

    /// The helper's work is done: get it green once the PR is green (or merged, or closed), get it merged once it is
    /// merged (or closed).
    public static func done(_ goal: HelperGoal, status: PilotStatus) -> Bool {
        switch (goal, status) {
        case (_, .closed): true
        case (.green, .green), (.green, .passing): true
        case (.green, .conflicted): true
        default: false
        }
    }

    /// The tab's title: the goal, and the PR when the session has several.
    public static func title(_ goal: HelperGoal, ref: PullRef, pullCount: Int) -> String {
        pullCount > 1 ? "\(goal.rawValue) #\(ref.number)" : goal.rawValue
    }

    /// Whether the helper may be closed: never mid-turn.
    public static func canClose(_ state: AgentState?) -> Bool {
        switch state {
        case .idle, .done, .exited, nil: true
        case .working, .blocked, .asking, .limited: false
        }
    }
}
