import Foundation
@testable import HeedCore
import Testing

struct ToolsTests {
    /// A directory holding executable scripts named after tools, each printing `<name> version <dir>`.
    private func bin(_ names: [String], failing: Set<String> = []) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in names {
            let path = "\(directory)/\(name)"
            let body = failing.contains(name) ? "exit 1" : "echo \"\(name) version \(directory)\""
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return directory
    }

    private func check(_ path: String) async -> String? {
        await ToolDetection.version(of: path, developerDirectory: nil)
    }

    @Test func parsesThePathOutOfShellNoise() {
        let output = "Welcome to fish\nsome rc noise\n\n__HEED_PATH__/opt/homebrew/bin:/usr/bin::/bin\n"
        #expect(ToolDetection.parsePath(output) == ["/opt/homebrew/bin", "/usr/bin", "/bin"])
        #expect(ToolDetection.parsePath("no marker here") == nil)
    }

    @Test func asksEachShellInItsOwnSyntax() {
        #expect(ToolDetection.pathQueries(for: "/opt/homebrew/bin/fish").first?.last?.contains("string join") == true)
        #expect(ToolDetection.pathQueries(for: "/bin/zsh").first?.contains("-i") == true)
        #expect(ToolDetection.pathQueries(for: "/bin/zsh").count == 2)
        #expect(ToolDetection.pathQueries(for: "/opt/homebrew/bin/nu").first?.last?.contains("$env.PATH") == true)
    }

    @Test func searchPathKeepsExistingDirectoriesOnce() throws {
        let one = try bin([])
        let path = ToolDetection.searchPath([
            (one, .loginShell), ("/definitely/not/here", .known), (one, .known), ("", .inherited),
        ])
        #expect(path.map(\.0) == [one])
        #expect(path.first?.1 == .loginShell)
    }

    @Test func findsTheFirstThatRuns() async throws {
        let broken = try bin(["git"], failing: ["git"])
        let good = try bin(["git"])
        let tool = await ToolDetection.resolve(
            "git", configured: "", directories: [(broken, .loginShell), (good, .known)], check: check
        )
        #expect(tool.path == "\(good)/git")
        #expect(tool.source == .known)
        #expect(tool.version == "git version \(good)")
        #expect(tool.problem == nil)
    }

    @Test func aConfiguredPathWins() async throws {
        let detected = try bin(["gh"])
        let configured = try bin(["gh"])
        let tool = await ToolDetection.resolve(
            "gh", configured: "\(configured)/gh", directories: [(detected, .loginShell)], check: check
        )
        #expect(tool.path == "\(configured)/gh")
        #expect(tool.source == .config)
    }

    @Test func aConfiguredNameIsSearchedFor() async throws {
        let directory = try bin(["git-2.50"])
        let tool = await ToolDetection.resolve(
            "git", configured: "git-2.50", directories: [(directory, .loginShell)], check: check
        )
        #expect(tool.path == "\(directory)/git-2.50")
        #expect(tool.source == .config)
    }

    @Test func aBrokenConfiguredPathFallsBackAndSaysSo() async throws {
        let detected = try bin(["git"])
        let tool = await ToolDetection.resolve(
            "git", configured: "/nope/git", directories: [(detected, .loginShell)], check: check
        )
        #expect(tool.path == "\(detected)/git")
        #expect(tool.problem?.contains("tools.git") == true)
        #expect(tool.problem?.contains("using \(detected)/git") == true)
    }

    @Test func nothingFoundExplainsWhatToDo() async throws {
        let empty = try bin([])
        let tool = await ToolDetection.resolve("gh", configured: "", directories: [(empty, .known)], check: check)
        #expect(tool.path == nil)
        #expect(tool.problem?.contains("brew install gh") == true)
        #expect(tool.problem?.contains("[tools] gh") == true)
    }

    @Test func stubsWithoutDeveloperToolsAreNotRun() async {
        // /usr/bin/git without the Command Line Tools would pop up an install dialog.
        #expect(await ToolDetection.version(of: "/usr/bin/git", developerDirectory: nil) == nil)
        #expect(await ToolDetection.version(of: "/usr/bin/git", developerDirectory: "/nowhere") == nil)
    }

    @Test func findsAgentCommandsOnTheSearchPath() throws {
        let directory = try bin(["claude"])
        #expect(ToolDetection.find("claude", in: ["/nowhere", directory]) == "\(directory)/claude")
        #expect(ToolDetection.find("missing", in: [directory]) == nil)
    }

    @Test func configReadsTools() {
        let (config, problems) = ConfigLoader.decode("""
        [tools]
        git = "/opt/homebrew/bin/git"
        path = ["~/bin"]
        """)
        #expect(problems.isEmpty)
        #expect(config?.tools == ToolSettings(git: "/opt/homebrew/bin/git", gh: "", path: ["~/bin"]))
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).problems.isEmpty)
    }
}
