import Foundation
@testable import HeedCore
import Testing

struct SetupDetectionTests {
    @Test func miseAloneWhenTheRepoUsesIt() {
        let proposal = SetupDetection.propose(files: ["mise.toml", "pnpm-lock.yaml", "uv.lock"])
        #expect(proposal.commands == ["mise install"])
        #expect(proposal.reasons == ["mise.toml"])
        #expect(SetupDetection.propose(files: [".config/mise/config.toml", "package-lock.json"]).commands
            == ["mise install"])
    }

    @Test func lockfilesPickTheirInstalls() {
        #expect(SetupDetection.propose(files: ["pnpm-lock.yaml", "package.json"]).commands == ["pnpm install"])
        #expect(SetupDetection.propose(files: ["bun.lock", "bun.lockb"]).commands == ["bun install"])
        #expect(SetupDetection.propose(files: ["package-lock.json"]).commands == ["npm ci"])
        #expect(SetupDetection.propose(files: ["yarn.lock"]).commands == ["yarn install"])
        #expect(SetupDetection.propose(files: ["uv.lock", "pnpm-lock.yaml"]).commands == ["pnpm install", "uv sync"])
        #expect(SetupDetection.propose(files: ["poetry.lock"]).commands == ["poetry install"])
        #expect(SetupDetection.propose(files: ["docs-builder.sln", "README.md"]).lines
            == ["dotnet restore (docs-builder.sln)"])
    }

    @Test func nothingForReposThatFetchOnBuild() {
        #expect(SetupDetection.propose(files: ["Cargo.lock", "Cargo.toml"]).isEmpty)
        #expect(SetupDetection.propose(files: ["go.mod", "go.sum"]).isEmpty)
        #expect(SetupDetection.propose(files: ["src/app.csproj"]).isEmpty)
    }

    @Test func listsTheFilesOfACheckout() async throws {
        let root = try TempRepo()
        try root.write("pnpm-lock.yaml", "")
        try root.write(".config/mise/config.toml", "[tools]\n")
        let files = await SetupDetection.files(at: root.path)
        #expect(files.contains("pnpm-lock.yaml"))
        #expect(files.contains(".config/mise/config.toml"))
        #expect(await SetupDetection.detect(at: root.path).commands == ["mise install"])
    }

    @Test func repoBeforeOrg() {
        let rules = SetupRules(orgs: ["elastic": ["make deps"]], repos: ["elastic/kibana": []])
        #expect(rules.commands(for: Repo(org: "elastic", name: "kibana")) == [])
        #expect(rules.commands(for: Repo(org: "elastic", name: "docs-builder")) == ["make deps"])
        #expect(rules.commands(for: Repo(org: "nullean", name: "curb")) == nil)
    }

    @Test func configReadsSetupAndTheTrustSwitch() {
        let source = """
        [worktrees]
        offer_trust = false
        [orgs.elastic]
        setup = ["make deps"]
        [repos."elastic/kibana"]
        setup = []
        """
        let config = ConfigLoader.decode(source).config
        #expect(config?.work.offerTrust == false)
        #expect(config?.work.setup.orgs["elastic"] == ["make deps"])
        #expect(config?.work.setup.repos["elastic/kibana"] == [])
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.work.offerTrust == true)
        let key = Overrides.keys.first { $0.id == "setup" }!
        let kibana = OverrideScope.repo(Repo(org: "elastic", name: "kibana"))
        #expect(Overrides.effective(key, at: kibana, in: config!).value == .list([]))
        #expect(Overrides.effective(key, at: .repo(Repo(org: "elastic", name: "x")), in: config!).source == .org)
    }
}

struct SetupPaneCommandTests {
    @Test func noSetupLeavesTheCommand() {
        #expect(WorktreeSetup.paneCommand(setup: [], then: "claude") == "claude")
        #expect(WorktreeSetup.paneCommand(setup: [" "], then: nil) == nil)
    }

