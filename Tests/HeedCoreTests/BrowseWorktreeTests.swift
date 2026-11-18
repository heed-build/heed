import Foundation
@testable import HeedCore
import Testing

/// The temporary worktree: its names, the sweep that takes what a crash left, what a kept run becomes, and the git
/// behind them against a real throwaway repo (a bare remote, a clone, git worktree add and remove).
struct BrowseWorktreeTests {
    private let docs = Repo(org: "acme", name: "docs-toolkit")

    private func item(_ number: Int, _ kind: BrowseItem.Kind = .issue) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, kind: kind,
            title: ExternalText("Anchors lost when a page is moved", source: .issueTitle, author: .unknown)
        )
    }

    // MARK: Names

    @Test func namesAreTheKindTheNumberAndSixHexDigits() {
        #expect(BrowseWorktree.name(.issue, number: 2830, suffix: "4f9c2e") == "issue-2830-4f9c2e")
        #expect(BrowseWorktree.name(.pull, number: 412, suffix: "a01b2c") == "pr-412-a01b2c")
        #expect(BrowseWorktree.branch(named: "issue-2830-4f9c2e") == "heed/browse/issue-2830-4f9c2e")
        #expect(BrowseWorktree
            .path(root: "/wt", repo: docs, name: "pr-1-abcdef") == "/wt/heed/docs-toolkit/pr-1-abcdef")
        #expect(BrowseWorktree.suffix(0x4F9C2E) == "4f9c2e")
        #expect(BrowseWorktree.suffix(0xA) == "00000a")
        #expect(BrowseWorktree.suffix(0xFFFF_FFFF) == "ffffff")
        for _ in 0 ..< 50 {
            let suffix = BrowseWorktree.randomSuffix()
            #expect(suffix.count == 6 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(suffix)")
        }
        #expect(Set((0 ..< 40).map { _ in BrowseWorktree.randomSuffix() }).count > 30, "the suffix is not constant")
    }

    @Test func aNamePlansItsPlaceAndWhatItStartsFrom() {
        let issue = BrowseWorktree.plan(for: item(2830), defaultBranch: "develop", root: "/wt", suffix: "4f9c2e")
        #expect(issue.name == "issue-2830-4f9c2e")
        #expect(issue.branch == "heed/browse/issue-2830-4f9c2e")
        #expect(issue.path == "/wt/heed/docs-toolkit/issue-2830-4f9c2e")
        #expect(issue.start == .defaultBranch("develop"))
        let pull = BrowseWorktree.plan(for: item(412, .pull), defaultBranch: "main", root: "/wt", suffix: "a01b2c")
        #expect(pull.name == "pr-412-a01b2c")
        #expect(pull.start == .pullHead(412))
    }

    @Test func onlyBrowseRunBranchesAreRecognised() throws {
        let ours = ["heed/browse/issue-2830-4f9c2e", "heed/browse/pr-1-000000", "heed/browse/issue-99999-abcdef"]
        for branch in ours {
            #expect(BrowseWorktree.isBranch(branch), "\(branch)")
            #expect(Runs.isRunBranch(branch), "\(branch)")
        }
        let others = [
            "heed/browse/", "heed/browse/issue-x-4f9c2e", "heed/browse/issue-12-4F9C2E", "heed/browse/issue-12-4f9c2",
            "heed/browse/issue-12-4f9c2ee", "heed/browse/task-12-4f9c2e", "heed/browse/issue-0-4f9c2e",
            "heed/browse/issue-12", "heed/browse/my-own-work", "browse/issue-12-4f9c2e", "fix/issue-12-4f9c2e",
            "heed/other/issue-12-4f9c2e", "heed/browse/issue-12-4f9c2e/more", "issue-12-4f9c2e",
        ]
        for branch in others {
            #expect(!BrowseWorktree.isBranch(branch), "\(branch)")
        }
        // The older runs are still runs.
        #expect(Runs.isRunBranch("heed/get-it-green/fix-a"))
        #expect(!Runs.isRunBranch("heed/other/x"))
        let parsed = try #require(BrowseWorktree.parse("heed/browse/pr-412-a01b2c"))
        #expect(parsed.kind == .pull && parsed.number == 412 && parsed.suffix == "a01b2c")
        #expect(BrowseWorktree.parse("issue-7-abcdef")?.kind == .issue)
    }

    // MARK: Sweep

    @Test func theSweepRemovesWhatIsSafeAndKeepsTheRestWithWhy() {
        let found: [BrowseWorktree.Found] = [
            .init(branch: "heed/browse/issue-1-aaaaaa", worktree: "/wt/a", dirty: false, unpushed: 0),
            .init(branch: "heed/browse/issue-2-bbbbbb", worktree: "/wt/b", dirty: true, unpushed: 0),
            .init(branch: "heed/browse/issue-3-cccccc", worktree: "/wt/c", dirty: false, unpushed: 2),
            .init(branch: "heed/browse/issue-4-dddddd", worktree: "/wt/d", dirty: false, unpushed: 0),
            .init(branch: "heed/browse/issue-5-eeeeee", worktree: nil, dirty: false, unpushed: 0),
            .init(branch: "heed/something-else", worktree: "/wt/x", dirty: false, unpushed: 0),
        ]
        let result = BrowseWorktree.sweep(found, live: ["heed/browse/issue-4-dddddd"])
        #expect(
            result.map(\.found.branch) == found.dropLast().map(\.branch),
            "a branch that is not a Browse run's is not its to judge"
        )
        #expect(result.map(\.remove) == [true, false, false, false, true])
        #expect(result[1].reason.contains("uncommitted"))
        #expect(result[2].reason.contains("2 commits"))
        #expect(result[3].reason.contains("a run is using it"))
        #expect(result[0].reason == "left by a Browse run")
    }

    // MARK: Real git

    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("heed-browse-\(UUID().uuidString)").resolvingSymlinksInPath().path

    private func git(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.output("git", ["-C", path] + args, caller: "test")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bare remote with `main` pushed and a pull request's head at `refs/pull/12/head`, and a clone of it.
    private func world() async throws -> RepoRecord {
        let remote = base + "/remote.git", clone = base + "/clone"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output("git", ["init", "-q", "--bare", "-b", "main", remote], caller: "test")
        _ = try await ProcessRunner.output("git", ["clone", "-q", remote, clone], caller: "test")
        try "one\n".write(toFile: clone + "/a.txt", atomically: true, encoding: .utf8)
        for args in [
            ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["add", "."], ["commit", "-q", "-m", "a"],
            ["push", "-q", "origin", "main"], ["checkout", "-q", "-b", "pr-head"],
        ] {
            _ = try await git(clone, args)
        }
        try "two\n".write(toFile: clone + "/b.txt", atomically: true, encoding: .utf8)
        for args in [
            ["add", "."], ["commit", "-q", "-m", "pr work"], ["push", "-q", "origin", "pr-head:refs/pull/12/head"],
            ["checkout", "-q", "main"], ["branch", "-q", "-D", "pr-head"],
        ] {
            _ = try await git(clone, args)
        }
        _ = try await git(clone, ["remote", "set-head", "origin", "main"])
        return RepoRecord(repo: docs, path: clone, defaultBranch: "main")
    }

    /// The same place, whether the system calls it /var or /private/var.
    private func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    private func worktrees(_ record: RepoRecord) async throws -> String {
        try await git(record.path, ["worktree", "list", "--porcelain"])
    }

    private func branches(_ record: RepoRecord) async throws -> [String] {
        try await git(record.path, ["for-each-ref", "--format=%(refname:short)", "refs/heads/"])
            .split(separator: "\n").map(String.init)
    }

    @Test func anIssueRunGetsAWorktreeOnANewBranchFromTheDefaultBranchAndItIsRemovedWithItsBranch() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        let plan = BrowseWorktree.plan(for: item(2830), defaultBranch: "main", root: base + "/wt", suffix: "4f9c2e")
        let path = try await BrowseWorktree.create(plan, in: record)
        #expect(same(path, base + "/wt/heed/docs-toolkit/issue-2830-4f9c2e"))
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
        #expect(try await git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "heed/browse/issue-2830-4f9c2e")
        #expect(try await git(path, ["rev-parse", "HEAD"]) == git(record.path, ["rev-parse", "origin/main"]))
        #expect(try await branches(record).contains("heed/browse/issue-2830-4f9c2e"))

        // The agent leaves work in it, committed and not: closing the run still removes all of it.
        try "x\n".write(toFile: path + "/new.txt", atomically: true, encoding: .utf8)
        await BrowseWorktree.remove(path: path, branch: plan.branch, in: record)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await !worktrees(record).contains("issue-2830"))
        #expect(try await !branches(record).contains(plan.branch))
        #expect(try await branches(record) == ["main"], "nothing else was touched")
    }

    @Test func aPullRequestRunStartsOnTheHeadGitHubHasAndIsRemoved() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        let plan = BrowseWorktree.plan(
            for: item(12, .pull),
            defaultBranch: "main",
            root: base + "/wt",
            suffix: "a01b2c"
        )
        let path = try await BrowseWorktree.create(plan, in: record)
        #expect(FileManager.default.fileExists(atPath: path + "/b.txt"), "the pull request's own file is there")
        #expect(try await git(path, ["rev-parse", "HEAD"]) == git(
            record.path,
            ["rev-parse", "refs/heads/\(plan.branch)"]
        ))
        #expect(try await git(path, ["log", "-1", "--format=%s"]) == "pr work")
        await BrowseWorktree.remove(path: path, branch: plan.branch, in: record)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await branches(record) == ["main"])
    }

    @Test func removingLeavesWhatTheRunPushedOnTheRemote() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        let plan = BrowseWorktree.plan(for: item(7), defaultBranch: "main", root: base + "/wt", suffix: "123abc")
        let path = try await BrowseWorktree.create(plan, in: record)
        try "fix\n".write(toFile: path + "/fix.txt", atomically: true, encoding: .utf8)
        _ = try await git(path, ["add", "."])
        _ = try await git(path, ["commit", "-q", "-m", "fix"])
        _ = try await git(path, ["push", "-q", "origin", "HEAD:fix/anchors"])
        await BrowseWorktree.remove(path: path, branch: plan.branch, in: record)
        let remote = try await ProcessRunner.output(
            "git",
            ["--git-dir", base + "/remote.git", "branch", "--list"],
            caller: "test"
        )
        #expect(remote.contains("fix/anchors"), "the pushed branch is still on the remote")
        #expect(try await branches(record) == ["main"])
    }

    @Test func theUnpushedCountSeesOnlyWorkNoRemoteHas() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        let plan = BrowseWorktree.plan(for: item(8), defaultBranch: "main", root: base + "/wt", suffix: "00aa00")
        let path = try await BrowseWorktree.create(plan, in: record)
        #expect(
            await Git.unpushedSinceCreation(record, branch: plan.branch) == 0,
            "the default branch's own commits are pushed"
        )
        try "1\n".write(toFile: path + "/one.txt", atomically: true, encoding: .utf8)
        _ = try await git(path, ["add", "."])
        _ = try await git(path, ["commit", "-q", "-m", "one"])
        #expect(await Git.unpushedSinceCreation(record, branch: plan.branch) == 1)
        _ = try await git(path, ["push", "-q", "origin", "HEAD:fix/one"])
        #expect(await Git.unpushedSinceCreation(record, branch: plan.branch) == 0)
        // A pull request's own commits are not the run's to lose, whoever has them.
        let pull = BrowseWorktree.plan(
            for: item(12, .pull),
            defaultBranch: "main",
            root: base + "/wt",
            suffix: "00bb00"
        )
        _ = try await BrowseWorktree.create(pull, in: record)
        #expect(await Git.unpushedSinceCreation(record, branch: pull.branch) == 0)
    }

    @Test func theStartupSweepRemovesLeftoversNobodyUsesAndKeepsTheRest() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        func make(_ number: Int, _ suffix: String) async throws -> BrowseWorktree.Plan {
            let plan = BrowseWorktree.plan(for: item(number), defaultBranch: "main", root: base + "/wt", suffix: suffix)
            _ = try await BrowseWorktree.create(plan, in: record)
            return plan
        }
        let clean = try await make(1, "aaaaaa")
        let dirty = try await make(2, "bbbbbb")
        let committed = try await make(3, "cccccc")
        let pushed = try await make(4, "dddddd")
        let live = try await make(5, "eeeeee")
        let pull = BrowseWorktree.plan(
            for: item(12, .pull),
            defaultBranch: "main",
            root: base + "/wt",
            suffix: "ffffff"
        )
        _ = try await BrowseWorktree.create(pull, in: record)
        try "x\n".write(toFile: dirty.path + "/x.txt", atomically: true, encoding: .utf8)
        _ = try await git(dirty.path, ["add", "."])
        // Different work in each, so no commit of one is on the remote because of the other.
        for plan in [committed, pushed] {
            try "\(plan.name)\n".write(toFile: plan.path + "/c.txt", atomically: true, encoding: .utf8)
            _ = try await git(plan.path, ["add", "."])
            _ = try await git(plan.path, ["commit", "-q", "-m", "work in \(plan.name)"])
        }
        _ = try await git(pushed.path, ["push", "-q", "origin", "HEAD:fix/pushed"])
        // Not a Browse run's: heed/ branches of other kinds, and a person's own worktree.
        _ = try await git(record.path, ["branch", "heed/other/keep", "main"])
        _ = try await git(record.path, ["branch", "fix/mine", "main"])

        let result = await RunCleanup.clean(record, live: [live.branch])
        let removed = Set(result.filter(\.removed).map(\.branch))
        let kept = Dictionary(uniqueKeysWithValues: result.filter { !$0.removed }.map { ($0.branch, $0.reason) })
        #expect(removed == [clean.branch, pushed.branch, pull.branch])
        #expect(kept[dirty.branch]?.contains("uncommitted") == true)
        #expect(kept[committed.branch]?.contains("1 commit") == true)
        #expect(kept[live.branch] == "a run is using it")
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(!FileManager.default.fileExists(atPath: pushed.path))
        #expect(!FileManager.default.fileExists(atPath: pull.path))
        #expect(FileManager.default.fileExists(atPath: dirty.path))
        #expect(FileManager.default.fileExists(atPath: committed.path))
        let left = try await Set(branches(record))
        #expect(left.contains("heed/other/keep") && left.contains("fix/mine") && left.contains("main"))
        #expect(!left.contains(clean.branch) && !left.contains(pushed.branch) && !left.contains(pull.branch))
        #expect(left.contains(dirty.branch) && left.contains(committed.branch) && left.contains(live.branch))
    }

    // MARK: Keeping a run as a session

    @Test func aKeptRunTakesHeedsUsualBranchNameAndStaysUnique() {
        #expect(BrowseWorktree
            .promoted(verb: .fix, title: "Anchors lost when a page is moved", taken: []) ==
            "fix/anchors-lost-page-moved")
        #expect(BrowseWorktree.promoted(
            verb: .fix,
            title: "Anchors lost when a page is moved",
            taken: ["fix/anchors-lost-page-moved"]
        ) == "fix/anchors-lost-page-moved-2")
        let add = BrowseWorktree.promoted(verb: .implement, title: "Support nested includes in snippets", taken: [])
        #expect(add.hasSuffix("support-nested-includes-snippets") && !add.contains("heed/browse"))
        #expect(!BrowseWorktree.promoted(verb: .chat, title: "Backpressure drops events", taken: []).hasPrefix("heed/"))
        #expect(!BrowseWorktree.promoted(verb: .review, title: "Bump spec tests to 0.17", taken: []).hasPrefix("heed/"))
        // The title's own fences and links never reach a branch name.
        let odd = BrowseWorktree.promoted(verb: .fix, title: "Crash on https://x.example/a?b=1 \u{1B}[31m", taken: [])
        #expect(!odd.contains("http") && !odd.contains("\u{1B}") && !odd.contains(" "))
    }

    @Test func keepingMovesTheWorktreeAndRenamesTheBranchWithoutLosingWork() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let record = try await world()
        let plan = BrowseWorktree.plan(for: item(2830), defaultBranch: "main", root: base + "/wt", suffix: "4f9c2e")
        let path = try await BrowseWorktree.create(plan, in: record)
        try "work\n".write(toFile: path + "/work.txt", atomically: true, encoding: .utf8)
        _ = try await git(path, ["add", "."])
        _ = try await git(path, ["commit", "-q", "-m", "work"])
        try "dirty\n".write(toFile: path + "/dirty.txt", atomically: true, encoding: .utf8)
        let head = try await git(path, ["rev-parse", "HEAD"])

        let branch = try await BrowseWorktree.promoted(
            verb: .fix,
            title: "Anchors lost when a page is moved",
            taken: Set(branches(record))
        )
        let newPath = base + "/wt/docs-toolkit/" + branch.replacingOccurrences(of: "/", with: "-")
        _ = try await BrowseWorktree.promote(record, from: path, branch: plan.branch, to: branch, at: newPath)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: newPath + "/work.txt"))
        #expect(FileManager.default.fileExists(atPath: newPath + "/dirty.txt"), "uncommitted work moves too")
        #expect(try await git(newPath, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch)
        #expect(try await git(newPath, ["rev-parse", "HEAD"]) == head)
        let left = try await branches(record)
        #expect(left.contains(branch) && !left.contains(plan.branch))
        #expect(!BrowseWorktree.isBranch(branch), "the sweep no longer thinks it is a leftover")
        let result = await RunCleanup.clean(record, live: [])
        #expect(result.isEmpty, "a kept run is not swept: \(result)")
        #expect(FileManager.default.fileExists(atPath: newPath))
        let listed = try await Git.worktrees(of: record)
        #expect(listed.contains { same($0.path, newPath) && $0.branch == branch })
    }
}
