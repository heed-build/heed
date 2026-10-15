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

    /// Where a helper's companion checkout goes: beside the session's worktree, named after it and the goal.
    public static func companionPath(worktree: String, goal: HelperGoal) -> String {
        "\(worktree)-\(goal == .green ? "green" : "merged")"
    }

    /// The companion's own branch: the PR's, with the goal as a suffix.
    public static func companionBranch(_ branch: String, goal: HelperGoal) -> String {
        "\(branch)-\(goal == .green ? "green" : "merged")"
    }

    /// The helper's prompt in its companion: where it is and how to push, then what to fix.
    public static func companionPrompt(_ feedback: String, branch: String, goal: HelperGoal) -> String {
        "You are in a separate worktree on the branch \(companionBranch(branch, goal: goal)), which tracks \(branch) "
            + "and leaves the main worktree alone. Commit here and push to the PR's branch with: "
            + "git push origin HEAD:\(branch)\n\n" + feedback
    }

    /// `send_to = "tab"`: a PR that already has a helper keeps it; otherwise one in a companion while you work in the
    /// session, and the session's own agent once you have stepped away.
    public enum Route: Equatable, Sendable {
        case existingHelper, companionHelper, sessionAgent
    }

    public static func route(hasHelper: Bool, youAreThere: Bool) -> Route {
        if hasHelper { return .existingHelper }
        return youAreThere ? .companionHelper : .sessionAgent
    }

    /// Whether the helper may be closed: never mid-turn.
    public static func canClose(_ state: AgentState?) -> Bool {
        switch state {
        case .idle, .done, .exited, nil: true
        case .working, .blocked, .asking, .limited: false
        }
    }
}
