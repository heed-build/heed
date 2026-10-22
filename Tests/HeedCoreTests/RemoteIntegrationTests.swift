import Foundation
@testable import HeedCore
import Testing

/// Against a real ssh host, when one is set up: HEED_SSH_TEST=<dir> with `id` (a key the host accepts) and
/// `known_hosts`, and HEED_SSH_TEST_TARGET (e.g. ssh://dev@127.0.0.1:2222) for a host with ~/code/docs-builder (origin
/// elastic/docs-builder) and a worktree ~/code/wt/flake-hunt. Skipped otherwise.
@Suite(.serialized)
struct RemoteIntegrationTests {
    private var setup: (dir: String, target: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HEED_SSH_TEST"], let target = env["HEED_SSH_TEST_TARGET"] else { return nil }
        return (dir, target)
    }

    private func configure(_ setup: (dir: String, target: String), knownHosts: String? = nil, key: String? = nil) {
        Remote.setTargets(["box": setup.target])
        Remote.setExtraOptions([
            "-o", "UserKnownHostsFile=\(knownHosts ?? setup.dir + "/known_hosts")",
            "-o", "IdentityFile=\(key ?? setup.dir + "/id")", "-o", "IdentitiesOnly=yes",
            "-o", "ControlPath=none",
        ])
    }

    @Test func checksScanAndListAHost() async throws {
        guard let setup else { return }
        configure(setup)
        defer { Remote.setExtraOptions([]); Remote.setTargets([:]) }
        guard case let .connected(info) = await HostProbe.check("box") else {
            await Testing.Issue.record("not connected: \(HostProbe.check("box"))")
            return
        }
        #expect(info.platform.hasPrefix("Linux"))
        #expect(info.git != nil)

        let records = await RemoteScan.scan(HostConfig(name: "box"))
        let repo = try #require(records.first { $0.repo.slug == "elastic/docs-builder" })
        #expect(repo.location == .host("box"))
        #expect(repo.id == "elastic/docs-builder@box")
        #expect(repo.defaultBranch != nil)

        let worktrees = try await Git.worktrees(of: repo)
        #expect(worktrees.contains { $0.branch == "flake-hunt" && $0.location == .host("box") })
        let flake = try #require(worktrees.first { $0.branch == "flake-hunt" })
        let status = try await Git.status(at: flake.path, on: .host("box"))
        #expect(status.upstream == nil)
    }

    @Test func startsWorkOnAHost() async throws {
        guard let setup else { return }
        configure(setup)
        defer { Remote.setExtraOptions([]); Remote.setTargets([:]) }
        let records = await RemoteScan.scan(HostConfig(name: "box"))
        let repo = try #require(records.first { $0.repo.slug == "elastic/docs-builder" })
        let name = "start-\(Int(Date().timeIntervalSince1970))"
        let plan = StartWorkPlan(prompt: "p", repos: [repo], name: name, agent: nil)
        let changes = try await StartWork.execute(
            plan, settings: WorkSettings(worktreeRoot: "/nowhere"), hosts: ["box": HostConfig(name: "box")]
        )
        let session = try #require(changes.compactMap {
            if case let .sessionUpserted(session) = $0 { session } else { nil }
        }.first)
        let path = try #require(session.worktreePaths.first)
        #expect(session.host == "box")
        #expect(path.hasPrefix("/") && path.hasSuffix("/code/wt/docs-builder/\(name)"))
        let listed = try await Git.worktrees(of: repo)
        #expect(listed.contains { $0.path == path && $0.branch == session.branch && $0.location == .host("box") })
        _ = try? await ProcessRunner.run(
            on: .host("box"), "git", ["-C", repo.path, "worktree", "remove", "--force", path], caller: "test"
        )
        _ = try? await ProcessRunner.run(
            on: .host("box"),
            "git",
            ["-C", repo.path, "branch", "-D", session.branch],
            caller: "test"
        )
    }

    @Test func removesAWorktreeOnAHost() async throws {
        guard let setup else { return }
        configure(setup)
        defer { Remote.setExtraOptions([]); Remote.setTargets([:]) }
        let box = Location.host("box")
        func sh(_ line: String) async throws -> String {
            try await ProcessRunner.output(on: box, "sh", ["-c", line], caller: "test")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try await sh("echo $HOME") + "/heed-remove-\(UUID().uuidString.prefix(8))"
        defer { Task { _ = try? await sh("rm -rf \(base)") } }
        _ = try await sh("""
        set -e; mkdir -p \(base); cd \(base); git init -q -b main repo; cd repo
        git config user.email t@t; git config user.name t; git commit -q --allow-empty -m a
        git worktree add -q -b spike \(base)/wt/spike
        """)
        let record = RepoRecord(repo: Repo(org: "local", name: "repo"), path: base + "/repo", location: box)
        let worktree = Worktree(
            repo: record.repo, path: base + "/wt/spike", branch: "spike", head: "", isMain: false, location: box
        )
        let plan = SweepPlan(
            removals: [SweepPlan.Removal(worktree: worktree, idleDays: 0, sessions: [], deleteBranch: true)],
            skips: [], next: nil
        )
        let (changes, failures) = await Sweep.execute(plan, domain: Domain(repos: [record], worktrees: [worktree]))
        #expect(failures.isEmpty)
        #expect(try await sh("test -e \(worktree.path) && echo there || echo gone") == "gone")
        #expect(try await sh("git -C \(record.path) branch --list spike").isEmpty)
        #expect(changes.contains { if case .worktreesListed = $0 { true } else { false } })
    }

    @Test func failuresAreNamed() async {
        guard let setup else { return }
        let empty = setup.dir + "/empty_known_hosts"
        FileManager.default.createFile(atPath: empty, contents: Data())
        configure(setup, knownHosts: empty)
        #expect(await HostProbe.check("box") == .unknownHostKey)
        configure(setup, key: setup.dir + "/not-a-key")
        if case .needsAuth = await HostProbe.check("box") {} else { Testing.Issue.record("expected needsAuth") }
        Remote.setTargets(["box": "ssh://dev@127.0.0.1:1"])
        if case .offline = await HostProbe.check("box") {} else { Testing.Issue.record("expected offline") }
        Remote.setExtraOptions([])
        Remote.setTargets([:])
    }
}
