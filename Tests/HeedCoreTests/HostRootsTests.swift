import Foundation
@testable import HeedCore
import Testing

struct HostRootsTests {
    // MARK: The probe

    @Test func theProbeOutputIsReadAsFoldersUnderHome() {
        let output = """
        Welcome to devbox
        folder=0 src
        folder=3 code
        folder=12 Projects
        folder=1 My Stuff
        folder=x broken
        folder=2 /etc
        folder=2 ../elsewhere
        folder=3 code
        """
        #expect(ProjectFolders.folders(fromOutput: output) == [
            ProjectFolder(path: "~/Projects", repos: 12),
            ProjectFolder(path: "~/code", repos: 3),
            ProjectFolder(path: "~/My Stuff", repos: 1),
            ProjectFolder(path: "~/src", repos: 0),
        ])
        #expect(ProjectFolders.folders(fromOutput: "").isEmpty)
    }

    /// fish reads `\` inside single quotes, and the script reaches the host as `sh -c '<script>'` through whatever
    /// login shell it has.
    @Test func theProbeHoldsNoBackslash() {
        #expect(!ProjectFolders.script.contains("\\"))
    }

    /// A made-up home: the usual folders, a top-level folder with a checkout in it, ones that are skipped.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("roots-\(UUID().uuidString)")
        let checkouts = [
            "Projects/alpha", "Projects/beta", "Projects/group/gamma", "code/delta", "experiments/epsilon",
            "My Stuff/zeta", "Library/eta", "node_modules/theta", "go/src/github.com/you/iota",
            "Projects/group/node_modules",
        ]
        for path in checkouts {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(path).appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }
        for path in ["src", "Documents/notes", ".cache/kappa/.git"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(path), withIntermediateDirectories: true
            )
        }
        // A worktree's `.git` is a file: not a main checkout.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Projects/wt/feature"), withIntermediateDirectories: true
        )
        try "gitdir: /x".write(
            to: home.appendingPathComponent("Projects/wt/feature/.git"), atomically: true, encoding: .utf8
        )
        return home
    }

    private let expected = [
        ProjectFolder(path: "~/Projects", repos: 3),
        ProjectFolder(path: "~/My Stuff", repos: 1),
        ProjectFolder(path: "~/code", repos: 1),
        ProjectFolder(path: "~/experiments", repos: 1),
        ProjectFolder(path: "~/go/src", repos: 0),
        ProjectFolder(path: "~/src", repos: 0),
    ]

    @Test func theProbeFindsTheFoldersOnThisMac() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", ProjectFolders.script], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            timeout: .seconds(20), caller: "test"
        )
        #expect(result.succeeded)
        #expect(ProjectFolders.folders(fromOutput: result.stdout) == expected)
    }

    /// The way it reaches a host whose login shell is fish: the quoted line ssh hands to it.
    @Test func theProbeRunsFromFish() async throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { return }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let line = Remote.shellLine(["sh", "-c", ProjectFolders.script])
        let result = try await ProcessRunner.run(
            fish, ["--no-config", "-c", line], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            timeout: .seconds(20), caller: "test"
        )
        #expect(result.succeeded)
        #expect(ProjectFolders.folders(fromOutput: result.stdout) == expected)
    }

    // MARK: Asking once

    @Test func heedAsksOnceWhenConfigDoesNotSayWhereReposAre() throws {
        let connected = HostStatus.connected(HostInfo(
            latency: .milliseconds(5), platform: "Darwin arm64", git: "2.50.0", zmx: nil, agents: []
        ))
        let host = HostConfig(name: "devbox")
        #expect(HostRoots.shouldAsk(host, status: connected, asked: []))
        #expect(!HostRoots.shouldAsk(host, status: connected, asked: ["devbox"]))
        #expect(HostRoots.shouldAsk(host, status: connected, asked: ["other"]))
        #expect(!HostRoots.shouldAsk(host, status: .unknown, asked: []))
        #expect(!HostRoots.shouldAsk(host, status: .offline(reason: "x", lastSeen: nil), asked: []))

        let (decoded, _) = ConfigLoader.decode("""
        [hosts.devbox]
        repo_roots = ["~/code"]
        [hosts.mac]
        worktree_root = "~/wt"
        """)
        let config = try #require(decoded)
        #expect(try !HostRoots.shouldAsk(#require(config.hosts["devbox"]), status: connected, asked: []))
        let mac = try #require(config.hosts["mac"])
        #expect(HostRoots.shouldAsk(mac, status: connected, asked: []))
        #expect(HostRoots.proposedWorktreeRoot(mac) == "~/wt")
        #expect(try HostRoots.proposedWorktreeRoot(#require(config.hosts["devbox"])) == "~/code/wt")
    }

    // MARK: Writing the answer

    @Test func theAnswerIsWrittenToConfigAndReadBack() throws {
        let source = """
        # my hosts
        [hosts.mac]
        ssh = "you@mac.lan"   # the laptop

        [keys]
        insert_escape = "<C-\\\\>"
        """
        var text = source
        for (path, value) in HostRoots.settings(
            host: "mac", roots: ["~/Projects", "~/My Stuff"], worktreeRoot: "~/Projects/wt"
        ) {
            text = try TOMLDocument(text).setting(path, to: value)
        }
        #expect(text.contains("# my hosts"))
        #expect(text.contains("ssh = \"you@mac.lan\"   # the laptop"))
        let (decoded, problems) = ConfigLoader.decode(text)
        #expect(problems.isEmpty)
        let mac = try #require(decoded?.hosts["mac"])
        #expect(mac.repoRoots == ["~/Projects", "~/My Stuff"])
        #expect(mac.worktreeRoot == "~/Projects/wt")
        #expect(mac.explicitRepoRoots && mac.explicitWorktreeRoot)
        #expect(mac.ssh == "you@mac.lan")

        // Asked again: the values are replaced in place, not added twice.
        for (path, value) in HostRoots.settings(host: "mac", roots: ["~/code"], worktreeRoot: "~/code/wt") {
            text = try TOMLDocument(text).setting(path, to: value)
        }
        #expect(text.components(separatedBy: "repo_roots").count == 2)
        #expect(ConfigLoader.decode(text).0?.hosts["mac"]?.repoRoots == ["~/code"])
    }

    @Test func typedFoldersMustBeUnderHome() {
        #expect(HostRoots.typedFolder(" ~/Projects/ ") == "~/Projects")
        #expect(HostRoots.typedFolder("~") == "~")
        #expect(HostRoots.typedFolder("/opt/src") == nil)
        #expect(HostRoots.typedFolder("~/../root") == nil)
        #expect(HostRoots.typedFolder("Projects") == nil)
    }

    // MARK: The dialog

    private func type(_ text: String, into chooser: inout HostRootsChooser) {
        for character in text {
            _ = chooser.handle(character == " " ? KeyStroke("Space") : KeyStroke(String(character)))
        }
    }

    @Test func foldersWithReposStartPicked() {
        let chooser = HostRootsChooser(
            host: "mac",
            found: [ProjectFolder(path: "~/Projects", repos: 7), ProjectFolder(path: "~/src", repos: 0)],
            current: ["~/old"], worktreeRoot: "~/code/wt"
        )
        #expect(chooser.chosen == ["~/Projects", "~/old"])
        #expect(chooser.rows.map(\.folder.path) == ["~/Projects", "~/src", "~/old"])
    }

    @Test func spaceTogglesAndReturnSaves() {
        var chooser = HostRootsChooser(
            host: "mac",
            found: [ProjectFolder(path: "~/Projects", repos: 7), ProjectFolder(path: "~/src", repos: 0)],
            worktreeRoot: "~/code/wt"
        )
        _ = chooser.handle(KeyStroke("j"))
        _ = chooser.handle(KeyStroke("Space"))
        #expect(chooser.handle(KeyStroke("CR")) == .save(roots: ["~/Projects", "~/src"], worktreeRoot: "~/code/wt"))
        _ = chooser.handle(KeyStroke("k"))
        _ = chooser.handle(KeyStroke("Space"))
        _ = chooser.handle(KeyStroke("j"))
        _ = chooser.handle(KeyStroke("Space"))
        if case .invalid = chooser.handle(KeyStroke("CR")) {} else { Issue.record("saved with nothing picked") }
        #expect(chooser.handle(.escape) == .skip)
    }

    @Test func aFolderAndTheWorktreeRootAreTyped() {
        var chooser = HostRootsChooser(
            host: "mac", found: [ProjectFolder(path: "~/code", repos: 0)], worktreeRoot: "~/code/wt"
        )
        _ = chooser.handle(KeyStroke("a"))
        #expect(chooser.editing == .folder("~/"))
        type("My Stuff/", into: &chooser)
        #expect(chooser.handle(KeyStroke("CR")) == .handled)
        #expect(chooser.editing == nil)
        #expect(chooser.chosen == ["~/My Stuff"])
        #expect(chooser.rows.last?.folder == ProjectFolder(path: "~/My Stuff", repos: nil))

        _ = chooser.handle(KeyStroke("a"))
        _ = chooser.handle(KeyStroke("u", .control))
        type("/etc", into: &chooser)
        _ = chooser.handle(KeyStroke("CR"))
        #expect(chooser.problem != nil)
        // ⎋ while typing only stops typing.
        #expect(chooser.handle(.escape) == .handled)
        #expect(chooser.editing == nil)

        _ = chooser.handle(KeyStroke("w"))
        _ = chooser.handle(KeyStroke("w", .control))
        type("wt", into: &chooser)
        _ = chooser.handle(KeyStroke("CR"))
        #expect(chooser.worktreeRoot == "~/code/wt")
        _ = chooser.handle(KeyStroke("w"))
        _ = chooser.handle(KeyStroke("u", .control))
        type("~/My Stuff/wt", into: &chooser)
        _ = chooser.handle(KeyStroke("CR"))
        #expect(chooser.handle(KeyStroke("CR", .command)) == .save(
            roots: ["~/My Stuff"],
            worktreeRoot: "~/My Stuff/wt"
        ))
    }

    @Test func returnOnTheAddLineStartsTyping() {
        var chooser = HostRootsChooser(host: "mac", found: [], worktreeRoot: "~/code/wt")
        #expect(chooser.cursor == chooser.addRow)
        _ = chooser.handle(KeyStroke("CR"))
        #expect(chooser.editing == .folder("~/"))
        _ = chooser.handle(.escape)
        _ = chooser.handle(KeyStroke("j"))
        _ = chooser.handle(KeyStroke("Space"))
        #expect(chooser.editing == .worktreeRoot("~/code/wt"))
    }
}
