import Foundation

/// What a cleanup sweep would do, decided before anything is removed (the Repos banner shows it).
public struct SweepPlan: Equatable, Sendable {
    public struct Removal: Equatable, Sendable {
        public let worktree: Worktree
        public let idleDays: Int
        /// Sessions on this worktree; they move to history as cleaned up.
        public let sessions: [String]
        public let deleteBranch: Bool

        /// "idle 21d", or "no activity recorded" when nothing dated was ever seen there.
        public var idleText: String {
            idleDays > 36500 ? "no activity recorded" : "idle \(idleDays)d"
        }

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

    /// A closed chat's scratch folder, long enough closed to go.
    public struct ChatRemoval: Equatable, Sendable {
        /// The chat's History entry.
        public let id: String
        public let title: String
        public let path: String
        public let closedDays: Int

        public init(id: String, title: String, path: String, closedDays: Int) {
            self.id = id
            self.title = title
            self.path = path
            self.closedDays = closedDays
        }

        /// The folder's name, as the sweep's list shows it.
        public var name: String { (path as NSString).lastPathComponent }
    }

    public var removals: [Removal]
    public var skips: [Skip]
    /// Scratch folders of chats closed `Sweep.chatDays` or more ago.
    public var chatRemovals: [ChatRemoval]
    /// The idle worktree closest to the threshold that is not due yet, and how many days until it is.
    public var next: (worktree: Worktree, days: Int)?

    public init(
        removals: [Removal], skips: [Skip], next: (worktree: Worktree, days: Int)?, chatRemovals: [ChatRemoval] = []
    ) {
        self.removals = removals
        self.skips = skips
        self.next = next
        self.chatRemovals = chatRemovals
    }

    public static func == (lhs: SweepPlan, rhs: SweepPlan) -> Bool {
        lhs.removals == rhs.removals && lhs.skips == rhs.skips && lhs.next?.worktree == rhs.next?.worktree
            && lhs.next?.days == rhs.next?.days && lhs.chatRemovals == rhs.chatRemovals
    }

    /// Whether running it would remove anything.
    public var isEmpty: Bool { removals.isEmpty && chatRemovals.isEmpty }

    public var summary: String {
        if removals.isEmpty, skips.isEmpty, chatRemovals.isEmpty, next == nil { return "Nothing to clean up." }
        if removals.isEmpty, skips.isEmpty, chatRemovals.isEmpty {
            return next
                .map {
                    "Nothing past the threshold. Closest: \($0.worktree.repo.name)/\($0.worktree.branch ?? "") in \($0.days)d."
                }
                ?? "Nothing to clean up."
        }
        var parts: [String] = []
        if !removals.isEmpty { parts.append("removes \(removals.count) worktree\(removals.count == 1 ? "" : "s")") }
        if !chatRemovals.isEmpty {
            parts.append(
                "\(removals.isEmpty ? "removes " : "")\(chatRemovals.count) chat scratch folder"
                    + (chatRemovals.count == 1 ? "" : "s")
            )
        }
        if !skips.isEmpty { parts.append("skips \(skips.count) with unsaved work") }
        return "The sweep " + parts.joined(separator: ", ") + "."
    }
}

public enum Sweep {
    /// A closed chat's scratch folder goes this many days after it closed.
    public static let chatDays = 30

