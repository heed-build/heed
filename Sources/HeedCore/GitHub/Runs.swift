import Foundation

/// Get it green and get it merged as background runs: each round of feedback goes to an agent in its own tab, worktree
/// and branch (`heed/get-it-green/<branch>`), and all three are removed as soon as the run ends. What a run is, what to
/// call its branch and worktree, how it ended, and what the sweep may remove.
public enum RunGoal: String, Hashable, Sendable, Codable {
    case green = "get it green"
    case merged = "get it merged"

    /// The goal in branch and path names.
    public var slug: String { self == .green ? "get-it-green" : "get-it-merged" }
}

/// One run, kept in the domain for the inspector's history.
public struct PilotRun: Identifiable, Hashable, Sendable, Codable {
    public enum Outcome: Hashable, Sendable, Codable {
        /// It pushed this many commits to the PR's branch.
        case pushed(Int)
        case noChanges
        case timedOut
        /// You closed its tab.
        case stopped
        /// heed quit while it ran.
        case interrupted
        /// It could not start: why.
        case failed(String)

        public var text: String {
            switch self {
            case let .pushed(count): "pushed \(count) commit\(count == 1 ? "" : "s")"
            case .noChanges: "no changes"
            case .timedOut: "timed out"
            case .stopped: "stopped"
            case .interrupted: "interrupted"
            case let .failed(reason): "failed: \(reason)"
            }
        }
    }

    public let id: String
    public let ref: PullRef
    public let sessionID: String
    public let goal: RunGoal
    public let agent: String
    public let model: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome?
    /// Feedback items it was sent.
    public let items: Int
    /// The PR's branch, the run's own branch and its worktree.
    public let prBranch: String
    public let branch: String
    public let worktree: String
    /// The remote PR branch's commit when it started, to tell what it pushed.
    public let startSHA: String?
    /// The last lines of its screen when it ended.
    public var screen: String?

    public init(
        id: String = UUID().uuidString.lowercased(), ref: PullRef, sessionID: String, goal: RunGoal, agent: String,
        model: String?, startedAt: Date, items: Int, prBranch: String, branch: String, worktree: String,
        startSHA: String?
    ) {
        self.id = id
        self.ref = ref
        self.sessionID = sessionID
        self.goal = goal
        self.agent = agent
        self.model = model
        self.startedAt = startedAt
        self.items = items
        self.prBranch = prBranch
        self.branch = branch
        self.worktree = worktree
        self.startSHA = startSHA
    }

    public var isRunning: Bool { endedAt == nil }

    /// How many the domain keeps, newest first.
    public static let keep = 200
}

public enum Runs {
    /// Every branch a run makes starts with this; scripts can clean up `heed/*`.
    public static let prefix = "heed/"

    public static func branch(_ goal: RunGoal, prBranch: String) -> String { "\(prefix)\(goal.slug)/\(prBranch)" }

    /// `<root>/heed/<repo>/get-it-green-fix-a`.
    public static func worktreePath(root: String, repo: Repo, goal: RunGoal, prBranch: String) -> String {
        "\(root)/heed/\(repo.name)/\(goal.slug)-\(prBranch.replacingOccurrences(of: "/", with: "-"))"
    }

    /// A branch a run made: `heed/get-it-green/...` or `heed/get-it-merged/...`.
    public static func isRunBranch(_ name: String) -> Bool {
        name.hasPrefix(prefix + RunGoal.green.slug + "/") || name.hasPrefix(prefix + RunGoal.merged.slug + "/")
    }

    /// The PR branch a run branch is for.
    public static func prBranch(of runBranch: String) -> String? {
        for goal in [RunGoal.green, .merged] {
            let head = prefix + goal.slug + "/"
            if runBranch.hasPrefix(head) { return String(runBranch.dropFirst(head.count)) }
        }
        return nil
    }

    /// The worktree a run starts beside, and runs git from: the session's in the PR's repo, else the one on the PR's
    /// branch, else one with the repo's name (a fork's clone: its origin is the fork, the PR is upstream), else any
    /// worktree on the PR's branch, else any of the session's.
    public static func baseWorktree(
        for ref: PullRef, headBranch: String?, owned: [Worktree], all: [Worktree]
    ) -> Worktree? {
        owned.first { $0.repo == ref.repo }
            ?? owned.first { headBranch != nil && $0.branch == headBranch }
            ?? owned.first { $0.repo.name == ref.repo.name }
            ?? all.first { headBranch != nil && $0.branch == headBranch && !$0.isMain }
            ?? owned.first
    }

    /// What a PR needs a run for: its checks and reviews, or its conflicts with the base.
    public static func goal(for status: PilotStatus) -> RunGoal? {
        switch status {
        case .failing, .changes, .feeding: .green
        case .conflicted: .merged
        case .stuck, .stalled, .pending, .draft, .green, .passing, .paused, .closed, .unwatched: nil
        }
    }

    /// The tab's title: the goal, and the PR when the session has several.
    public static func title(_ goal: RunGoal, ref: PullRef, pullCount: Int) -> String {
        pullCount > 1 ? "\(goal.rawValue) #\(ref.number)" : goal.rawValue
    }

    /// The run's prompt: where it is and how to push, then what to fix.
    public static func prompt(_ feedback: String, prBranch: String, branch: String) -> String {
        "You are in a worktree of your own on the branch \(branch), which tracks \(prBranch) (the pull request's "
            + "branch). Fix what is listed below, commit, and push to the pull request with: "
            + "git push origin HEAD:\(prBranch)\nThen stop: this worktree is removed when you are done.\n\n" + feedback
    }

    /// A run is done when its agent finishes its turn (after having worked) or exits.
    public static func ended(_ state: AgentState, worked: Bool) -> Bool {
        switch state {
        case .idle, .done: worked
        case .exited: true
        case .working, .blocked, .asking, .limited: false
        }
    }

    public static func timedOut(_ run: PilotRun, timeout: TimeInterval, now: Date) -> Bool {
        run.isRunning && now.timeIntervalSince(run.startedAt) >= timeout
    }

    /// How it ended, from the remote branch before and after (and how many commits lie between).
    public static func outcome(before: String?, after: String?, commits: Int) -> PilotRun.Outcome {
        guard let after, after != before else { return .noChanges }
        return .pushed(max(commits, 1))
    }

    /// Whether the sweep may remove what a run left behind: never one a live run owns, nor work that is not on the
    /// remote yet.
    public static func leftoverVerdict(
        ownedByLiveRun: Bool, dirty: Bool, unpushedCommits: Int
    ) -> (remove: Bool, reason: String) {
        if ownedByLiveRun { return (false, "a run is using it") }
        if dirty { return (false, "it has uncommitted changes") }
        if unpushedCommits > 0 {
            return (
                false,
                "\(unpushedCommits) commit\(unpushedCommits == 1 ? "" : "s") not on the pull request's branch"
            )
        }
        return (true, "left by a run")
    }
}
