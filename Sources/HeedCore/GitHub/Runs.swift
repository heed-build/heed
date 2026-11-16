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
    /// Where it is: running, ending (its tab closed, what it pushed still being read), or ended with how it went.
    /// Its end is set once: a late one (a timeout after it ended) changes nothing.
    public private(set) var state: State
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
    /// The model its agent actually ran and what it used, as its hooks report (`model` is the one it was asked for).
    public var usage: AgentUsage?

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
        state = .running
    }

    public enum State: Hashable, Sendable {
        case running
        /// Its tab is closed and heed reads what it pushed: still the PR's run, so the next round waits for it.
        case ending
        case ended(Outcome, at: Date)
    }

    /// Its tab closed and its end is being read. Only from running.
    public mutating func beginEnding() {
        guard state == .running else { return }
        state = .ending
    }

    /// It ended, and how. Only the first end counts.
    public mutating func end(_ outcome: Outcome, at time: Date) {
        guard !isEnded else { return }
        state = .ended(outcome, at: time)
    }

    public var endedAt: Date? {
        if case let .ended(_, at) = state { return at }
        return nil
    }

    public var outcome: Outcome? {
        if case let .ended(outcome, _) = state { return outcome }
        return nil
    }

    public var isEnding: Bool { state == .ending }
    private var isEnded: Bool { endedAt != nil }

    /// Not ended yet: working, or ending.
    public var isRunning: Bool { endedAt == nil }

    /// How many the domain keeps, newest first.
    public static let keep = 200
}

public extension PilotRun {
    private enum CodingKeys: String, CodingKey {
        case id, ref, sessionID, goal, agent, model, startedAt, endedAt, outcome, ending, items, prBranch, branch
        case worktree, startSHA, screen, usage
    }

    /// Stored as it always was (`endedAt` and `outcome` side by side), with `ending` while it ends. An end with no
    /// outcome (never written so) reads as interrupted.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        ref = try values.decode(PullRef.self, forKey: .ref)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        goal = try values.decode(RunGoal.self, forKey: .goal)
        agent = try values.decode(String.self, forKey: .agent)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        items = try values.decode(Int.self, forKey: .items)
        prBranch = try values.decode(String.self, forKey: .prBranch)
        branch = try values.decode(String.self, forKey: .branch)
        worktree = try values.decode(String.self, forKey: .worktree)
        startSHA = try values.decodeIfPresent(String.self, forKey: .startSHA)
        screen = try values.decodeIfPresent(String.self, forKey: .screen)
        usage = try values.decodeIfPresent(AgentUsage.self, forKey: .usage)
        if let endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt) {
            let outcome = try values.decodeIfPresent(Outcome.self, forKey: .outcome)
            state = .ended(outcome ?? .interrupted, at: endedAt)
        } else if try values.decodeIfPresent(Bool.self, forKey: .ending) == true {
            state = .ending
        } else {
            state = .running
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(ref, forKey: .ref)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(goal, forKey: .goal)
        try values.encode(agent, forKey: .agent)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encodeIfPresent(outcome, forKey: .outcome)
        if isEnding { try values.encode(true, forKey: .ending) }
        try values.encode(items, forKey: .items)
        try values.encode(prBranch, forKey: .prBranch)
        try values.encode(branch, forKey: .branch)
        try values.encode(worktree, forKey: .worktree)
        try values.encodeIfPresent(startSHA, forKey: .startSHA)
        try values.encodeIfPresent(screen, forKey: .screen)
        try values.encodeIfPresent(usage, forKey: .usage)
    }
}

public enum Runs {
    /// Every branch a run makes starts with this; scripts can clean up `heed/*`.
    public static let prefix = "heed/"

    public static func branch(_ goal: RunGoal, prBranch: String) -> String { "\(prefix)\(goal.slug)/\(prBranch)" }

    /// The root run worktrees go under: the host's `worktree_root` as written (its `~` is the host's home, expanded
    /// there), else this Mac's, expanded (a raw `~/code/wt` is a folder named `~` under `/`, the read-only system
    /// volume).
    public static func worktreeRoot(local: String, host: String?, hosts: [String: HostConfig]) -> String {
        if let host { return hosts[host]?.worktreeRoot ?? "~/code/wt" }
        return Paths.expand(local)
    }

    /// `<root>/heed/<repo>/get-it-green-fix-a`.
    public static func worktreePath(root: String, repo: Repo, goal: RunGoal, prBranch: String) -> String {
        "\(root)/heed/\(repo.name)/\(goal.slug)-\(prBranch.replacingOccurrences(of: "/", with: "-"))"
    }

    /// A branch a run made: `heed/get-it-green/...`, `heed/get-it-merged/...`, or a goal reviewer's `heed/review/...`.
    public static func isRunBranch(_ name: String) -> Bool {
        name.hasPrefix(prefix + RunGoal.green.slug + "/") || name.hasPrefix(prefix + RunGoal.merged.slug + "/")
            || ReviewRun.isReviewBranch(name)
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

    /// The clone a run runs git from when no worktree is a good base (the PR was opened from elsewhere): the repo's
    /// own, else one with its name (a fork's), on the session's machine first.
    public static func clone(for ref: PullRef, in repos: [RepoRecord], at location: Location) -> RepoRecord? {
        let here = repos.filter { $0.location == location }
        return here.first { $0.repo == ref.repo } ?? here.first { $0.repo.name == ref.repo.name }
            ?? repos.first { $0.repo == ref.repo } ?? repos.first { $0.repo.name == ref.repo.name }
    }

    /// What a PR needs a run for: its checks and reviews, or its conflicts with the base.
    public static func goal(for status: PilotStatus) -> RunGoal? {
        switch status {
        case .failing, .changes, .feeding: .green
        case .conflicted: .merged
        case .stuck, .stalled, .pending, .draft, .green, .passing, .paused, .closed, .unwatched: nil
        }
    }

    /// The last line of a run's screen with a letter or digit on it, trimmed: what the sidebar and the PR card show
    /// of it. Lines of only box drawing or punctuation (an agent's input frame) are skipped.
    public static func lastLine(of screen: String) -> String? {
        screen.split(whereSeparator: \.isNewline).reversed().lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
    }

    /// The tab's title: the goal, and the PR when the session has several.
    public static func title(_ goal: RunGoal, ref: PullRef, pullCount: Int) -> String {
        pullCount > 1 ? "\(goal.rawValue) #\(ref.number)" : goal.rawValue
    }

    /// The run's prompt: where it is and how to push, then what to fix.
    public static func prompt(_ feedback: Prompt, prBranch: String, branch: String) -> Prompt {
        "You are in a worktree of your own on the branch \(name: branch), which tracks \(name: prBranch) (the pull "
            + "request's branch). Fix what is listed below, commit, and push to the pull request with: "
            + "git push origin HEAD:\(name: prBranch)\nThen stop: this worktree is removed when you are done.\n\n"
            + feedback
    }

    /// Whether a run may start on its own (autopilot's auto-feed, not you sending it): on a PR from you or someone
    /// who can write to the repo (`PullAuthorship`), yes; on anyone else's, it waits for you to send it; while heed
    /// does not know yet, it asks first.
    public enum OwnStart: Equatable, Sendable {
        case go, ask, hold
    }

    public static func ownStart(explicit: Bool, trusted: Bool?) -> OwnStart {
        if explicit { return .go }
        switch trusted {
        case true?: return .go
        case false?: return .hold
        case nil: return .ask
        }
    }

    /// The line the PR's log says when a run waits for you.
    public static let heldForAuthor = "from someone outside the repo: runs on it start only when you send them"

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
