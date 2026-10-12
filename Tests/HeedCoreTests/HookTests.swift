import Foundation
@testable import HeedCore
import Testing

struct ClaudeHookTests {
    @Test func sessionStartCapturesTheAgentSessionID() {
        let kinds = AgentIntegration.claudeHook(
            event: "SessionStart",
            input: ["session_id": "abc", "source": "startup"]
        )
        #expect(kinds == [.agentSession(id: "abc", agent: "claude"), .state(.idle, reason: "startup")])
    }

    @Test func toolsPermissionsAndQuestions() {
        let bash: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "dotnet publish"]]
        #expect(AgentIntegration.claudeHook(event: "PreToolUse", input: bash) == [.state(
            .working,
            reason: "Bash(dotnet publish)"
        )])
        #expect(AgentIntegration.claudeHook(event: "PermissionRequest", input: bash) == [.state(
            .blocked,
            reason: "Bash(dotnet publish)"
        )])
        let ask: [String: Any] = ["tool_name": "AskUserQuestion", "tool_input": ["questions": [1, 2, 3]]]
        #expect(AgentIntegration.claudeHook(event: "PreToolUse", input: ask) == [.state(
            .asking,
            reason: "3 questions"
        )])
    }

    @Test func notificationsStopsAndLimits() {
        #expect(AgentIntegration
            .claudeHook(event: "Notification", input: ["notification_type": "idle_prompt"]) == [.state(
                .idle,
                reason: nil
            )])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: [:]) == [.state(.done, reason: nil)])
        #expect(AgentIntegration.claudeHook(event: "StopFailure", input: ["error": "rate_limit"]) == [.state(
            .limited,
            reason: "rate limited"
        )])
        #expect(AgentIntegration.claudeHook(event: "SessionEnd", input: ["reason": "exit"]) == [.state(
            .exited,
            reason: "exit"
        )])
        #expect(AgentIntegration.claudeHook(event: "Unknown", input: [:]).isEmpty)
    }

    @Test func hookVerbReadsStdin() throws {
        let kinds = try HookCommandLine.parse(["hook", "claude", "UserPromptSubmit"]) { Data(#"{"prompt":"x"}"#.utf8) }
        #expect(kinds == [.state(.working, reason: "prompt")])
    }

    @Test func settingsAreValidJSONWithEveryEvent() throws {
        let json = try #require(JSONSerialization
            .jsonObject(with: Data(AgentIntegration.claudeSettingsJSON().utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentIntegration.claudeEvents.map(\.event)))
    }

    @Test func claudeLaunchesWithSettingsAndAPreassignedSession() {
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/Heed Support"))
        let plan = StartWorkPlan(
            prompt: "go", repos: [], name: "n", agent: AgentProfile.builtIn[0], sessionID: "S1", integration: files
        )
        #expect(plan.command == "claude --settings '/tmp/Heed Support/claude-hooks.json' --session-id S1 go")
    }

    @Test func pullRefsFromURLs() {
        #expect(PullRef(url: "https://github.com/elastic/docs-builder/pull/2841")
            == PullRef(repo: Repo(org: "elastic", name: "docs-builder"), number: 2841))
        #expect(PullRef(url: "https://github.com/o/r/pull/12/files")?.number == 12)
        #expect(PullRef(url: "https://github.com/o/r/issues/12") == nil)
    }
}

struct HookServerTests {
    @Test func deliversMessagesWrittenToTheSocket() async throws {
        let path = "/tmp/heed-test-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(path: path)
        try server.start()
        defer { server.stop() }

        let first = try HookMessage(session: "s1", kind: .state(.blocked, reason: "Bash")).encodedLine()
        let second = try HookMessage(session: "s1", kind: .title("Renamed")).encodedLine()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = HookServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            ) }
        }
        #expect(connected == 0)
        let payload = first + second
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)

        var received: [HookMessage.Kind] = []
        for await message in server.messages {
            received.append(message.kind)
            if received.count == 2 { break }
        }
        #expect(received == [.state(.blocked, reason: "Bash"), .title("Renamed")])
        #expect(throws: HookServerError.self) { try HookServer(path: path).start() }
    }
}
