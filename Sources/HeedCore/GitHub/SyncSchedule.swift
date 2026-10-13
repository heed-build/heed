import Foundation

/// The parts of a GitHub sync, fetched separately so the one on screen can refresh without the others.
public enum GitHubPart: String, CaseIterable, Hashable, Sendable {
    case inbox, pulls, issues
}

/// What to fetch when: the part the window shows every `poll_seconds` (a minute by default), the rest five times less
/// often, and a PR's detail only when something about it changed. Polling everything every minute costs a dozen gh
/// calls a tick for data nobody is looking at.
public struct SyncSchedule: Hashable, Sendable {
    /// How often the part on screen refreshes; `[github] poll_seconds`.
    public var front: TimeInterval
    /// How often everything else does.
    public var background: TimeInterval { front * 5 }

    public private(set) var fetchedAt: [GitHubPart: Date] = [:]

    public init(pollSeconds: Int = 60) {
        front = TimeInterval(pollSeconds)
    }

    /// The parts due at `now`: those in `front` each poll, the others every fifth, everything when forced.
    public func due(now: Date, front: Set<GitHubPart>, force: Bool = false) -> Set<GitHubPart> {
        if force { return Set(GitHubPart.allCases) }
        return Set(GitHubPart.allCases.filter { part in
            guard let last = fetchedAt[part] else { return true }
            // A little slack, so a part fetched a moment after the last tick is not skipped on this one.
            let interval = (front.contains(part) ? self.front : background) - 5
            return now.timeIntervalSince(last) >= interval
        })
    }

    public mutating func fetched(_ parts: Set<GitHubPart>, at now: Date) {
        for part in parts {
            fetchedAt[part] = now
        }
    }

    /// Whether a watched PR's detail needs fetching: none yet, the summary from the last sync says its checks or
    /// threads moved since, or it is older than the background interval (reviews and comments do not show in the
    /// summary).
    public func needsDetail(pull: PullRequest?, detail: PullDetail?, now: Date) -> Bool {
        guard let detail else { return true }
        if now.timeIntervalSince(detail.fetchedAt) >= background - 5 { return true }
        guard let pull else { return false }
        let checks = pull.checks, known = detail.checks
        return (checks.passed, checks.failed, checks.pending, checks.skipped)
            != (known.passed, known.failed, known.pending, known.skipped)
            || pull.unresolvedThreads != detail.threads.count { !$0.isResolved }
    }
}
