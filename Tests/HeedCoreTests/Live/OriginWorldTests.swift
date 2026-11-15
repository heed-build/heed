import Foundation
@testable import HeedCore
import Testing

/// The origin-note live check's stand-in gh, without a model: every gh call agents made in earlier runs succeeds in
/// its world (a failed call reaches no `PostToolUse` hook, so no note), and heed's hook gives its note on the ones that
/// read PR 7's comments.
@Suite(.enabled(
    if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")
        || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq"),
    "needs jq"
), .serialized)
struct OriginWorldTests {
    @Test func everyRecordedCallSucceedsAndTheCommentsGetANote() async throws {
        let folder = try Live.scratch("origin-replay")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await OriginWorld.make(in: folder)
        // Only what the commands need: other tests set git's variables in this process.
        let environment = [
            "PATH": folder.appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let book = OriginWorld.book(repo: repo)
        for command in OriginWorld.recorded {
            let result = try await ProcessRunner.run(
                "/bin/zsh", ["-c", command], in: repo, environment: environment, timeout: .seconds(20),
                caller: "origin.replay"
            )
            #expect(result.succeeded, "\(command)\n\(result.stderr)")
            if command.contains("--comments") || command.contains("pulls/7/") {
                #expect(result.stdout.contains(OriginWorld.comment), "\(command)")
                let input: [String: Any] = [
                    // As Claude Code reports it: through /private.
                    "permission_mode": "auto", "tool_name": "Bash", "cwd": "/private" + repo,
                    "tool_input": ["command": command],
                ]
                #expect(OriginNote.report(input: input) { book }?.note != nil, "\(command)")
            }
        }
    }

    /// The built `heed` as the live check's hooks run it, its socket in `folder`: the note comes back on stdout.
    @Test func theHookBinaryAnswersWithTheNote() async throws {
        guard let heed = try? Live.heedBinary() else { return }
        let folder = try Live.scratch("origin-hook")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await OriginWorld.make(in: folder)
        let socket = folder.appendingPathComponent("h.sock").path
        try OriginWorld.book(repo: repo).write(to: OriginBook.path(forSocket: socket))
        let input: [String: Any] = [
            "hook_event_name": "PostToolUse", "permission_mode": "auto", "tool_name": "Bash", "cwd": "/private" + repo,
            "tool_input": ["command": OriginWorld.recorded.last ?? ""], "tool_response": ["stdout": "x"],
        ]
        let stdin = folder.appendingPathComponent("in.json")
        try JSONSerialization.data(withJSONObject: input).write(to: stdin)
        let line = AgentIntegration.hookCommand(
            heed: heed, sockets: HookSockets(hooks: socket, control: folder.appendingPathComponent("c.sock").path),
            agent: "claude", event: "PostToolUse"
        )
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", line + " < " + ShellQuote.quote(stdin.path)], in: repo,
            environment: ["HEED_SESSION_ID": "replay", "PATH": "/usr/bin:/bin"], timeout: .seconds(10),
            caller: "origin.replay"
        )
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let note = (json["hookSpecificOutput"] as? [String: Any])?["classifierContext"] as? String
        #expect(note?.contains("acme/app PR #7") == true, "\(result.stdout)\n\(result.stderr)")
        #expect(note?.contains("@stranger (not a collaborator on acme/app)") == true)
    }
}
