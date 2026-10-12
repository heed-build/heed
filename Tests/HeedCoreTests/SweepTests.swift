import Foundation
@testable import HeedCore
import Testing

struct SweepTests {
    private let repo = Repo(org: "o", name: "r")
    private let now = Date()

    private func worktree(_ name: String, status: WorktreeStatus? = WorktreeStatus(upstream: "origin/x")) -> Worktree {
        Worktree(repo: repo, path: "/wt/\(name)", branch: name, head: "", isMain: false, status: status)
    }

    private func session(_ branch: String, daysAgo: Double, pinned: Bool = false) -> Session {
        Session(
            id: branch,
            title: branch,
            repos: [repo],
            branch: branch,
            agent: "claude",
            state: .init(.done),
            pinned: pinned,
            lastActivity: now.addingTimeInterval(-daysAgo * 86400)
        )
    }

    @Test func removesIdleSkipsUnsafeAndKeepsPinned() {
        let domain = Domain(
            repos: [RepoRecord(repo: repo, path: "/r")],
            worktrees: [
                Worktree(repo: repo, path: "/r", branch: "main", head: "", isMain: true),
                worktree("old"), worktree("dirty", status: WorktreeStatus(changedFiles: 1, upstream: "origin/x")),
                worktree("local", status: WorktreeStatus()), worktree("pinned"), worktree("fresh"),
            ],
            sessions: [
                session("old", daysAgo: 20),
                session("dirty", daysAgo: 30),
                session("local", daysAgo: 30),
                session("pinned", daysAgo: 90, pinned: true),
                session("fresh", daysAgo: 10),
            ]
        )
        let plan = Sweep.plan(domain: domain, rule: CleanupRule(enabled: true), now: now)
        #expect(plan.removals.map(\.worktree.branch) == ["old"])
        #expect(plan.removals.first?.sessions == ["old"])
        #expect(plan.skips.map(\.reason) == ["uncommitted changes", "never pushed"])
        #expect(plan.next?.worktree.branch == "fresh")
        #expect(plan.next?.days == 4)
        #expect(plan.summary == "The sweep removes 1 worktree, skips 2 with unsaved work.")
    }

    @Test func recentCommitsAndPRsCountAsActivity() {
        let domain = Domain(worktrees: [worktree("old")], sessions: [session("old", daysAgo: 20)])
        let plan = Sweep.plan(
            domain: domain,
            rule: CleanupRule(enabled: true),
            lastCommit: ["/wt/old": now.addingTimeInterval(-86400)],
            now: now
        )
        #expect(plan.removals.isEmpty)
        #expect(Sweep.plan(domain: domain, rule: CleanupRule(enabled: false), now: now).removals
            .isEmpty)
    }

    @Test func offByDefault() {
        let domain = Domain(worktrees: [worktree("old")], sessions: [session("old", daysAgo: 60)])
        #expect(Sweep.plan(domain: domain, rule: CleanupRule(), now: now).removals.isEmpty)
        #expect(Sweep.plan(domain: domain, rule: CleanupRule(enabled: true), now: now).removals.count == 1)
    }

    @Test func unpushedCommitsAreNeverRemoved() {
        #expect(Sweep
            .unsafe(worktree("a", status: WorktreeStatus(ahead: 2, upstream: "origin/a"))) == "2 unpushed commits")
        #expect(Sweep.unsafe(worktree("b", status: nil)) == "status unknown")
        #expect(Sweep.unsafe(worktree("c")) == nil)
    }
}
