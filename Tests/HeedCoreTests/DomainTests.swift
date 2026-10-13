import Foundation
@testable import HeedCore
import Testing

private let repo = Repo(org: "elastic", name: "docs-builder")

struct GitParsingTests {
    @Test func remotes() {
        #expect(Git.parseRemote("git@github.com:elastic/docs-builder.git") == repo)
        #expect(Git.parseRemote("https://github.com/elastic/docs-builder") == repo)
        #expect(Git.parseRemote("https://github.com/elastic/docs-builder.git\n") == repo)
        #expect(Git.parseRemote("ssh://git@github.com/elastic/docs-builder.git") == repo)
        #expect(Git.parseRemote("nonsense") == nil)
    }

    @Test func worktreeList() {
        let porcelain = """
        worktree /code/docs-builder
        HEAD 1234567890abcdef
        branch refs/heads/main

        worktree /code/wt/docs-builder/fix-anchors
        HEAD abcdef1234567890
        branch refs/heads/fix-anchors

        worktree /code/wt/docs-builder/detached
        HEAD 0000000000000000
        detached

        """
        let worktrees = Git.parseWorktrees(porcelain, repo: repo)
        #expect(worktrees.map(\.path) == [
            "/code/docs-builder", "/code/wt/docs-builder/fix-anchors", "/code/wt/docs-builder/detached",
        ])
        #expect(worktrees.map(\.isMain) == [true, false, false])
        #expect(worktrees.map(\.branch) == ["main", "fix-anchors", nil])
        #expect(worktrees[1].head == "abcdef1")
    }

    @Test func status() {
        let porcelain = """
        # branch.oid abc
        # branch.head fix-anchors
        # branch.upstream origin/fix-anchors
        # branch.ab +3 -1
        1 .M N... 100644 100644 100644 abc abc src/a.cs
        2 R. N... 100644 100644 100644 abc abc R100 src/b.cs\tsrc/c.cs
        ? tests/new.cs
        """
        let status = Git.parseStatus(porcelain)
        #expect(status == WorktreeStatus(
            changedFiles: 2, untrackedFiles: 1, ahead: 3, behind: 1, upstream: "origin/fix-anchors"
        ))
        #expect(status.isDirty)
        #expect(status.hasUnpushedWork)
        #expect(!Git.parseStatus("# branch.upstream origin/x\n# branch.ab +0 -0").hasUnpushedWork)
    }
}

struct StartWorkTests {
    @Test func names() {
        #expect(StartWork.name(for: "Fix broken anchors in redirects.yml") == "fix-broken-anchors-redirects")
        #expect(StartWork.name(for: "Bump spec tests to 0.17") == "bump-spec-tests-0-17")
        #expect(StartWork.name(for: "The, a: of!").hasPrefix("work-"))
    }

