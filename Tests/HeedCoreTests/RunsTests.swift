import Foundation
@testable import HeedCore
import Testing

/// Get it green / get it merged runs: their names, how they end, what the sweep may remove, and the settings.
struct RunsTests {
    private let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 12)

    @Test func namesAreScriptable() {
        #expect(Runs.branch(.green, prBranch: "fix/a") == "heed/get-it-green/fix/a")
        #expect(Runs.branch(.merged, prBranch: "fix-a") == "heed/get-it-merged/fix-a")
        #expect(Runs.worktreePath(root: "/wt", repo: ref.repo, goal: .green, prBranch: "fix/a")
            == "/wt/heed/r/get-it-green-fix-a")
        #expect(Runs.isRunBranch("heed/get-it-green/fix-a") && Runs.isRunBranch("heed/get-it-merged/x"))
        #expect(!Runs.isRunBranch("heed/other/x") && !Runs.isRunBranch("fix-a"))
        #expect(Runs.prBranch(of: "heed/get-it-green/fix/a") == "fix/a")
        #expect(Runs.title(.green, ref: ref, pullCount: 1) == "get it green")
        #expect(Runs.title(.merged, ref: ref, pullCount: 2) == "get it merged #12")
        let prompt = Runs.prompt("Fix lint", prBranch: "fix-a", branch: "heed/get-it-green/fix-a")
        #expect(prompt.contains("git push origin HEAD:fix-a") && prompt.hasSuffix("Fix lint"))
    }

    @Test func aRunsRootIsExpandedHereAndLeftForTheHost() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Runs.worktreeRoot(local: "~/code/wt", host: nil, hosts: [:]) == home + "/code/wt")
        #expect(Runs.worktreeRoot(local: "/wt", host: nil, hosts: [:]) == "/wt")
        let hosts = ["devbox": HostConfig(name: "devbox", worktreeRoot: "~/src/wt")]
        #expect(Runs.worktreeRoot(local: "~/code/wt", host: "devbox", hosts: hosts) == "~/src/wt")
        #expect(Runs.worktreeRoot(local: "~/code/wt", host: "gpu", hosts: hosts) == "~/code/wt")
    }

    @Test func goalsEndingsAndOutcomes() {
        #expect(Runs.goal(for: .failing(1)) == .green && Runs.goal(for: .conflicted("x")) == .merged)
        #expect(Runs.goal(for: .green) == nil)
        // Idle before it worked is the agent starting up, not the end.
        #expect(!Runs.ended(.idle, worked: false) && Runs.ended(.idle, worked: true) && Runs.ended(
            .exited,
            worked: false
        ))
        #expect(!Runs.ended(.working, worked: true) && !Runs.ended(.asking, worked: true))
        #expect(Runs.outcome(before: "a", after: "b", commits: 2) == .pushed(2))
        #expect(Runs.outcome(before: "a", after: "a", commits: 0) == .noChanges)
        #expect(Runs.outcome(before: "a", after: nil, commits: 0) == .noChanges)
        #expect(PilotRun.Outcome.pushed(1).text == "pushed 1 commit")
        let started = Date(timeIntervalSince1970: 0)
        let run = PilotRun(
            ref: ref, sessionID: "s", goal: .green, agent: "codex", model: nil, startedAt: started, items: 1,
            prBranch: "b", branch: "heed/get-it-green/b", worktree: "/wt", startSHA: nil
        )
        #expect(!Runs.timedOut(run, timeout: 1800, now: started.addingTimeInterval(60)))
        #expect(Runs.timedOut(run, timeout: 1800, now: started.addingTimeInterval(1800)))
    }

    @Test func theSweepRemovesOnlyWhatIsSafe() {
        #expect(Runs.leftoverVerdict(ownedByLiveRun: true, dirty: false, unpushedCommits: 0).remove == false)
        #expect(Runs.leftoverVerdict(ownedByLiveRun: false, dirty: true, unpushedCommits: 0).remove == false)
        #expect(Runs.leftoverVerdict(ownedByLiveRun: false, dirty: false, unpushedCommits: 2)
            == (false, "2 commits not on the pull request's branch"))
        #expect(Runs.leftoverVerdict(ownedByLiveRun: false, dirty: false, unpushedCommits: 0).remove)
    }

    @Test func settingsAgentModelAndRemovedKeys() {
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        agent = "Codex"
        model = "gpt-5-codex"
        run_timeout = "45m"
        send_to = "tab"
        [repos."o/r"]
        model = "haiku"
        agent = "claude"
        """)
        #expect(problems.map(\.path) == ["pilot.send_to"])
        let pilot = config?.pilot ?? PilotRules()
        #expect(pilot.defaults.agent == "codex" && pilot.defaults.model == "gpt-5-codex")
        #expect(pilot.defaults.runTimeout == 2700)
        let repo = pilot.resolve(ref.repo)
        #expect(repo.agent == "claude" && repo.model == "haiku")
        #expect(HeedConfig.default.pilot.defaults.agent == nil && HeedConfig.default.pilot.defaults.runTimeout == 1800)
    }

    @Test func everyBuiltInAgentTakesAModel() throws {
        for agent in AgentProfile.builtIn {
            let line = agent.launchCommand(prompt: "fix", model: "fast-one")
            #expect(line.contains("--model fast-one"), "\(agent.name)")
            #expect(!agent.launchCommand(prompt: "fix").contains("--model"))
        }
        let (config, _) = ConfigLoader.decode("""
        [agents.mine]
        command = "mine"
        model_flag = "-m"
        """)
        let mine = try #require(config?.work.agents.first { $0.name == "mine" })
        #expect(mine.launchCommand(prompt: "", model: "x").hasSuffix("mine -m x"))
    }

    @Test func runsPersistAndOldCachesLoad() throws {
        var domain = Domain()
        var run = PilotRun(
            ref: ref, sessionID: "s", goal: .green, agent: "codex", model: "m", startedAt: Date(), items: 2,
            prBranch: "b", branch: "heed/get-it-green/b", worktree: "/wt", startSHA: "a"
        )
        domain.apply(.runUpdated(run))
        run.endedAt = Date()
        run.outcome = .pushed(1)
        domain.apply(.runUpdated(run))
        #expect(domain.runs.count == 1 && domain.runs[0].outcome == .pushed(1))
        let data = try JSONEncoder().encode(domain)
        #expect(try JSONDecoder().decode(Domain.self, from: data).runs == domain.runs)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["runs"] = nil
        #expect(try JSONDecoder().decode(Domain.self, from: JSONSerialization.data(withJSONObject: json)).runs.isEmpty)
    }

    @Test func aBusyRunPutsItsSessionInNeedsYou() {
        let session = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.idle))
        #expect(SessionGroup.of(session, pilot: SessionPilot(helperNeedsYou: true)) == .needsYou)
    }
}

/// A run's worktree and its cleanup against real git.
struct RunGitTests {
    private func git(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.output("git", ["-C", path] + args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aRunPushesAndCleansUpAndTheSweepIsSafe() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("heed-run-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let remote = base + "/remote.git", clone = base + "/clone", main = base + "/wt/r/fix-a"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output("git", ["init", "-q", "--bare", "-b", "main", remote])
        _ = try await ProcessRunner.output("git", ["clone", "-q", remote, clone])
        for args in [
            ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["commit", "-q", "--allow-empty", "-m", "a"],
            ["push", "-q", "origin", "main"], ["worktree", "add", "-q", "-b", "fix-a", main],
        ] {
            _ = try await git(clone, args)
        }
        _ = try await git(main, ["push", "-q", "-u", "origin", "fix-a"])
        let record = RepoRecord(repo: Repo(org: "o", name: "r"), path: clone)
        let branch = Runs.branch(.green, prBranch: "fix-a")

        let before = await Git.remoteSHA(record, branch: "fix-a")
        let worktree = try await Git.addRunWorktree(
            record, path: Runs.worktreePath(root: base + "/wt", repo: record.repo, goal: .green, prBranch: "fix-a"),
            branch: "fix-a", runBranch: branch
        )
        #expect(try await git(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch)
        #expect(try await git(worktree, ["rev-parse", "--abbrev-ref", "@{u}"]) == "origin/fix-a")
        _ = try await git(worktree, ["commit", "-q", "--allow-empty", "-m", "run fix"])
        _ = try await git(worktree, ["push", "-q", "origin", "HEAD:fix-a"])
        let after = await Git.remoteSHA(record, branch: "fix-a")
        let count = await Git.commitCount(record, from: before!, to: after!)
        #expect(Runs.outcome(before: before, after: after, commits: count) == .pushed(1))
        #expect(await Git.runBranches(record).map(\.branch) == [branch])

        // A live run is never swept; once it is not, a clean and pushed one is.
        #expect(await RunCleanup.clean(record, live: [branch]).map(\.removed) == [false])
        #expect(await RunCleanup.clean(record, live: [], untouchedFor: 3600).map(\.removed) == [false])
        #expect(await RunCleanup.clean(record, live: []).map(\.removed) == [true])
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(await Git.runBranches(record).isEmpty)
        #expect(await Git.fastForwardIfClean(at: main))
        #expect(try await git(main, ["log", "-1", "--format=%s"]) == "run fix")

        // A leftover with work of its own is kept.
        let dirty = try await Git.addRunWorktree(
            record, path: Runs.worktreePath(root: base + "/wt", repo: record.repo, goal: .merged, prBranch: "fix-a"),
            branch: "fix-a", runBranch: Runs.branch(.merged, prBranch: "fix-a")
        )
        FileManager.default.createFile(atPath: dirty + "/wip.txt", contents: Data("x".utf8))
        let kept = await RunCleanup.clean(record, live: [])
        #expect(kept.map(\.removed) == [false] && kept.first?.reason == "it has uncommitted changes")
    }
}

struct RunBaseWorktreeTests {
    private let upstream = Repo(org: "elastic", name: "docs-builder")
    private let fork = Repo(org: "me", name: "docs-builder")

    private func worktree(_ repo: Repo, _ path: String, branch: String?, main: Bool = false) -> Worktree {
        Worktree(repo: repo, path: path, branch: branch, head: "", isMain: main)
    }

    @Test func aForkStillFindsItsWorktree() {
        let ref = PullRef(repo: upstream, number: 1)
        let mine = worktree(fork, "/wt/docs-builder/fix-a", branch: "fix-a")
        let other = worktree(Repo(org: "o", name: "other"), "/wt/other/fix-a", branch: "x")
        // The PR is upstream, the clone's origin is the fork: same repo name, or the PR's branch.
        #expect(Runs.baseWorktree(for: ref, headBranch: "fix-a", owned: [other, mine], all: [other, mine]) == mine)
        #expect(Runs.baseWorktree(for: ref, headBranch: nil, owned: [other, mine], all: []) == mine)
        // The exact repo wins when there is one.
        let exact = worktree(upstream, "/wt/docs-builder/fix-a-up", branch: "fix-a")
        #expect(Runs.baseWorktree(for: ref, headBranch: "fix-a", owned: [mine, exact], all: []) == exact)
        // Nothing owned: any worktree on the PR's branch, never a main checkout.
        let loose = worktree(fork, "/code/docs-builder", branch: "fix-a", main: true)
        #expect(Runs.baseWorktree(for: ref, headBranch: "fix-a", owned: [], all: [loose, mine]) == mine)
        #expect(Runs.baseWorktree(for: ref, headBranch: "fix-a", owned: [], all: [loose]) == nil)
    }
}