    /// Plans a sweep over every added worktree of every known repo; the same rules apply wherever a worktree lives.
    /// Off unless `rule.enabled`. `lastCommit` gives each worktree's last commit date when known. Closed chats'
    /// scratch folders on this Mac go `chatDays` after they closed, never a pinned one's, never one outside the chats
    /// root, and once only: the entry's timeline then ends with `chatRemovedNote`. No IO: the plan is drawn in Repos.
    public static func plan(
        domain: Domain, rule: CleanupRule, lastCommit: [String: Date] = [:], now: Date = Date(),
        chatsRoot: String = Chats.localRoot
    ) -> SweepPlan {
        guard rule.enabled else { return SweepPlan(removals: [], skips: [], next: nil) }
        var removals: [SweepPlan.Removal] = []
        var skips: [SweepPlan.Skip] = []
        var next: (Worktree, Int)?
        // Worktrees on hosts are not the sweep's: it runs git here, and heed does not clean hosts up (yet).
        for worktree in domain.worktrees where !worktree.isMain && worktree.location.isLocal {
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
        let chats = domain.history.compactMap { entry -> SweepPlan.ChatRemoval? in
            let session = entry.session
            guard let chat = session.chat, chat.kind == .scratch, session.location.isLocal, !session.pinned,
                  Chats.isScratch(chat.path, root: chatsRoot), session.timeline.last?.text != chatRemovedNote
            else { return nil }
            let days = Int(now.timeIntervalSince(entry.closedAt) / 86400)
            guard days >= chatDays else { return nil }
            return SweepPlan.ChatRemoval(id: entry.id, title: session.title, path: chat.path, closedDays: days)
        }
        return SweepPlan(removals: removals, skips: skips, next: next, chatRemovals: chats)
    }

    /// What a closed chat's timeline ends with once the sweep removed its scratch folder.
    public static let chatRemovedNote = "scratch folder removed by the cleanup sweep"

    /// Removes closed chats' scratch folders, each checked again to be one directly under the chats root (one already
    /// gone counts as removed), and notes it on each entry. File IO: call it off the main actor.
    public static func removeChatFolders(
        _ removals: [SweepPlan.ChatRemoval], domain: Domain, chatsRoot: String = Chats.localRoot, now: Date = Date()
    ) -> (changes: [DomainChange], failures: [String]) {
        var changes: [DomainChange] = []
        var failures: [String] = []
        for removal in removals {
            guard Chats.isScratch(removal.path, root: chatsRoot) else {
                failures.append("\(removal.path): not a scratch folder")
                continue
            }
            if FileManager.default.fileExists(atPath: removal.path) {
                do {
                    try FileManager.default.removeItem(atPath: removal.path)
                } catch {
                    failures.append("\(removal.path): \(error.localizedDescription)")
                    continue
                }
            }
            guard var entry = domain.history.first(where: { $0.id == removal.id }) else { continue }
            entry.session.record(chatRemovedNote, at: now)
            changes.append(.historyUpdated(entry))
        }
        return (changes, failures)
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
        var touched: [RepoRecord] = []
        for removal in plan.removals {
            // The repo where the worktree lives: on a host, that host's clone, over ssh. Never this Mac's clone of
            // the same repo, which may have a worktree at the same path.
            let worktree = removal.worktree
            guard let record = domain.repo(StartContext.id(worktree.repo, worktree.location)) else { continue }
            do {
                _ = try await ProcessRunner.output(
                    on: record.location, "git",
                    ["-C", record.path, "worktree", "remove", worktree.path], caller: "cleanup.sweep"
                )
                if removal.deleteBranch, let branch = worktree.branch {
                    // Everything on it is pushed (checked by the plan), so -D only drops the local name.
                    _ = try? await ProcessRunner.output(
                        on: record.location, "git",
                        ["-C", record.path, "branch", "-D", branch],
                        caller: "cleanup.sweep"
                    )
                }
                if !touched.contains(record) { touched.append(record) }
            } catch {
                failures.append("\(worktree.path): \(error)")
            }
        }
        var changes: [DomainChange] = []
        for record in touched {
            if let listed = try? await Git.worktrees(of: record) {
                changes.append(.worktreesListed(repo: record.repo, listed))
            }
        }
        let touchedRepos = touched.map(\.repo)
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
    static func lastCommitDate(at path: String, on location: Location = .local) async -> Date? {
        guard let text = try? await ProcessRunner.output(
            on: location, "git",
            ["-C", path, "log", "-1", "--format=%ct"],
            timeout: .seconds(5), caller: "cleanup.lastCommit"
        ),
            let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