    @Test func branchNamesGetAPrefixFromTheFirstWord() {
        #expect(StartWork.branchName(for: "Fix broken anchors in redirects.yml") == "fix/broken-anchors-redirects")
        #expect(StartWork.branchName(for: "Bump spec tests to 0.17") == "bump/spec-tests-0-17")
        #expect(StartWork.branchName(for: "Add link validation to assembler") == "feature/link-validation-assembler")
        #expect(StartWork.branchName(for: "Sequence diagram arrowheads") == "feature/sequence-diagram-arrowheads")
        let none = BranchPrefixes(prefixes: ["fix": ["fix"]], defaultPrefix: "")
        #expect(StartWork
            .branchName(for: "Sequence diagram arrowheads", prefixes: none) == "sequence-diagram-arrowheads")
        #expect(WorkSettings(worktreeRoot: "/wt")
            .worktreePath(repo: Repo(org: "o", name: "r"), name: "fix/a-b") == "/wt/r/fix-a-b")
    }

    @Test func guessesNamedReposFirstWithReasons() {
        let records = ["docs-builder", "docs-content", "mermaider"].map {
            RepoRecord(repo: Repo(org: "elastic", name: $0), path: "/code/\($0)")
        }
        let history = [Session(
            title: "x", repos: [records[0].repo], branch: "x", agent: "claude", state: ObservedState(.done)
        )]
        let guesses = StartWork.guessRepos(
            for: "Redirects in docs-content need the matching entries", in: records, history: history
        )
        #expect(guesses.first?.repo.repo.name == "docs-content")
        #expect(guesses.first?.reason.contains("Prompt names docs-content") == true)
        #expect(guesses[1].repo.repo.name == "docs-builder")
        #expect(guesses[1].reason.contains("1 of your last 1 sessions ran here") == true)
        #expect(guesses.last?.confidence == 0)
    }

    @Test func commandsQuoteThePrompt() throws {
        let claude = try #require(AgentProfile.builtIn.first { $0.name == "claude" })
        var plan = StartWorkPlan(prompt: "Fix Bob's anchors", repos: [], name: "x", agent: claude)
        #expect(plan.command == "claude 'Fix Bob'\\''s anchors'")
        plan.planFirst = true
        #expect(plan.command == "claude --permission-mode plan 'Fix Bob'\\''s anchors'")
        plan.autostart = false
        #expect(plan.command == nil)
        #expect(ShellQuote.quote("simple-word") == "simple-word")
    }

    @Test func layoutIsOneAgentPaneUnlessAShellSplitIsAsked() {
        let records = [RepoRecord(repo: repo, path: "/r1"), RepoRecord(repo: Repo(org: "o", name: "two"), path: "/r2")]
        var plan = StartWorkPlan(prompt: "p", repos: records, name: "n", agent: AgentProfile.builtIn[0])
        let session = Session(title: "t", repos: records.map(\.repo), branch: "n", agent: "claude", state: .init(.idle))
        let worktrees = records.map { Worktree(
            repo: $0.repo,
            path: "/wt/\($0.repo.name)/n",
            branch: "n",
            head: "",
            isMain: false
        ) }
        #expect(StartWork.layout(for: plan, session: session, worktrees: worktrees).tabs[0].tree.panes.map(\.role)
            == [.agent])
        plan.shellSplit = true
        let layout = StartWork.layout(for: plan, session: session, worktrees: worktrees)
        #expect(layout.tabs.count == 2)
        let panes = layout.tabs[0].tree.panes
        #expect(panes.map(\.role) == [.agent, .shell])
        #expect(panes[0].command == "claude p")
        #expect(layout.tabs[0].focused == panes[0].id)
        #expect(layout.tabs[1].tree.panes[0].directory == "/wt/two/n")
    }
}

struct DomainChangeTests {
    @Test func worktreeListingKeepsKnownStatus() {
        var domain = Domain()
        let status = WorktreeStatus(changedFiles: 2)
        domain.apply(.worktreesListed(repo: repo, [
            Worktree(repo: repo, path: "/a", branch: "a", head: "", isMain: true, status: status),
        ]))
        domain.apply(.worktreesListed(repo: repo, [
            Worktree(repo: repo, path: "/a", branch: "a", head: "", isMain: true),
            Worktree(repo: repo, path: "/b", branch: "b", head: "", isMain: false),
        ]))
        #expect(domain.worktrees.map(\.path) == ["/a", "/b"])
        #expect(domain.worktrees[0].status == status)
    }

    @Test func removingASessionDropsItsLayout() {
        var domain = Fixtures.main
        #expect(domain.layouts["s1"] != nil)
        domain.apply(.sessionRemoved("s1"))
        #expect(domain.session("s1") == nil)
        #expect(domain.layouts["s1"] == nil)
    }

    @Test func storeRoundTripsThroughItsCacheFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DomainStore(file: file, writeDelay: .zero)
        await store.apply(Fixtures.main.sessions.map { .sessionUpserted($0) })
        await store.flush()
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.sessions == Fixtures.main.sessions)
        #expect(await DomainStore.load(from: file.appendingPathExtension("missing")) == .empty)
    }
}

struct GitIntegrationTests {
    private func makeRepo() async throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("heed-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
            ["commit", "-q", "--allow-empty", "-m", "first"],
        ] {
            _ = try await ProcessRunner.output("git", ["-C", path] + args)
        }
        return path
    }

    @Test func locatesALinkedWorktreeAndItsMainCheckout() async throws {
        let path = try await makeRepo()
        let linked = path + "-linked"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: linked)
        }
        _ = try await ProcessRunner.output("git", ["-C", path, "worktree", "add", "-q", "-b", "side", linked])
        let found = try #require(await Git.locate(linked + "/"))
        #expect(found.worktree.branch == "side")
        #expect(!found.worktree.isMain)
        #expect(URL(fileURLWithPath: found.record.path).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        #expect(found.all.count == 2)
        #expect(await Git.locate(FileManager.default.temporaryDirectory.path) == nil)
    }

    @Test func addsAndListsWorktrees() async throws {
        let path = try await makeRepo()
        let wtRoot = path + "-wt"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: wtRoot)
        }
        let record = try #require(await Git.record(at: path))
        #expect(record.repo.org == "local")
        #expect(record.defaultBranch == "main")
        let added = try await Git.addWorktree(record, path: wtRoot + "/feature", branch: "feature", base: "main")
        #expect(added.branch == "feature")
        let listed = try await Git.worktrees(of: record)
        #expect(listed.count == 2)
        #expect(listed.last?.branch == "feature")
        let status = try await Git.status(at: added.path)
        #expect(!status.isDirty)
    }

    @Test func runnerTimesOut() async {
        await #expect(throws: ProcessError.self) {
            _ = try await ProcessRunner.run("sleep", ["5"], timeout: .milliseconds(100))
        }
    }

    @Test func scannerFindsMainCheckoutsOnly() async throws {
        let path = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let parent = (path as NSString).deletingLastPathComponent
        let found = RepoScanner.candidates(in: parent, depth: 1)
        #expect(found.contains(path))
    }
}

