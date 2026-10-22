import Foundation
@testable import HeedCore
import Testing

/// Removing a worktree saves what exists nowhere else under `refs/heed/archive/`, and reopening brings it back, against
/// real git in a throwaway directory.
struct ArchiveGitTests {
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("heed-archive-\(UUID().uuidString)").path

    private func git(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.output("git", ["-C", path] + args, caller: "test")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A clone of a bare remote with `main` pushed, and a worktree on `spike` (never pushed) holding one commit.
    private func world() async throws -> (record: RepoRecord, worktree: Worktree, commit: String) {
        let remote = base + "/remote.git", clone = base + "/clone", path = base + "/wt/r/spike"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output("git", ["init", "-q", "--bare", "-b", "main", remote], caller: "test")
        _ = try await ProcessRunner.output("git", ["clone", "-q", remote, clone], caller: "test")
        try "one\n".write(toFile: clone + "/a.txt", atomically: true, encoding: .utf8)
        try "gone soon\n".write(toFile: clone + "/b.txt", atomically: true, encoding: .utf8)
        for args in [
            ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["add", "."], ["commit", "-q", "-m", "a"],
            ["push", "-q", "origin", "main"], ["worktree", "add", "-q", "-b", "spike", path],
        ] {
            _ = try await git(clone, args)
        }
        try "two\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await git(path, ["commit", "-q", "-am", "spike work"])
        let record = RepoRecord(repo: Repo(org: "o", name: "r"), path: clone)
        let commit = try await git(path, ["rev-parse", "HEAD"])
        let worktree = Worktree(
            repo: record.repo, path: path, branch: "spike", head: String(commit.prefix(7)), isMain: false,
            status: WorktreeStatus(ahead: 1)
        )
        return (record, worktree, commit)
    }

    private func removal(_ worktree: Worktree, sessions: [String] = []) -> SweepPlan {
        SweepPlan(
            removals: [SweepPlan.Removal(worktree: worktree, idleDays: 0, sessions: sessions, deleteBranch: true)],
            skips: [], next: nil
        )
    }

    private func reopen(_ record: RepoRecord, branch: String) async throws -> (Domain, WorkSettings) {
        var settings = WorkSettings.default
        settings.worktreeRoot = base + "/wt"
        settings.setup = SetupRules(repos: [record.repo.slug: ["make deps"]])
        // No such agent: the session comes back as a shell, so nothing reads an agent's own files.
        let closed = Session(
            id: "s", title: "s", prompt: "do s", repos: [record.repo], branch: branch, agent: "none",
            state: ObservedState(.done)
        )
        let entry = HistoryEntry(session: closed, closedAt: Date(), outcome: .cleanedUp)
        let domain = Domain(repos: [record], history: [entry])
        let changes = try await Reopen.execute(entry, domain: domain, settings: settings, integration: nil)
        return (domain.applying(changes), settings)
    }

    @Test func removingSavesUnpushedCommitsAndReopenBringsThemBack() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (record, worktree, commit) = try await world()

        let result = await Sweep.execute(removal(worktree), domain: Domain(repos: [record], worktrees: [worktree]))
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        // The branch is gone (delete_branch), its commit is not.
        #expect(await (try? git(record.path, ["rev-parse", "--verify", "--quiet", "refs/heads/spike"])) == nil)
        #expect(try await git(record.path, ["rev-parse", "refs/heed/archive/spike^{commit}"]) == commit)
        #expect(result.saved.map(\.unpushed) == [1])
        #expect(result.saved.first?.said == "saved 1 unpushed commit as heed/archive/spike")

        let (restored, _) = try await reopen(record, branch: "spike")
        #expect(try await git(worktree.path, ["rev-parse", "HEAD"]) == commit)
        #expect(try await git(worktree.path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "spike")
        #expect(restored.session("s")?.timeline.contains { $0.text == "worktree recreated from heed/archive/spike" }
            == true)
        // A worktree made again is a fresh checkout: the repo's setup runs in it first.
        let pane = restored.layouts["s"]?.tabs.first?.tree.panes.first
        #expect(pane?.command?.posix.contains("make deps") == true)
    }

    @Test func removingSavesUncommittedWorkAndReopenPutsItBack() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (record, worktree, commit) = try await world()
        // Changed, deleted, staged and untracked: all of it comes back as it was, uncommitted.
        try "three\n".write(toFile: worktree.path + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: worktree.path + "/b.txt")
        try "new\n".write(toFile: worktree.path + "/c.txt", atomically: true, encoding: .utf8)
        try "staged\n".write(toFile: worktree.path + "/d.txt", atomically: true, encoding: .utf8)
        _ = try await git(worktree.path, ["add", "d.txt"])
        var dirty = worktree
        dirty.status = WorktreeStatus(changedFiles: 3, untrackedFiles: 1, ahead: 1)

        let result = await Sweep.execute(removal(dirty), domain: Domain(repos: [record], worktrees: [dirty]))
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(result.saved.first?.wip != nil)
        #expect(result.saved.first?.said
            == "saved 1 unpushed commit and uncommitted changes as heed/archive/spike")
        // The user's own stash is left alone.
        #expect(try await git(record.path, ["stash", "list"]).isEmpty)

        let listed = try #require(await Archive.list(record))
        #expect(listed.map(\.branch) == ["spike"])
        #expect(listed.first?.unpushed == 1 && listed.first?.wip != nil)

        _ = try await reopen(record, branch: "spike")
        #expect(try await git(worktree.path, ["rev-parse", "HEAD"]) == commit)
        #expect(try String(contentsOfFile: worktree.path + "/a.txt", encoding: .utf8) == "three\n")
        #expect(!FileManager.default.fileExists(atPath: worktree.path + "/b.txt"))
        #expect(try String(contentsOfFile: worktree.path + "/c.txt", encoding: .utf8) == "new\n")
        #expect(try String(contentsOfFile: worktree.path + "/d.txt", encoding: .utf8) == "staged\n")
        // Back as changes on top of the commit, not as a commit, and nothing staged: new files are untracked again.
        let status = try await git(worktree.path, ["status", "--porcelain"]).split(separator: "\n").map(String.init)
        #expect(status.sorted() == [" D b.txt", "?? c.txt", "?? d.txt", "M a.txt"].sorted())
        #expect(try await git(worktree.path, ["diff", "--cached", "--name-only"]).isEmpty)
    }

    @Test func pushedWorkIsArchivedTooSoAMergedBranchStillReopens() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (record, worktree, commit) = try await world()
        _ = try await git(worktree.path, ["push", "-q", "-u", "origin", "spike"])
        // The PR merged and GitHub deleted its branch: nothing named spike is left anywhere but the archive.
        _ = try await git(worktree.path, ["push", "-q", "origin", "spike:main"])
        _ = try await git(record.path, ["push", "-q", "origin", "--delete", "spike"])

        let result = await Sweep.execute(removal(worktree), domain: Domain(repos: [record], worktrees: [worktree]))
        #expect(result.failures.isEmpty)
        #expect(result.saved.first?.said == nil)
        _ = try await reopen(record, branch: "spike")
        #expect(try await git(worktree.path, ["rev-parse", "HEAD"]) == commit)
    }

    @Test func aWorktreeThatCannotBeSavedIsNotRemoved() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (record, worktree, _) = try await world()
        var broken = worktree
        broken.path = base + "/wt/r/not-there"
        let result = await Sweep.execute(removal(broken), domain: Domain(repos: [record], worktrees: [broken]))
        #expect(result.failures.count == 1)
        #expect(result.saved.isEmpty)
    }

    @Test func pruningDropsTheRefsAndTheirWork() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (record, worktree, _) = try await world()
        try "three\n".write(toFile: worktree.path + "/a.txt", atomically: true, encoding: .utf8)
        _ = await Sweep.execute(removal(worktree), domain: Domain(repos: [record], worktrees: [worktree]))
        let listed = try #require(await Archive.list(record))
        #expect(listed.count == 1)

        let plan = SweepPlan(removals: [], skips: [], next: nil, expired: listed)
        let result = await Sweep.execute(plan, domain: Domain(repos: [record]))
        #expect(result.failures.isEmpty)
        #expect(await Archive.list(record) == [])
        #expect(await (try? git(record.path, ["rev-parse", "--verify", "--quiet", "refs/heed/archive/spike-wip"]))
            == nil)
        #expect(result.changes.contains(.archivesListed(repo: record.repo, location: .local, [])))
    }
}

