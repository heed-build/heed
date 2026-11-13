import Foundation
@testable import HeedCore
import Testing

struct PermissionAskTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func claudeBashCarriesItsCommandModeReasonAndRules() throws {
        let input: [String: Any] = [
            "tool_name": "Bash", "permission_mode": "default", "cwd": "/w/docs",
            "tool_input": ["command": "rm -rf node_modules", "description": "Remove node_modules"],
            "permission_suggestions": [
                [
                    "type": "addRules",
                    "behavior": "allow",
                    "destination": "localSettings",
                    "rules": [["toolName": "Bash", "ruleContent": "rm -rf node_modules"]],
                ],
                ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
            ],
        ]
        let ask = try #require(PermissionAsk.from(hook: input, agent: "claude", session: "s1", pane: "p", id: "a"))
        #expect(ask.command == "rm -rf node_modules")
        #expect(ask.why == "Remove node_modules")
        #expect(ask.mode == "default")
        #expect(ask.cwd == "/w/docs")
        #expect(ask.rules == [PermissionRule(toolName: "Bash", ruleContent: "rm -rf node_modules")])
        #expect(ask.title == "Run a command")
        #expect(ask.subagent == nil)
    }

    @Test func codexPatchNamesItsFiles() throws {
        let patch = "*** Begin Patch\n*** Update File: /etc/x.toml\n-a\n+b\n*** Add File: new.txt\n+hi\n*** End Patch"
        let input: [String: Any] = [
            "tool_name": "apply_patch", "tool_input": ["command": patch, "description": "needs a bigger queue"],
        ]
        let ask = try #require(PermissionAsk.from(hook: input, agent: "codex", session: "s3", pane: nil))
        #expect(ask.paths == ["/etc/x.toml", "new.txt"])
        #expect(ask.why == "needs a bigger queue")
        #expect(ask.title == "Edit 2 files")
        #expect(ask.patch?.contains("+b") == true)
    }

    @Test func anEditIsShownAsRemovedAndAddedLines() throws {
        let input: [String: Any] = [
            "tool_name": "Edit", "tool_input": ["file_path": "/w/a.cs", "old_string": "x = 1", "new_string": "x = 2"],
        ]
        let ask = try #require(PermissionAsk.from(hook: input, agent: "claude", session: "s", pane: nil))
        #expect(ask.patch == "- x = 1\n+ x = 2")
        #expect(ask.paths == ["/w/a.cs"])
    }

    /// Questions to you reach the permission flow too (Claude runs PermissionRequest for AskUserQuestion and
    /// ExitPlanMode), but they are not approvals: told apart by the tool's name.
    @Test func questionsAreNeverAsks() {
        for tool in ["AskUserQuestion", "ExitPlanMode", "request_user_input"] {
            let input: [String: Any] = ["tool_name": tool, "tool_input": ["questions": [1]]]
            #expect(PermissionAsk.from(hook: input, agent: "claude", session: "s", pane: nil) == nil)
            #expect(AgentIntegration.claudeHook(event: "PermissionRequest", input: input) == [])
            #expect(AgentIntegration.codexHook(event: "PermissionRequest", input: input) == [])
        }
        let notice: [String: Any] = [
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use AskUserQuestion",
        ]
        #expect(AgentIntegration.claudeHook(event: "Notification", input: notice) == [.state(
            .asking, reason: "Claude needs your permission to use AskUserQuestion"
        )])
        let bash: [String: Any] = ["notification_type": "permission_prompt", "message": "permission to use Bash"]
        #expect(AgentIntegration.claudeHook(event: "Notification", input: bash) == [.state(
            .blocked, reason: "permission to use Bash"
        )])
    }

    @Test func aBlockedSessionsReasonReadsAsAScreenAsk() {
        var session = Session(
            id: "s6", title: "t", repos: [], branch: "b", agent: "opencode",
            state: ObservedState(.blocked, reason: "bash(git push -u origin x)")
        )
        session.lastActivity = now
        let ask = PermissionAsk.screen(session, now: now)
        #expect(ask.channel == .screen)
        #expect(ask.command == "git push -u origin x")
        session.state = ObservedState(.blocked, reason: "edit")
        #expect(PermissionAsk.screen(session, now: now).tool == "edit")
    }

    @Test func permissionHooksWaitLongerThanTheRest() throws {
        let json = try #require(JSONSerialization
            .jsonObject(with: Data(AgentIntegration.claudeSettingsJSON().utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        let timeout = { (event: String) in
            ((hooks[event]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"]) as? Int
        }
        #expect(timeout("PermissionRequest") == PermissionHook.hookTimeout)
        #expect(timeout("Stop") == 15)
        let codex = AgentIntegration.codexArguments(heed: "/h").joined(separator: " ")
        #expect(codex.contains("hook codex PermissionRequest\",timeout=\(PermissionHook.hookTimeout)}"))
        #expect(Double(PermissionHook.maxWait) < PermissionHook.ceiling)
        #expect(PermissionHook.ceiling < Double(PermissionHook.hookTimeout))
    }
}

struct PermissionRiskTests {
    private func tags(_ command: String, cwd: String = "/w/repo") -> [PermissionRisk] {
        let ask = PermissionAsk(
            id: "a",
            session: "s",
            agent: "claude",
            tool: "Bash",
            command: command,
            cwd: cwd,
            askedAt: Date()
        )
        return PermissionRisk.tags(for: ask, roots: ["/w/repo"], home: "/Users/me")
    }

    @Test func readOnlyOnlyWhenEveryPartReads() {
        #expect(tags("git log --oneline -20") == [.readOnly])
        #expect(tags("ls -la && git status | head") == [.readOnly])
        #expect(tags("rg anchor src 2>/dev/null") == [.readOnly])
        #expect(tags("cat a > b") == [])
        #expect(tags("ls && rm -rf build") == [])
        #expect(tags("echo $(rm x)") == [])
        #expect(tags("find . -name '*.tmp' -delete") == [])
        #expect(tags("sed -i '' s/a/b/ f") == [])
        #expect(tags("cargo test") == [])
    }

    @Test func networkAndGitHubWrites() {
        #expect(tags("curl -sI https://example.com") == [.network])
        #expect(tags("git push origin main") == [.writesGitHub, .network])
        #expect(tags("gh pr create --fill") == [.writesGitHub, .network])
        #expect(tags("gh pr view 12") == [.network, .readOnly])
        #expect(tags("gh api repos/o/r/pulls") == [.network, .readOnly])
        #expect(tags("gh api -X POST repos/o/r/issues -f title=x") == [.writesGitHub, .network])
        #expect(tags("npm install left-pad") == [.network])
        #expect(tags("git fetch") == [.network])
    }

    @Test func pathsOutsideTheWorktree() {
        #expect(tags("cat ~/.ssh/config") == [.outsideWorktree, .readOnly])
        #expect(tags("cat /w/repo/README.md") == [.readOnly])
        #expect(tags("cd ../other && ls") == [.outsideWorktree, .readOnly])
        #expect(tags("ls >/dev/null") == [.readOnly])
        let edit = PermissionAsk(
            id: "e",
            session: "s",
            agent: "codex",
            tool: "apply_patch",
            paths: ["docker-compose.yml", "~/.config/x.toml"],
            cwd: "/w/repo",
            askedAt: Date()
        )
        #expect(PermissionRisk.tags(for: edit, roots: ["/w/repo"], home: "/Users/me") == [.outsideWorktree])
        let inside = PermissionAsk(
            id: "e",
            session: "s",
            agent: "codex",
            tool: "apply_patch",
            paths: ["src/a.swift"],
            cwd: "/w/repo",
            askedAt: Date()
        )
        #expect(PermissionRisk.tags(for: inside, roots: ["/w/repo"], home: "/Users/me") == [])
        // A sibling whose name starts like the root is still outside.
        #expect(tags("cat /w/repo-old/x") == [.outsideWorktree, .readOnly])
    }

    @Test func toolsTagThemselves() {
        let fetch = PermissionAsk(
            id: "f",
            session: "s",
            agent: "claude",
            tool: "WebFetch",
            url: "https://x.y",
            askedAt: Date()
        )
        #expect(PermissionRisk.tags(for: fetch, roots: ["/w"]) == [.network, .readOnly])
        let pr = PermissionAsk(
            id: "g",
            session: "s",
            agent: "claude",
            tool: "mcp__github__create_pull_request",
            askedAt: Date()
        )
        #expect(PermissionRisk.tags(for: pr, roots: ["/w"]) == [.writesGitHub, .network])
    }
}

struct ApprovalQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ask(_ id: String, _ session: String, _ command: String, ago: TimeInterval) -> PermissionAsk {
        PermissionAsk(
            id: id,
            session: session,
            agent: "claude",
            tool: "Bash",
            command: command,
            askedAt: now.addingTimeInterval(-ago)
        )
    }

    @Test func oldestFirstWithIdenticalAsksMerged() {
        var queue = ApprovalQueue()
        queue.add(ask("b", "s2", "curl x", ago: 10))
        queue.add(ask("a", "s1", "git log", ago: 40))
        queue.add(ask("c", "s3", "curl x", ago: 5))
        let groups = queue.groups()
        #expect(groups.map(\.first.id) == ["a", "b"])
        #expect(groups[1].asks.map(\.id) == ["b", "c"])
        #expect(groups[1].title == "Run a command (2 agents)")
        #expect(groups[0].waited(now) == "40 s")
        #expect(ApprovalSummary(groups).text == "2 asks from 3 agents")
    }

    @Test func anAnswerIsRememberedAndAPassIsNot() {
        var queue = ApprovalQueue(asks: [ask("a", "s1", "rm x", ago: 1)])
        queue.record(.pass, for: queue.asks, at: now)
        #expect(!queue.deniedBefore(queue.asks[0].key))
        queue.record(.deny, for: queue.asks, at: now)
        #expect(queue.groups()[0].deniedBefore)
        #expect(queue.remove(["a"]).map(\.id) == ["a"])
        #expect(queue.isEmpty)
    }

    @Test func theAgentMovingOnSettlesOnlyItsOwnAsks() {
        let queue = ApprovalQueue(asks: [ask("a", "s1", "git log", ago: 1), ask("b", "s2", "git log", ago: 1)])
        #expect(queue.settled(by: .toolCall(ToolCall(tool: "Bash", input: "git log")), session: "s1") == ["a"])
        #expect(queue.settled(by: .toolCall(ToolCall(tool: "Bash", input: "ls")), session: "s1") == [])
        #expect(queue.settled(by: .state(.done, reason: nil), session: "s2") == ["b"])
        #expect(queue.settled(by: .state(.working, reason: "prompt"), session: "s1") == ["a"])
        #expect(queue.settled(by: .state(.working, reason: "Bash(ls)"), session: "s1") == [])
        #expect(queue.settled(by: .state(.blocked, reason: "Bash(git log)"), session: "s1") == [])
    }

    @Test func blockedSessionsWithoutAHookAskAreScreenAsks() {
        let blocked = Session(
            id: "s1",
            title: "t",
            repos: [],
            branch: "b",
            agent: "claude",
            state: ObservedState(.blocked, reason: "Bash(ls)")
        )
        var other = blocked
        other.id = "s2"
        let queue = ApprovalQueue(asks: [ask("a", "s2", "ls", ago: 1)])
        let screen = queue.screenAsks([blocked, other], now: now)
        #expect(screen.map(\.session) == ["s1"])
        let groups = queue.groups(screen: screen)
        #expect(groups.count == 2)
        #expect(groups.first { $0.first.channel == .screen }?.answerable == false)
        #expect(groups.first { $0.first.channel == .hook }?.answerable == true)
    }

    @Test func theFakeWorldHasFiveAsksFromFourAgents() {
        let now = Clock.now
        let domain = Fixtures.approvals
        let queue = ApprovalQueue(asks: Fixtures.approvalAsks(now: now))
        let groups = queue.groups(screen: queue.screenAsks(domain.sessions, now: now)) { id in
            guard let session = domain.sessions.first(where: { $0.id == id }) else { return [] }
            return domain.worktrees.filter { session.owns($0) }.map(\.path)
        }
        #expect(ApprovalSummary(groups).text == "5 asks from 4 agents")
        #expect(groups.first?.tags == [.outsideWorktree])
        #expect(groups.contains { $0.tags == [.writesGitHub, .network] && !$0.answerable })
        #expect(groups.filter(\.safeRead).count == 1)
    }
}

struct PermissionHookTests {
    private let ask = PermissionAsk(
        id: "ask-1", session: "s1", agent: "claude", tool: "Bash", command: "npm test", askedAt: Date(),
        rules: [PermissionRule(toolName: "Bash", ruleContent: "npm test")]
    )

    private func decision(_ data: Data?) throws -> [String: Any] {
        let json = try #require(data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        let output = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }

    @Test func outputsAsEachAgentReadsThem() throws {
        #expect(PermissionHook.output(.pass, for: ask) == nil)
        let allow = try decision(PermissionHook.output(PermissionAnswer(.allow), for: ask))
        #expect(allow["behavior"] as? String == "allow")
        #expect(allow["updatedPermissions"] == nil)
        let deny = try decision(PermissionHook.output(PermissionAnswer(.deny, message: "not now"), for: ask))
        #expect(deny["behavior"] as? String == "deny")
        #expect(deny["message"] as? String == "not now")
        let always = try decision(PermissionHook.output(PermissionAnswer(.allow, always: true), for: ask))
        let update = try #require((always["updatedPermissions"] as? [[String: Any]])?.first)
        #expect(update["destination"] as? String == "localSettings")
        #expect(update["type"] as? String == "addRules")
        #expect((update["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String == "npm test")
        // Codex fails closed on updatedPermissions: never sent.
        var codex = ask
        codex.agent = "codex"
        let codexAlways = try decision(PermissionHook.output(PermissionAnswer(.allow, always: true), for: codex))
        #expect(codexAlways["updatedPermissions"] == nil)
    }

    @Test func onlyPermissionHooksInAHeedPaneAsk() {
        let input = Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        let env = [HeedEnvironment.sessionID: "s1", HeedEnvironment.pane: "p1"]
        #expect(PermissionHook.ask(["hook", "claude", "PermissionRequest"], input: input, environment: env)?
            .pane == "p1")
        #expect(PermissionHook.ask(["hook", "codex", "PermissionRequest"], input: input, environment: env) != nil)
        #expect(PermissionHook.ask(["hook", "claude", "PreToolUse"], input: input, environment: env) == nil)
        #expect(PermissionHook.ask(["hook", "cursor", "PermissionRequest"], input: input, environment: env) == nil)
        #expect(PermissionHook.ask(["hook", "claude", "PermissionRequest"], input: input, environment: [:]) == nil)
    }

    private static func path() -> String { "/tmp/heed-perm-\(UUID().uuidString.prefix(8)).sock" }

    @Test func theAnswerComesBackOnTheConnectionThatAsked() async throws {
        let path = Self.path()
        let server = ControlServer(path: path) { request in
            guard request.method == .permission, let ask = request.permission else { return .failure("no") }
            try? await Task.sleep(for: .milliseconds(50))
            return ControlReply(
                permission: PermissionAnswer(.deny, message: "for \(ask.session)"),
                permissionID: ask.id
            )
        }
        try server.start()
        defer { server.stop() }
        let ask = ask
        let answer = try await onThread { PermissionHook.wait(for: ask, socket: path, ceiling: 5) }
        #expect(answer == PermissionAnswer(.deny, message: "for s1"))
    }

    @Test func anythingButItsOwnAnswerIsAPass() async throws {
        let path = Self.path()
        let server = ControlServer(path: path) { _ in
            ControlReply(permission: PermissionAnswer(.allow), permissionID: "someone-else")
        }
        try server.start()
        let ask = ask
        #expect(try await onThread { PermissionHook.wait(for: ask, socket: path, ceiling: 5) } == .pass)
        server.stop()
        // heed not running: a pass at once.
        #expect(try await onThread { PermissionHook.wait(for: ask, socket: path, ceiling: 5) } == .pass)
    }

    @Test func aSlowAnswerTimesOutAndTheServerHearsTheHookLeft() async throws {
        let path = Self.path()
        let gone = Gone()
        let server = ControlServer(path: path) { _ in
            try? await Task.sleep(for: .seconds(3))
            return ControlReply(permission: PermissionAnswer(.allow), permissionID: "ask-1")
        }
        server.permissionGone = { id in gone.add(id) }
        try server.start()
        defer { server.stop() }
        let ask = ask
        let started = Date()
        #expect(try await onThread { PermissionHook.wait(for: ask, socket: path, ceiling: 0.3) } == .pass)
        // Well under the server's 3 s answer: the hook gave up at its ceiling (CI machines can be slow to get there).
        #expect(Date().timeIntervalSince(started) < 2.9)
        try await Task.sleep(for: .milliseconds(200))
        #expect(gone.ids == ["ask-1"])
    }

    @Test func waitIsConfiguredWithinItsCeiling() {
        #expect(ConfigLoader.decode("").config?.approvals.waitSeconds == 120)
        #expect(ConfigLoader.decode("[approvals]\nwait_seconds = 0\n").config?.approvals.waitSeconds == 0)
        let refused = ConfigLoader.decode("[approvals]\nwait_seconds = 999\n")
        #expect(refused.problems.map(\.path) == ["approvals.wait_seconds"])
        #expect(refused.config?.approvals.waitSeconds == 120)
    }
}

private final class Gone: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ id: String) { lock.withLock { list.append(id) } }
    var ids: [String] { lock.withLock { list } }
}

private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}
