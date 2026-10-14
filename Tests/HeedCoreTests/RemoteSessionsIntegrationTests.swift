import Foundation
@testable import HeedCore
import Testing

/// Against a real host (see RemoteIntegrationTests), plus HEED_ZMX_TARBALLS: a folder with zmx-<platform>.tar.gz.
@Suite(.serialized)
struct RemoteSessionsIntegrationTests {
    private var setup: (dir: String, target: String, tarballs: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HEED_SSH_TEST"], let target = env["HEED_SSH_TEST_TARGET"],
              let tarballs = env["HEED_ZMX_TARBALLS"] else { return nil }
        return (dir, target, tarballs)
    }

    @Test func installHooksAndEventsComeBack() async throws {
        guard let setup else { return }
        Remote.setTargets(["box": setup.target])
        Remote.setExtraOptions([
            "-o", "UserKnownHostsFile=\(setup.dir)/known_hosts", "-o", "IdentityFile=\(setup.dir)/id",
            "-o", "IdentitiesOnly=yes",
        ])
        defer { Remote.setExtraOptions([]); Remote.setTargets([:]) }
        try await HostSetup.install(
            on: "box", zmxVersion: "0.8.1",
            zmxTarball: { URL(fileURLWithPath: "\(setup.tarballs)/zmx-\($0).tar.gz") },
            files: ["~/.heed/claude-hooks.json": AgentIntegration.claudeSettingsJSON()]
        )
        #expect(await HostSetup.installedZmx(on: "box") == "0.8.1")

        // Calls as agents make them, from a pane's environment.
        let calls = """
        : > "$HOME/.heed/events.log"
        export HEED_SESSION_ID=s-42 HEED_PANE_ID=p-7 HEED_BIN="$HOME/.heed/bin/heed-hook"
        "$HEED_BIN" state working --reason "running tests"
        echo '{"session_id":"abc","source":"startup"}' | "$HEED_BIN" hook claude SessionStart
        echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create"},"tool_response":{"stdout":"https://github.com/o/r/pull/9"}}' | "$HEED_BIN" hook claude PostToolUse
        "$HEED_BIN" hook pi idle sid-1
        cat "$HOME/.heed/events.log"
        """
        let output = try await ProcessRunner.output(on: .host("box"), "sh", ["-c", calls])
        let messages = output.split(separator: "\n").flatMap { HostEvents.messages(fromLine: String($0)) }
        #expect(messages.allSatisfy { $0.session == "s-42" && $0.pane == "p-7" })
        let kinds = messages.map(\.kind)
        #expect(kinds.contains(.state(.working, reason: "running tests")))
        #expect(kinds.contains(.agentSession(id: "abc", agent: "claude")))
        #expect(kinds.contains(.prAdd(url: "https://github.com/o/r/pull/9")))
        #expect(kinds.contains(.state(.done, reason: nil)))

        // The pane command, for the pseudo-terminal check.
        let command = RemotePane.command(host: "box", pane: "rp1", directory: "~/code/docs-builder", sessionID: "s-42")
        try command.write(toFile: "\(setup.dir)/pane-command.sh", atomically: true, encoding: .utf8)
    }
}
