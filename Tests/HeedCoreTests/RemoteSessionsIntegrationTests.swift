import Foundation
@testable import HeedCore
import Testing

/// Against a real host (see RemoteIntegrationTests). HEED_ZMX_TARBALLS (a folder with zmx-<platform>.tar.gz) stands
/// in for you installing zmx on the host, into ~/.local/bin as heed's instructions say.
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
        // As you would: zmx gone, then installed by hand into ~/.local/bin, which a non-login ssh has no PATH for.
        _ = try await ProcessRunner.run(
            on: .host("box"),
            "sh",
            ["-c", "rm -rf \"$HOME/.heed/bin/zmx\" \"$HOME/.local/bin/zmx\""], caller: "test"
        )
        guard case let .connected(before) = await HostProbe.check("box") else {
            Testing.Issue.record("offline")
            return
        }
        #expect(before.zmxPath == nil)
        #expect(before.os == "alpine")
        #expect(ZmxInstall.commands(platform: before.platform, os: before.os).first?.contains("~/.local/bin") == true)
        _ = try await ProcessRunner.run(
            on: .host("box"), "sh", ["-c", "mkdir -p \"$HOME/.local/bin\" && tar -xzf - -C \"$HOME/.local/bin\" zmx"],
            input: URL(
                fileURLWithPath: "\(setup.tarballs)/zmx-linux-\(before.platform.hasSuffix("aarch64") ? "aarch64" : "x86_64").tar.gz"
            ), caller: "test"
        )
        guard case let .connected(info) = await HostProbe.check("box") else {
            Testing.Issue.record("offline")
            return
        }
        let zmx = try #require(info.zmxPath)
        #expect(zmx.hasSuffix("/.local/bin/zmx"))
        #expect(info.zmx == "0.8.1")
        try await HostSetup.install(
            on: "box",
            files: ["~/.heed/claude-hooks.json": AgentIntegration.claudeSettingsJSON()]
        )

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
        let output = try await ProcessRunner.output(on: .host("box"), "sh", ["-c", calls], caller: "test")
        let messages = output.split(separator: "\n").flatMap { HostEvents.messages(fromLine: String($0)) }
        #expect(messages.allSatisfy { $0.session == "s-42" && $0.pane == "p-7" })
        let kinds = messages.map(\.kind)
        #expect(kinds.contains(.state(.working, reason: "running tests")))
        #expect(kinds.contains(.agentSession(id: "abc", agent: "claude")))
        #expect(kinds.contains(.prAdd(url: "https://github.com/o/r/pull/9")))
        #expect(kinds.contains(.state(.done, reason: nil)))

        // The pane command, for the pseudo-terminal check.
        let command = RemotePane.command(
            host: "box", pane: "rp1", directory: "~/code/docs-toolkit", sessionID: "s-42", zmx: zmx
        )
        try command.write(toFile: "\(setup.dir)/pane-command.sh", atomically: true, encoding: .utf8)
        let plain = RemotePane.command(
            host: "box",
            pane: "rp2",
            directory: "~/code/docs-toolkit",
            sessionID: "s-42",
            zmx: nil
        )
        try plain.write(toFile: "\(setup.dir)/pane-command-plain.sh", atomically: true, encoding: .utf8)
    }
}