struct ArchiveTests {
    private let repo = Repo(org: "o", name: "r")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ref(_ branch: String, daysAgo: Double, location: Location = .local) -> ArchiveRef {
        ArchiveRef(
            repo: repo, location: location, branch: branch, commit: "abc1234",
            archivedAt: now.addingTimeInterval(-daysAgo * 86400)
        )
    }

    @Test func parsesTheListing() {
        let tag = "refs/heed/archive/old-spike\ttag\tabc1234\t1700000000\theed-archive unpushed=3"
        let wip = "refs/heed/archive/old-spike-wip\tcommit\tdef5678\t1700000001\theed-archive wip of old-spike"
        // A branch of the user's that happens to end in -wip is its own archive, not someone's changes.
        let other = "refs/heed/archive/try-wip\ttag\t0123456\t1700000002\theed-archive unpushed=0"
        let refs = Archive.parse([tag, wip, other].joined(separator: "\n"), repo: repo, location: .host("box"))
        #expect(refs.map(\.branch) == ["old-spike", "try-wip"])
        #expect(refs[0].commit == "abc1234" && refs[0].wip == "def5678" && refs[0].unpushed == 3)
        #expect(refs[0].archivedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(refs[0].location == .host("box"))
        #expect(refs[1].wip == nil)
    }

