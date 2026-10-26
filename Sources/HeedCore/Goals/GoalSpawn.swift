import Foundation

/// How many sessions and background runs `heed goal item spawn` may have going on a goal (`[goals]
/// spawn_concurrent`, `spawn_per_day`). Each spawn leaves evidence on its item (source `spawn`, its session or run in
/// `ref`), so the count survives a restart and the item shows the work started.
public enum GoalSpawnCap {
    public enum Verdict: Equatable, Sendable {
        case go
        /// `limit` are going already.
        case atOnce(limit: Int)
        /// `limit` started today already.
        case today(limit: Int)

        /// Why it waits, in words; nil when it goes.
        public var reason: String? {
            switch self {
            case .go: nil
            case let .atOnce(limit): "\(limit) spawned on the goal are going already"
            case let .today(limit): "the goal spawned \(limit) today already"
            }
        }
    }

    /// The evidence a spawn leaves.
    public static let source = "spawn"

    /// The spawns started on `goal`: their session or run, and when.
    public static func spawns(_ evidence: [GoalEvidence], goal: String) -> [(ref: String, at: Date)] {
        evidence.filter { $0.goal == goal && $0.source == source && $0.state == .inProgress }
            .compactMap { entry in entry.ref.map { (ref: $0, at: entry.at) } }
    }

    /// Whether one more may start now. `going` says whether a spawned session or run still works (open, not exited
    /// or done; a run not finished).
    public static func verdict(
        goal: String, evidence: [GoalEvidence], going: (String) -> Bool, atOnce: Int, perDay: Int, now: Date,
        calendar: Calendar = .current
    ) -> Verdict {
        let spawns = spawns(evidence, goal: goal)
        if spawns.count(where: { going($0.ref) }) >= atOnce { return .atOnce(limit: atOnce) }
        if spawns.count(where: { calendar.isDate($0.at, inSameDayAs: now) }) >= perDay { return .today(limit: perDay) }
        return .go
    }

    /// The evidence that records a spawn starting.
    public static func started(_ spawn: GoalSpawn, ref: String, title: String, now: Date) -> GoalEvidence {
        GoalEvidence(
            goal: spawn.goal, item: spawn.item, kind: .built, state: .inProgress, at: now, source: source,
            text: "\(spawn.background ? "background run" : "session") \(title), spawned by \(spawn.from)", ref: ref
        )
    }
}

/// A spawned background run: the item's agent headless in its own worktree, on its own branch (kept when it ends, so
/// the work can be opened, pushed or thrown away), told about the goal as a session would be.
public enum GoalSpawnRun {
    /// The words that run `agent` headless on `prompt` in `worktree`; nil for agents that only run in a pane.
    /// Edits are allowed (the worktree is the run's own); claude's shell is limited to `heed goal` and git status, so
    /// a run that needs more stops and says so instead of acting unattended.
    public static func headless(
        agent: String, command: String, prompt: String, worktree: String, instructions: [String]
    ) -> [String]? {
        let command = command.split(separator: " ").map(String.init)
        switch agent {
        case "claude":
            return command + ["-p", prompt, "--permission-mode", "acceptEdits"] + instructions
                + ["--allowedTools", "Bash(heed goal *)", "Bash(git status *)", "Bash(git diff *)"]
        case "codex":
            return command + ["exec", "--sandbox", "workspace-write", "-C", worktree] + instructions + [prompt]
        default:
            return nil
        }
    }

    /// `<root>/heed/<repo>/spawn-<goal>-<item slug>`.
    public static func worktreePath(root: String, repo: Repo, item: GoalItem) -> String {
        "\(root)/heed/\(repo.name)/spawn-\(item.goal)-\(item.slug)"
    }

    /// `heed/spawn/<goal>/<item slug>`.
    public static func branch(item: GoalItem) -> String { "heed/spawn/\(item.goal)/\(item.slug)" }

    /// How long a background run may take before heed stops waiting for it.
    public static let timeout: TimeInterval = 60 * 60
}
