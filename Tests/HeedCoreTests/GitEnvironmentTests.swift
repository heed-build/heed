import Foundation
@testable import HeedCore
import Testing

struct GitEnvironmentTests {
    /// The repo's config, refs and worktrees, read with its git dir named explicitly.
    private func snapshot(_ bare: String) async throws -> String {
        let config = try String(contentsOfFile: bare + "/config", encoding: .utf8)
        let refs = try await ProcessRunner.output(
            "git", ["--git-dir", bare, "for-each-ref", "--format=%(refname) %(objectname)"], caller: "test"
        )
        let worktrees = (try? FileManager.default.contentsOfDirectory(atPath: bare + "/worktrees")) ?? []
        return config + "\n" + refs + "\n" + worktrees.sorted().joined(separator: ",")
    }

    @Test func gitRunByHeedNeverReachesTheRepoItsParentPointsAt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("heed-gitenv-\(UUID().uuidString)")
            .resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let bare = base + "/outer.git", repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output("git", ["init", "-q", "--bare", "-b", "main", bare], caller: "test")
        let before = try await snapshot(bare)

        // As `git rebase --exec` would leave them for the commands it runs: handed to this test's commands only, so
        // the suites running beside it never see them.
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_DIR"] = bare
        inherited["GIT_INDEX_FILE"] = bare + "/index"
        inherited["GIT_WORK_TREE"] = base
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try await GitEnvironment.$inheritedOverride.withValue(inherited) {
            for args in [
                ["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["add", "."], ["commit", "-qm", "a"],
                ["branch", "side"], ["worktree", "add", "-q", base + "/linked", "-b", "f"],
                ["init", "-q", "--bare", base + "/other.git"],
            ] {
                _ = try await ProcessRunner.output("git", ["-C", repo] + args, caller: "test")
            }
        }

        #expect(try await snapshot(bare) == before)
        // The commands did their work where they were pointed.
        let log = try await ProcessRunner.output("git", ["-C", repo, "log", "--format=%an %s"], caller: "test")
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "heed test a")
    }

    @Test func theRepositoryVariablesAreDroppedAndTheRestKept() {
        let parent = ["GIT_DIR": "/x", "GIT_COMMON_DIR": "/y", "PATH": "/bin", "GIT_EDITOR": "vi"]
        let environment = GitEnvironment.environment(parent, ["A": "1"])
        #expect(environment["GIT_DIR"] == nil && environment["GIT_COMMON_DIR"] == nil)
        #expect(environment["PATH"] == "/bin" && environment["GIT_EDITOR"] == "vi" && environment["A"] == "1")
    }
}