    @Test func namesSayWhatWasSaved() {
        var saved = ref("old-spike", daysAgo: 0)
        #expect(saved.said == nil)
        saved.unpushed = 3
        #expect(saved.said == "saved 3 unpushed commits as heed/archive/old-spike")
        saved.wip = "def"
        saved.unpushed = 0
        #expect(saved.said == "saved uncommitted changes as heed/archive/old-spike")
        #expect(Archive.refName(for: "feature/x") == "refs/heed/archive/feature/x")
    }

    @Test func retentionKeepsRecentOnesAndZeroKeepsAll() {
        let refs = [ref("old", daysAgo: 91), ref("new", daysAgo: 89), ref("far", daysAgo: 200, location: .host("b"))]
        #expect(Archive.expired(refs, keepDays: 90, now: now).map(\.branch) == ["old", "far"])
        #expect(Archive.expired(refs, keepDays: 0, now: now).isEmpty)
    }

    @Test func theSweepListsWhatRetentionDrops() {
        let domain = Domain(archives: [ref("old", daysAgo: 120), ref("new", daysAgo: 3)])
        let plan = Sweep.plan(domain: domain, rule: CleanupRule(enabled: true), now: now)
        #expect(plan.expired.map(\.branch) == ["old"])
        #expect(plan.summary == "The sweep drops 1 saved archive.")
        #expect(Sweep.plan(domain: domain, rule: CleanupRule(enabled: true, keepArchiveDays: 0), now: now)
            .expired.isEmpty)
        #expect(Sweep.plan(domain: domain, rule: CleanupRule(), now: now).expired.isEmpty)
    }

    @Test func archivesAreListedPerRepoAndPlace() {
        var domain = Domain(archives: [ref("a", daysAgo: 1), ref("b", daysAgo: 1, location: .host("box"))])
        domain.apply(.archivesListed(repo: repo, location: .local, [ref("c", daysAgo: 0)]))
        #expect(domain.archives.map(\.branch).sorted() == ["b", "c"])
        domain.apply(.worktreeArchived(ref("c", daysAgo: -1)))
        #expect(domain.archives.count(where: { $0.branch == "c" }) == 1)
    }

    @Test func savingIsLogged() {
        var saved = ref("old-spike", daysAgo: 0)
        saved.unpushed = 2
        let writes = DomainEvents.writes(before: Domain(), changes: [.worktreeArchived(saved)], now: now)
        guard case let .events(events) = writes.first else {
            Issue.record("no event")
            return
        }
        #expect(events.map(\.kind) == [.worktreeArchived])
        #expect(events.first?.subject == "heed/archive/old-spike")
        #expect(events.first?.text == "saved 2 unpushed commits as heed/archive/old-spike")
        #expect(events.first?.payload["unpushed"] == "2")
    }

    @Test func archiveSettingsDecode() {
        let (config, problems) = ConfigLoader.decode("[cleanup]\nkeep_archive_days = 30\n")
        #expect(problems.isEmpty)
        #expect(config?.cleanup.keepArchiveDays == 30)
        #expect(CleanupRule().keepArchiveDays == 90)
    }
}
