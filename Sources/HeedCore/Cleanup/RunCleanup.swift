import Foundation

/// What get it green / get it merged runs left behind (heed quit mid-run, a removal failed): `heed/…` branches and
/// their worktrees. The sweep removes those that are safe, and says why it keeps the others.
public enum RunCleanup {
    public struct Leftover: Equatable, Sendable {
        public let repo: Repo
        public let branch: String
        public let worktree: String?
        public let removed: Bool
        public let reason: String
    }

    /// Finds a repo's leftovers and removes the safe ones: not a live run's (`live`, by branch), no uncommitted
    /// changes, and no commits that are not on the pull request's branch.
    /// `untouchedFor`: also keep worktrees git touched more recently than this (`heed cleanup runs`, which cannot see
    /// which runs are live).
    public static func clean(
        _ record: RepoRecord, live: Set<String>, untouchedFor: TimeInterval? = nil, now: Date = Date()
    ) async -> [Leftover] {
        var result: [Leftover] = []
        for (branch, worktree) in await Git.runBranches(record) {
            if let untouchedFor, let worktree, let touched = await lastTouched(worktree),
               now.timeIntervalSince(touched) < untouchedFor
            {
                result.append(Leftover(
                    repo: record.repo, branch: branch, worktree: worktree, removed: false,
                    reason: "touched in the last \(PilotDuration.text(untouchedFor)): a run may still be working"
                ))
                continue
            }
            var dirty = false
            if let worktree, let status = try? await Git.status(at: worktree, on: record.location) {
                dirty = status.changedFiles > 0 || status.untrackedFiles > 0
            }
            let unpushed = if let pr = Runs.prBranch(of: branch) {
                await Git.commitCount(record, from: "origin/\(pr)", to: branch)
            } else {
                0
            }
            let verdict = Runs.leftoverVerdict(
                // A reviewer never edits: what is in its worktree is only the review it wrote.
                ownedByLiveRun: live.contains(branch), dirty: dirty && !ReviewRun.isReviewBranch(branch),
                unpushedCommits: unpushed
            )
            if verdict.remove {
                if let worktree {
                    await Git.removeWorktree(record, path: worktree, branch: branch)
                } else {
                    _ = try? await ProcessRunner.run(
                        on: record.location, "git", ["-C", record.path, "branch", "-D", branch], timeout: .seconds(10),
                        caller: "cleanup.runs"
                    )
                }
            }
            result.append(Leftover(
                repo: record.repo, branch: branch, worktree: worktree, removed: verdict.remove, reason: verdict.reason
            ))
        }
        return result
    }

    /// When git last changed a worktree's index (its own git dir), on this Mac.
    static func lastTouched(_ worktree: String) async -> Date? {
        guard let dir = try? await ProcessRunner.output(
            "git",
            ["-C", worktree, "rev-parse", "--absolute-git-dir"],
            caller: "cleanup.runs"
        )
        else { return nil }
        let index = dir.trimmingCharacters(in: .whitespacesAndNewlines) + "/index"
        return (try? FileManager.default.attributesOfItem(atPath: index))?[.modificationDate] as? Date
    }
}