    @Test func setupRunsFirstAndTheAgentOnlyAfterIt() throws {
        let line = try #require(WorktreeSetup.paneCommand(setup: ["pnpm install"], then: "claude 'fix it'"))
        #expect(line.hasPrefix("sh -c '"))
        #expect(line.hasSuffix(" && claude 'fix it'"))
        #expect(!line.contains("task-exit"))
        #expect(WorktreeSetup.paneCommand(setup: ["x"], then: "claude", report: true)?.contains("task-exit") == true)
    }

    /// The line runs in a real shell: a passing setup starts the command, a failing one says so and stops there.
    @Test func failureStopsAndSaysHow() async throws {
        let passing = try #require(WorktreeSetup.paneCommand(setup: ["true", "echo set"], then: "echo agent"))
        let ok = try await ProcessRunner.run("/bin/sh", ["-c", passing])
        #expect(ok.succeeded)
        #expect(ok.stdout.contains("set\n"))
        #expect(ok.stdout.hasSuffix("agent\n"))
        let failing = try #require(WorktreeSetup.paneCommand(
            setup: ["sh -c 'exit 3'", "echo never"],
            then: "echo agent"
        ))
        let bad = try await ProcessRunner.run("/bin/sh", ["-c", failing])
        #expect(bad.status == 3)
        #expect(bad.stdout
            .contains("heed: setup failed (sh -c 'exit 3'); fix it, then start the agent with:\n  echo agent"))
        #expect(!bad.stdout.contains("never"))
        #expect(!bad.stdout.split(separator: "\n").contains("agent"))
    }

    /// An install whose manifest the worktree lacks is skipped, not failed: the next step and the command still run.
    @Test func missingManifestSkipsTheInstall() async throws {
        let dir = NSTemporaryDirectory() + "heed-setup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let line = try #require(WorktreeSetup.paneCommand(setup: ["npm ci", "echo after"], then: "echo agent"))
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "cd '\(dir)' && \(line)"])
        #expect(result.succeeded)
        #expect(result.stdout.contains("heed: setup: skipped npm ci (no package.json)"))
        #expect(result.stdout.contains("after\n"))
        #expect(result.stdout.hasSuffix("agent\n"))
        #expect(!result.stdout.contains("setup failed"))
    }

    @Test func manifestsPerPackageManager() {
        #expect(WorktreeSetup.manifest(for: "pnpm install") == "package.json")
        #expect(WorktreeSetup.manifest(for: "uv sync") == "pyproject.toml")
        #expect(WorktreeSetup.manifest(for: "mise install") == nil)
        #expect(WorktreeSetup.manifest(for: "npm") == nil)
    }
}

struct WorktreeIncludeTests {
    @Test func copiesIgnoredMatchesOnly() async throws {
        let repo = try TempRepo()
        try repo.write(".gitignore", ".env*\nsecrets/\nnode_modules/\n")
        try repo.write(".worktreeinclude", "# from the main checkout\n.env*\nsecrets/\ntracked.txt\nconfig/*.local\n")
        try repo.write("tracked.txt", "tracked")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "init")
        try repo.write(".env", "A=1")
        try repo.write(".env.local", "B=2")
        try repo.write("secrets/deep/key", "k")
        try repo.write("node_modules/p/index.js", "n")
        try repo.write("config/a.local", "not ignored")
        let worktree = repo.path + "-wt"
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try repo.git("worktree", "add", "-q", "-b", "wt", worktree)
        try "mine".write(toFile: worktree + "/.env.local", atomically: true, encoding: .utf8)

        let copied = await WorktreeInclude.copy(from: repo.path, to: worktree)
        #expect(Set(copied) == [".env", "secrets/deep/key"])
        #expect(try String(contentsOfFile: worktree + "/.env", encoding: .utf8) == "A=1")
        // What the worktree already has is left alone.
        #expect(try String(contentsOfFile: worktree + "/.env.local", encoding: .utf8) == "mine")
        #expect(!FileManager.default.fileExists(atPath: worktree + "/node_modules"))
        #expect(!FileManager.default.fileExists(atPath: worktree + "/config/a.local"))
    }

    @Test func nothingWithoutTheFile() async throws {
        let repo = try TempRepo()
        try repo.write(".gitignore", ".env\n")
        try repo.write(".env", "A=1")
        #expect(await WorktreeInclude.copy(from: repo.path, to: repo.path + "-nowhere").isEmpty)
    }
}