struct StartWorkFormTests {
    private let records = ["docs-builder", "docs-content", "mermaider"].map {
        RepoRecord(repo: Repo(org: "elastic", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func type(_ text: String, into form: inout StartWorkForm) {
        for char in text {
            _ = form.handle(char == " " ? KeyStroke("Space") : KeyStroke(String(char)))
        }
    }

    @Test func typingGuessesReposAndNamesTheWorktree() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        type("Fix anchors in docs-builder and docs-content", into: &form)
        #expect(form.name == "fix/anchors-docs-builder-docs")
        #expect(form.selectedRepos == ["elastic/docs-builder", "elastic/docs-content"])
        #expect(form.plan.command == "claude 'Fix anchors in docs-builder and docs-content'")
    }

    @Test func navigationTogglesAndStarts() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        type("mermaider arrows", into: &form)
        #expect(form.handle(.escape) == .handled)
        #expect(!form.editing)
        #expect(form.handle(KeyStroke("j")) == .handled)
        #expect(form.field == .repo)
        // The cursor is on the first guess (mermaider, selected); move right and add docs-builder.
        _ = form.handle(KeyStroke("l"))
        _ = form.handle(KeyStroke("Space"))
        #expect(form.selectedRepos.count == 2)
        _ = form.handle(KeyStroke("j"))
        _ = form.handle(KeyStroke("j"))
        #expect(form.field == .agent)
        _ = form.handle(KeyStroke("h"))
        #expect(form.agent == nil)
        guard case let .start(plan) = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
        #expect(plan.command == nil)
        #expect(plan.repos.first?.repo.name == "mermaider")
        #expect(form.handle(.escape) == .cancel)
    }

    @Test func cannotStartWithoutARepo() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        type("something unrelated", into: &form)
        #expect(form.selectedRepos.isEmpty)
        #expect(form.handle(KeyStroke("CR", .command)) == .handled)
        #expect(form.error == "pick a repo first")
        _ = form.handle(KeyStroke("n", .control))
        #expect(form.selectedRepos.count == 1)
        #expect(form.canStart)
    }

    @Test func editedNamesStick() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        type("first words", into: &form)
        _ = form.handle(KeyStroke("Tab"))
        _ = form.handle(KeyStroke("Tab"))
        #expect(form.field == .worktree)
        _ = form.handle(KeyStroke("i"))
        _ = form.handle(KeyStroke("u", .control))
        type("My Name", into: &form)
        #expect(form.name == "my-name")
        _ = form.handle(KeyStroke("Tab", .shift))
        _ = form.handle(KeyStroke("Tab", .shift))
        type(" more", into: &form)
        #expect(form.name == "my-name")
    }
}

struct RepoOrderTests {
    private func record(_ slug: String) -> RepoRecord {
        let parts = slug.split(separator: "/").map(String.init)
        return RepoRecord(repo: Repo(org: parts[0], name: parts[1]), path: "/src/\(parts[1])")
    }

    @Test func mostWorktreesFirstThenByName() {
        let repos = ["a/zeta", "b/Alpha", "c/beta", "d/gamma"].map(record)
        let sorted = RepoOrder.sorted(repos, counts: ["d/gamma": 3, "a/zeta": 3, "c/beta": 1])
        #expect(sorted.map(\.id) == ["d/gamma", "a/zeta", "c/beta", "b/Alpha"])
    }

    @Test func guessesFavourReposWithMoreWorktrees() {
        let repos = ["a/one", "a/two", "a/three"].map(record)
        let guesses = StartWork.guessRepos(
            for: "tidy something", in: repos, history: [], worktrees: ["a/three": 6, "a/two": 2]
        )
        #expect(guesses.map(\.repo.id) == ["a/three", "a/two", "a/one"])
        #expect(guesses.first?.reason.contains("6 worktrees already") == true)
        // A repo the prompt names still wins.
        let named = StartWork.guessRepos(for: "fix one", in: repos, history: [], worktrees: ["a/three": 6])
        #expect(named.first?.repo.id == "a/one")
    }
}
