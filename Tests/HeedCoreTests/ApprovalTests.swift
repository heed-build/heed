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

    @Test func readOnlyIsNotGivenToWhatRunsOrWritesSomething() {
        // Programs that run another command, and quoted scripts, are never read only.
        for command in [
            "env ls", "env PAGER=x git log", "xargs cat", "nice ls", "time git status", "timeout 5 cat a", "sudo cat a",
            "nohup ls", "watch ls", "command ls", "sh -c 'ls'", "bash -c \"git status\"", "bash -lc ls", "eval ls",
            "exec ls", "source x.sh", ". ./x.sh", "less README.md", "more README.md",
        ] {
            #expect(!tags(command).contains(.readOnly), "\(command)")
        }
        #expect(tags("command -v git") == [.readOnly])
        // Options that write or run.
        for command in [
            "awk '{print > \"out\"}' f", "awk '{print >> \"out\"}' f", "awk '{system(\"rm x\")}' f",
            "awk '{print | \"sh\"}' f", "awk '{getline l < \"/etc/x\"}' f", "awk -f prog.awk f",
            "rg --pre ./x foo", "rg --pre=./x foo", "rg --pre-glob '*.pdf' foo", "fd -x rm", "fd -X rm", "fd --exec rm",
            "fd -tfx rm", "find . -exec rm {} +", "find . -execdir rm {} +", "find . -ok rm {} +", "find . -delete",
            "find . -fprint out", "find . -fls out", "find . -fprintf out x", "sort -o out f", "sort -uo out f",
            "sort --output=out f", "sort --compress-program=x f", "git diff --output=out", "git diff --output out",
            "git log -p --ext-diff", "git -c core.pager=x log", "git grep -O foo", "git grep --open-files-in-pager foo",
            "git reflog expire --all", "sed -i '' s/a/b/ f", "sed -i.bak s/a/b/ f", "sed -Ei s/a/b/ f",
            "sed --in-place s/a/b/ f", "sed 'w out' f", "sed 's/a/b/w out' f", "sed 's/a/b/e' f", "sed -n '1e ls' f",
            "sed -f script.sed f", "sed '1a text' f", "tree -o out", "uniq a b", "date 0101000026", "file -C",
            "gh pr checkout 12", "gh repo clone o/r", "gh run download 1", "/tmp/x/cat a", "./cat a",
            "PAGER=x git log", "GIT_EXTERNAL_DIFF=x git diff",
        ] {
            #expect(!tags(command).contains(.readOnly), "\(command)")
        }
        // What still reads.
        for command in [
            "awk '{print $1}' f", "rg foo src", "fd swift", "find . -name '*.swift'", "sort -u f", "sort -k2 -n f",
            "git diff HEAD~1", "git -C sub log", "git --no-pager log", "sed -n '1,20p' f", "sed 's/a/b/g' f",
            "sed -e 's/a/b/' -e '/x/d' f", "tree -L 2", "uniq -c f", "date +%s", "LC_ALL=C sort f", "/usr/bin/grep x f",
            "file a", "git reflog", "gh release list",
        ] {
            #expect(tags(command).contains(.readOnly), "\(command)")
        }
    }

    @Test func pathsThatClimbOutOfTheWorktree() {
        #expect(tags("cat ../../etc/hosts") == [.outsideWorktree, .readOnly])
        #expect(tags("ls src/../../x") == [.outsideWorktree, .readOnly])
        #expect(tags("rg foo --glob=../x") == [.outsideWorktree, .readOnly])
        #expect(tags("cat src/../README.md") == [.readOnly])
        #expect(tags("cat ../repo/README.md") == [.readOnly])
        #expect(tags("ls ..", cwd: "/w/repo/src") == [.readOnly])
        #expect(tags("ls ..") == [.outsideWorktree, .readOnly])
    }

    @Test func releasesPublishesAndDeploys() {
        for command in [
            "npm publish", "pnpm -r publish --access public", "yarn npm publish", "yarn publish", "bun publish",
            "cargo publish", "dotnet nuget push x.nupkg", "gem push x.gem", "twine upload dist/*", "poetry publish",
            "uv publish", "swift package-registry publish", "gh release create v1", "gh release upload v1 a.zip",
            "gh release edit v1 --draft=false", "git push --tags", "git push origin --follow-tags",
            "git push origin refs/tags/v1", "git push origin tag v1", "git push origin HEAD:refs/tags/v1",
            "docker push ghcr.io/o/i", "podman push i", "docker image push i", "docker buildx build --push .",
            "fly deploy", "flyctl deploy", "vercel --prod", "vercel deploy", "netlify deploy --prod",
            "kubectl apply -f k",
            "kubectl rollout restart deploy/x", "helm upgrade x c", "helm install x c", "terraform apply", "tofu apply",
            "gh workflow run release.yml", "brew bump-formula-pr x", "mise run release", "mise run publish:npm",
            "npm run release", "make deploy", "just release", "sudo npm publish", "env A=1 cargo publish",
            "bash -c 'npm publish'", "timeout 60 docker push i", "cd pkg && npm publish",
        ] {
            #expect(tags(command).contains(.publishes), "\(command)")
            #expect(PermissionRisk.publishes(command), "\(command)")
        }
        for command in [
            "npm install", "npm run build", "cargo build", "git push origin main", "git tag v1", "docker build .",
            "docker pull i", "kubectl get pods", "kubectl rollout status deploy/x", "helm list", "terraform plan",
            "gh release view v1", "gh release list", "gh workflow list", "vercel", "mise run test", "make",
            "brew install x",
            "echo npm publish", "make releases-notes",
        ] {
            #expect(!tags(command).contains(.publishes), "\(command)")
        }
        // Worst first, and still with the tags it had.
        #expect(tags("gh release create v1") == [.publishes, .writesGitHub, .network])
        #expect(PermissionRisk.tags(forCommand: "git push --tags") == [.publishes, .writesGitHub, .network])
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

struct PublishAskTests {
    @Test func alwaysIsNeverOfferedForAPublish() {
        func group(_ command: String) -> ApprovalGroup {
            let ask = PermissionAsk(
                id: command, session: "s1", agent: "claude", tool: "Bash", command: command, askedAt: Date(),
                rules: [PermissionRule(toolName: "Bash", ruleContent: command)]
            )
            return ApprovalQueue(asks: [ask]).groups { _ in ["/w/repo"] }[0]
        }
        #expect(group("npm test").canAlways)
        let publish = group("npm publish")
        #expect(publish.tags.first == .publishes)
        #expect(!publish.canAlways)
        #expect(publish.answerable)
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
        // Timed on the hook's own thread: how long the hook took, not how long the test took to be resumed.
        let (answer, took) = try await onThread {
            let started = ContinuousClock.now
            let answer = PermissionHook.wait(for: ask, socket: path, ceiling: 0.3)
            return (answer, ContinuousClock.now - started)
        }
        #expect(answer == .pass)
        // The hook gave up at its ceiling, a hard deadline, well before the server's 3 s answer.
        #expect(took < .milliseconds(800))
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
