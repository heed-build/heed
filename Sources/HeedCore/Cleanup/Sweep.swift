import Foundation

/// What a cleanup sweep would do, decided before anything is removed (the Repos banner shows it).
public struct SweepPlan: Equatable, Sendable {
    public struct Removal: Equatable, Sendable {
        public let worktree: Worktree
        public let idleDays: Int
        /// Sessions on this worktree; they move to history as cleaned up.
        public let sessions: [String]
        public let deleteBranch: Bool

        public init(worktree: Worktree, idleDays: Int, sessions: [String], deleteBranch: Bool) {
            self.worktree = worktree
            self.idleDays = idleDays
            self.sessions = sessions
            self.deleteBranch = deleteBranch
        }
    }

    public struct Skip: Equatable, Sendable {
        public let worktree: Worktree
        public let reason: String
    }

    public var removals: [Removal]
    public var skips: [Skip]
    /// The idle worktree closest to the threshold that is not due yet, and how many days until it is.
    public var next: (worktree: Worktree, days: Int)?

    public init(removals: [Removal], skips: [Skip], next: (worktree: Worktree, days: Int)?) {
        self.removals = removals
        self.skips = skips
        self.next = next
    }

    public static func == (lhs: SweepPlan, rhs: SweepPlan) -> Bool {
        lhs.removals == rhs.removals && lhs.skips == rhs.skips && lhs.next?.worktree == rhs.next?.worktree
            && lhs.next?.days == rhs.next?.days
    }

    public var summary: String {
        if removals.isEmpty, skips.isEmpty, next == nil { return "Nothing to clean up." }
        if removals.isEmpty, skips.isEmpty {
            return next
                .map {
                    "Nothing past the threshold. Closest: \($0.worktree.repo.name)/\($0.worktree.branch ?? "") in \($0.days)d."
                }
                ?? "Nothing to clean up."
        }
        var parts: [String] = []
        if !removals.isEmpty { parts.append("removes \(removals.count) worktree\(removals.count == 1 ? "" : "s")") }
        if !skips.isEmpty { parts.append("skips \(skips.count) with unsaved work") }
        return "The sweep " + parts.joined(separator: ", ") + "."
    }
}

public enum Sweep {
    /// Plans a sweep over every added worktree of every known repo; the same rules apply wherever a worktree lives.
    /// Off unless `rule.enabled`. `lastCommit` gives each worktree's last commit date when known.
    public static func plan(
        domain: Domain, rule: CleanupRule, lastCommit: [String: Date] = [:], now: Date = Date()
    ) -> SweepPlan {
        guard rule.enabled else { return SweepPlan(removals: [], skips: [], next: nil) }
        var removals: [SweepPlan.Removal] = []
        var skips: [SweepPlan.Skip] = []
        var next: (Worktree, Int)?
        for worktree in domain.worktrees where !worktree.isMain {
            let sessions = domain.sessions.filter { $0.branch == worktree.branch && $0.repos.contains(worktree.repo) }
            if sessions.contains(where: \.pinned) { continue }
            let activity = lastActivity(of: worktree, sessions: sessions, domain: domain, lastCommit: lastCommit)
            let idle = Int(now.timeIntervalSince(activity) / 86400)
            guard idle >= rule.idleDays else {
                let remaining = rule.idleDays - idle
                if next == nil || remaining < next!.1 { next = (worktree, remaining) }
                continue
            }
            if let reason = unsafe(worktree) {
                skips.append(SweepPlan.Skip(worktree: worktree, reason: reason))
                continue
            }
            removals.append(SweepPlan.Removal(
                worktree: worktree, idleDays: idle, sessions: sessions.map(\.id),
                deleteBranch: rule.deleteBranch && worktree.branch != nil
            ))
        }
        return SweepPlan(removals: removals, skips: skips, next: next)
    }

    /// Why a worktree must not be removed: dirty, unpushed, or status unknown. Nil when it is safe.
    public static func unsafe(_ worktree: Worktree) -> String? {
        guard let status = worktree.status else { return "status unknown" }
        if status.isDirty { return "uncommitted changes" }
        if status
            .hasUnpushedWork { return status.upstream == nil ? "never pushed" : "\(status.ahead) unpushed commits" }
        return nil
    }

    /// The latest of: sessions' activity (agent output, keystrokes, hook events), the last commit, PR updates.
    static func lastActivity(
        of worktree: Worktree, sessions: [Session], domain: Domain, lastCommit: [String: Date]
    ) -> Date {
        var dates = sessions.map(\.lastActivity)
        if let commit = lastCommit[worktree.path] { dates.append(commit) }
        dates += domain.github.pulls.filter { $0.ref.repo == worktree.repo && $0.headBranch == worktree.branch }
            .map(\.updatedAt)
        return dates.max() ?? .distantPast
    }

    /// Removes the planned worktrees (git refuses dirty ones by itself too) and their branches, and returns the
    /// domain changes: worktree lists refreshed, affected sessions closed into history as cleaned up.
    public static func execute(
        _ plan: SweepPlan,
        domain: Domain,
        now: Date = Date()
    ) async -> (changes: [DomainChange], failures: [String]) {
        var failures: [String] = []
        var touchedRepos: [Repo] = []
        for removal in plan.removals {
            guard let record = domain.repo(removal.worktree.repo.slug) else { continue }
            do {
                _ = try await ProcessRunner.output(
                    "git",
                    ["-C", record.path, "worktree", "remove", removal.worktree.path]
                )
                if removal.deleteBranch, let branch = removal.worktree.branch {
                    // Everything on it is pushed (checked by the plan), so -D only drops the local name.
                    _ = try? await ProcessRunner.output("git", ["-C", record.path, "branch", "-D", branch])
                }
                touchedRepos.append(record.repo)
            } catch {
                failures.append("\(removal.worktree.path): \(error)")
            }
        }
        var changes: [DomainChange] = []
        for repo in Set(touchedRepos) {
            if let record = domain.repo(repo.slug), let listed = try? await Git.worktrees(of: record) {
                changes.append(.worktreesListed(repo: repo, listed))
            }
        }
        let removedIDs = Set(plan.removals.filter { removal in
            touchedRepos.contains(removal.worktree.repo)
        }.flatMap(\.sessions))
        for id in removedIDs {
            guard var session = domain.session(id) else { continue }
            session.record(
                "worktree cleaned up after \(plan.removals.first { $0.sessions.contains(id) }?.idleDays ?? 0) idle days",
                at: now
            )
            changes.append(.sessionClosed(HistoryEntry(session: session, closedAt: now, outcome: .cleanedUp)))
        }
        return (changes, failures)
    }
}

public extension Git {
    /// The date of the last commit in a worktree.
    static func lastCommitDate(at path: String) async -> Date? {
        guard let text = try? await ProcessRunner.output(
            "git",
            ["-C", path, "log", "-1", "--format=%ct"],
            timeout: .seconds(5)
        ),
            let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