struct ClaudeTrustTests {
    @Test func setsAnExistingValueInPlace() throws {
        let source = """
        {
          "numStartups": 3,
          "projects": {
            "/Users/me": {
              "hasTrustDialogAccepted": false
            },
            "/code/x": {
              "allowedTools": [],
              "hasTrustDialogAccepted": false,
              "note": "a } in a string, and \\"quotes\\""
            }
          },
          "z": 1
        }

        """
        let edited = try ClaudeTrust.trusting("/code/x", in: source)
        #expect(edited == source.replacingOccurrences(
            of: "\"hasTrustDialogAccepted\": false,\n      \"note\"",
            with: "\"hasTrustDialogAccepted\": true,\n      \"note\""
        ))
        #expect(ClaudeTrust.isTrusted("/code/x", json: edited))
        #expect(!ClaudeTrust.isTrusted("/Users/me", json: edited))
    }

    @Test func addsWhatIsMissingAtTheTopOfItsObject() throws {
        let source = "{\n  \"projects\": {\n    \"/a\": {\n      \"x\": 1\n    }\n  },\n  \"y\": 2\n}\n"
        let entry = try ClaudeTrust.trusting("/a", in: source)
        #expect(entry ==
            "{\n  \"projects\": {\n    \"/a\": {\n      \"hasTrustDialogAccepted\": true,\n      \"x\": 1\n    }\n  },\n  \"y\": 2\n}\n")
        let project = try ClaudeTrust.trusting("/b", in: source)
        #expect(project.hasPrefix("{\n  \"projects\": {\n    \"/b\": {\"hasTrustDialogAccepted\": true},\n    \"/a\""))
        let none = try ClaudeTrust.trusting("/b", in: "{\"y\": 2}")
        #expect(ClaudeTrust.isTrusted("/b", json: none))
        #expect(none.contains("\"y\": 2"))
        let empty = try ClaudeTrust.trusting("/b", in: "{}")
        #expect(ClaudeTrust.isTrusted("/b", json: empty))
        #expect(throws: ClaudeTrust.TrustError.self) { try ClaudeTrust.trusting("/b", in: "[1]") }
    }

    @Test func writesAtomicallyWithABackupAndNeverTheHomeFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".claude.json")
        let original = "{\n  \"numStartups\": 1\n}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        #expect(!ClaudeTrust.isTrusted("/code/x", file: file))
        try ClaudeTrust.trust("/code/x", file: file, home: "/Users/me")
        #expect(ClaudeTrust.isTrusted("/code/x", file: file))
        let backup = file.appendingPathExtension("heed-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        try ClaudeTrust.trust("/code/y", file: file, home: "/Users/me")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(ClaudeTrust.isTrusted("/code/x", file: file) && ClaudeTrust.isTrusted("/code/y", file: file))
        #expect(throws: ClaudeTrust.TrustError.self) {
            try ClaudeTrust.trust("/Users/me/", file: file, home: "/Users/me")
        }
        // No file yet: one is made.
        let fresh = directory.appendingPathComponent("fresh.json")
        try ClaudeTrust.trust("/code/x", file: fresh, home: "/Users/me")
        #expect(ClaudeTrust.isTrusted("/code/x", file: fresh))
    }
}

struct MiseTrustTests {
    @Test func readsTrustAndEnv() {
        #expect(MiseTrust.setsEnvironment("[tools]\nnode = \"22\"\n\n[env]\nA = \"1\"\n"))
        #expect(!MiseTrust.setsEnvironment("[tools]\nnode = \"22\"\n[tasks.test]\nrun = \"x\"\n"))
        #expect(MiseTrust.untrusted("/code/x: untrusted\n", root: "/code/x"))
        #expect(!MiseTrust.untrusted("/code/x: trusted\n", root: "/code/x"))
        #expect(!MiseTrust.untrusted("/code: untrusted\n", root: "/code/x"))
    }
}

/// A git repository in a temp directory, removed when the test is done with it.
final class TempRepo {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
        try git("init", "-q")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "t")
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func write(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}
