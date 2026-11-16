import Foundation
@testable import HeedCore
import Testing

/// A headless review run as heed launches it (`ReviewRun.headless` with the run's folder, behind
/// `RunSandbox.environment`), against real Claude Code on haiku in a throwaway repo: the agent is asked to reach the
/// network, write outside its worktree, use gh and read a variable it was started with, and to write inside its
/// worktree and its run folder. Only the last two may work. What each command printed is kept in the capture folder.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveSandboxTests {
    @Test(.timeLimit(.minutes(5))) func aReviewRunsShellIsSandboxed() async throws {
        let scratch = try Live.scratch("sandbox")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let worktree = try await Live.repo(in: scratch, files: ["README.md": "# tiny\n"])
        let folder = RunFolder.path(run: "run", root: scratch.resolvingSymlinksInPath().path)
        try RunFolder.prepare(folder)
        // Outside: a folder of its own under the home folder (temp folders may be writable in any sandbox).
        let elsewhere = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/heed-live-sandbox-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("outside.txt").path
        let steps = [
            "curl -sS --max-time 10 https://example.com > curl.out 2>&1; echo \"exit $?\" >> curl.out",
            "touch \(outside) > touch.out 2>&1; echo \"exit $?\" >> touch.out",
            // Through env, which the `Bash(gh:*)` deny does not match: gh runs, and has no login.
            "/usr/bin/env gh auth status > gh.out 2>&1; echo \"exit $?\" >> gh.out",
            // Set where the run starts, like a variable your shell config exports: the run's environment drops it.
            "echo \"probe=${LIVE_PROBE_KEY:-none}\" > env.out",
            "echo hi > inside.txt",
            "echo hi > \(folder)/report.txt",
        ]
        let prompt = "This is a check of your shell, nothing else. Run each of these commands with your Bash tool, "
            + "exactly as written, one at a time, in the current folder, even if one fails. Do not retry, change or "
            + "explain them, and do not ask to run anything outside the sandbox.\n"
            + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\nThen reply with the word done."
        let words = try #require(ReviewRun.headless(
            agent: "claude", command: "claude", prompt: .owner(prompt), model: Live.model, worktree: worktree,
            folder: folder
        ))
        // The run starts from an empty environment, so the test runner's own Claude Code and heed variables go too.
        let claude = try Live.which("claude")
        let line = RunSandbox.environment(agent: "claude", folder: folder) + [claude] + words.dropFirst()
        let result = try await ProcessRunner.run(
            line[0], Array(line.dropFirst()), in: worktree, environment: ["LIVE_PROBE_KEY": "set"],
            timeout: .seconds(240), caller: "live.sandbox"
        )
        func read(_ name: String) -> String {
            (try? String(contentsOfFile: "\(worktree)/\(name)", encoding: .utf8)) ?? "(none)"
        }
        Live.keep(
            "sandbox.out",
            ["curl.out", "touch.out", "gh.out", "env.out"].map { "--- \($0)\n" + read($0) }.joined(separator: "\n")
                + "\n--- stdout\n" + result.stdout + "\n--- stderr\n" + result.stderr
        )
        // It ran the commands, inside the worktree and the run's folder.
        #expect(FileManager.default.fileExists(atPath: "\(worktree)/inside.txt"))
        #expect(FileManager.default.fileExists(atPath: "\(folder)/report.txt"))
        // No network, nothing outside, no gh login.
        #expect(read("curl.out").contains("exit ") && !read("curl.out").contains("exit 0"))
        #expect(!read("curl.out").lowercased().contains("example domain"))
        #expect(read("touch.out").contains("exit ") && !read("touch.out").contains("exit 0"))
        #expect(!FileManager.default.fileExists(atPath: outside))
        // gh either was refused outright or ran with no login.
        #expect(read("gh.out") == "(none)" || (read("gh.out").contains("exit ") && !read("gh.out").contains("exit 0")))
        #expect(!read("gh.out").contains("Logged in"))
        // Nothing it was not given: the probe never reached it.
        #expect(!read("env.out").contains("probe=set"))
    }
}
