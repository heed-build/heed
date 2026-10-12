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

struct ScreenGuessTests {
    @Test func commonPromptsAreRecognised() {
        let patterns = ScreenGuess.patterns(for: AgentProfile(name: "x", command: "x"))
        #expect(ScreenGuess.guess("some output\nDo you want to proceed?\n❯ 1. Yes", patterns: patterns) == .blocked)
        #expect(ScreenGuess.guess("✻ Thinking… (esc to interrupt)", patterns: patterns) == .working)
        #expect(ScreenGuess.guess("Error: rate limit reached, retrying", patterns: patterns) == .limited)
        #expect(ScreenGuess.guess("all done\n$ ", patterns: patterns) == nil)
    }

    @Test func onlyTheLastLinesCount() {
        let patterns = ScreenGuess.patterns(for: AgentProfile(name: "x", command: "x"))
        let screen = "Do you want to proceed?\n" + String(repeating: "line\n", count: 20)
        #expect(ScreenGuess.guess(screen, patterns: patterns) == nil)
    }

    @Test func customPatternsReplaceAState() throws {
        let (config, problems) = ConfigLoader.decode("""
        [agents.mytool]
        command = "mytool"
        [agents.mytool.patterns]
        working = "Pondering"
        bogus = "x"
        blocked = "(unclosed"
        """)
        #expect(Set(problems.map(\.path)) == ["agents.mytool.patterns.bogus", "agents.mytool.patterns.blocked"])
        let agent = try #require(config?.work.agent("mytool"))
        let patterns = ScreenGuess.patterns(for: agent)
        #expect(ScreenGuess.guess("Pondering deeply", patterns: patterns) == .working)
        #expect(ScreenGuess.guess("esc to interrupt", patterns: patterns) == nil)
    }
}

struct AgentIntegrationTests {
    private let files = IntegrationFiles(directory: URL(fileURLWithPath: "/s"), heedBinary: "/app/heed")

    private func plan(_ agent: String, prompt: String = "go") -> String? {
        StartWorkPlan(
            prompt: prompt,
            repos: [],
            name: "n",
            agent: AgentProfile.builtIn.first { $0.name == agent },
            sessionID: "S1",
            integration: files
        ).command
    }

    @Test func eachAgentLaunchesWithItsWiring() throws {
        #expect(plan("claude") == "claude --settings /s/claude-hooks.json --session-id S1 go")
        #expect(plan("pi") == "pi -e /s/heed-pi.js --session-id S1 go")
        #expect(plan("gemini") == "gemini --session-id S1 -i go")
        #expect(plan("opencode") ==
            #"OPENCODE_CONFIG_CONTENT='{"plugin":["file:///s/heed-opencode.js"]}' opencode --prompt go"#)
        #expect(plan("cursor") == "cursor-agent go")
        let codex = try #require(plan("codex"))
        #expect(codex.hasPrefix("codex --dangerously-bypass-hook-trust -c "))
        #expect(codex
            .contains(
                #"hooks.PermissionRequest=[{hooks=[{type="command",command="/app/heed hook codex PermissionRequest",timeout=15}]}]"#
            ))
        #expect(codex.hasSuffix(" go"))
    }

    @Test func hookMappingsPerAgent() throws {
        #expect(try HookCommandLine.parse(["hook", "codex", "PermissionRequest"]) {
            Data(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf x"}}"#.utf8)
        } == [.state(.blocked, reason: "Bash(rm -rf x)")])
        #expect(try HookCommandLine.parse(["hook", "codex", "SessionStart"]) { Data(#"{"session_id":"c1"}"#.utf8) }
            .first == .agentSession(id: "c1", agent: "codex"))
        #expect(try HookCommandLine.parse(["hook", "cursor", "stop"]) { Data(#"{"status":"aborted"}"#.utf8) }
            == [.state(.idle, reason: "aborted")])
        #expect(try HookCommandLine.parse(["hook", "pi", "start", "p1", "startup"]) {
            Issue.record("pi must not read stdin")
            return Data()
        } == [.agentSession(id: "p1", agent: "pi"), .state(.idle, reason: "startup")])
        #expect(try HookCommandLine.parse(["hook", "opencode", "session.status", "o1", "retry"]) { Data() }
            == [.state(.limited, reason: "retrying")])
        #expect(try HookCommandLine.parse(["hook", "opencode", "permission.asked", "o1", "bash"]) { Data() }
            == [.state(.blocked, reason: "bash")])
    }

    @Test func cursorHooksGoIntoTheWorktreeAndStayOutOfGit() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("heed-cursor-\(UUID().uuidString)")
            .path
        let worktree = repo + "-wt"
        defer {
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: worktree)
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "t"],
            ["commit", "-q", "--allow-empty", "-m", "first"],
            ["worktree", "add", "-q", "-b", "f", worktree],
        ] {
            _ = try await ProcessRunner.output("git", ["-C", repo] + args)
        }
        try AgentIntegration.installCursorHooks(worktree: worktree, heed: "/app/heed")
        try AgentIntegration.installCursorHooks(worktree: worktree, heed: "/app/heed")
        let hooks = try String(contentsOfFile: worktree + "/.cursor/hooks.json", encoding: .utf8)
        #expect(hooks.contains("/app/heed hook cursor stop"))
        let status = try await Git.status(at: worktree)
        #expect(!status.isDirty)
        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: ".cursor/hooks.json").count == 2)
    }
}
