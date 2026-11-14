import Foundation
@testable import HeedCore
import Testing

/// Approvals end to end: real Claude Code with heed's own hook settings, its `PermissionRequest` hook running the
/// built `heed`, which asks heed's control socket (served here, in process) and waits for the answer.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveApprovalTests {
    @Test(.timeLimit(.minutes(5))) func anAllowLetsTheCommandRun() async throws {
        let outcome = try await round(.allow, file: "allowed.txt")
        #expect(outcome.ran, "the allowed command ran")
    }

    @Test(.timeLimit(.minutes(5))) func aDenyStopsIt() async throws {
        let outcome = try await round(.deny, file: "denied.txt")
        #expect(!outcome.ran, "the denied command did not run")
    }

    private func round(
        _ decision: PermissionAnswer.Decision,
        file: String
    ) async throws -> (ran: Bool, ask: PermissionAsk) {
        let folder = try Live.scratch("perm")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await Live.repo(in: folder, files: ["README.md": "a scratch repo\n"])
        let session = UUID().uuidString.lowercased()

        // The app's two sockets: hook messages and the control socket the permission hook waits on.
        let hooks = HookServer(path: folder.appendingPathComponent("h.sock").path)
        try hooks.start()
        defer { hooks.stop() }
        let messages = LiveLog<HookMessage>()
        let hookReader = Task { for await message in hooks.messages {
            messages.append(message)
        } }
        defer { hookReader.cancel() }
        let asks = LiveLog<PermissionAsk>()
        let control = ControlServer(path: folder.appendingPathComponent("c.sock").path) { request in
            guard request.method == .permission, let ask = request.permission else { return .failure("not served") }
            asks.append(ask)
            let answer = decision == .deny
                ? PermissionAnswer(.deny, message: "Denied in heed (live check).") : PermissionAnswer(.allow)
            return ControlReply(permission: answer, permissionID: ask.id)
        }
        try control.start()
        defer { control.stop() }

        // heed's hook settings, written where the app writes them, but here; HEED_BIN keeps a copy of each hook's
        // input for the capture before handing it to the real helper.
        let files = try IntegrationFiles(
            directory: folder.appendingPathComponent("support"),
            heedBinary: Live.heedBinary()
        )
        try files.write()
        let tee = folder.appendingPathComponent("heed-tee").path
        let keep = Live.capture.appendingPathComponent("hooks-\(decision.rawValue)").path
        try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        f="\(keep)/$3-$$.json"
        cat > "$f"
        exec "\(files.heedBinary)" "$@" < "$f"
        """.write(toFile: tee, atomically: true, encoding: .utf8)
        chmod(tee, 0o755)

        var environment = Live.cleanEnvironment()
        environment[HeedEnvironment.sessionID] = session
        environment[HeedEnvironment.pane] = "live-pane"
        environment[HeedEnvironment.socket] = hooks.path
        environment[HeedControl.socketVariable] = control.path
        environment[HeedEnvironment.binary] = tee
        let result = try await Live.claude(
            prompt: "Use the Bash tool to run exactly this command, once: touch \(file)\n"
                + "If it is not allowed, do not try anything else; just stop and say so in one line.",
            repo: repo, session: session, files: files, environment: environment
        )
        #expect(result.succeeded, "claude -p ended: \(result.stderr)")
        _ = await Live.eventually(3) { messages.all.contains { $0.kind == .state(.done, reason: nil) } }
        Live.keep("hooks-\(decision.rawValue).txt", messages.all.map { "\($0.kind)" }.joined(separator: "\n"))

        // The ask heed decoded from the hook: the tool, the command, its mode and where, and its tags.
        let ask = try #require(asks.all.first, "the PermissionRequest hook reached heed's control socket")
        #expect(asks.all.count == 1)
        #expect(ask.session == session)
        #expect(ask.pane == "live-pane")
        #expect(ask.agent == "claude")
        #expect(ask.channel == .hook)
        #expect(ask.tool == "Bash")
        #expect(ask.command == "touch \(file)")
        #expect(ask.title == "Run a command")
        #expect(ask.mode == "default")
        #expect(ask.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == repo)
        let tags = PermissionRisk.tags(for: ask, roots: [repo])
        #expect(!tags.contains(.readOnly))
        #expect(!tags.contains(.outsideWorktree))
        #expect(!tags.contains(.network))

        // The hooks around it: the session is claude's own id, blocked on the run while it waited.
        let kinds = messages.all.map(\.kind)
        #expect(kinds.contains(.agentSession(id: session, agent: "claude")))
        #expect(kinds.contains { if case .state(.blocked, _) = $0 { true } else { false } })
        #expect(messages.all.allSatisfy { $0.session == session })

        let ran = FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent(file))
        return (ran, ask)
    }
}
