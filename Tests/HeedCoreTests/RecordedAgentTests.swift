import Foundation
@testable import HeedCore
import Testing

/// What the real agents sent in the live checks (`mise run live`), kept in Fixtures/live with personal details
/// scrubbed, and read by heed as the app reads them: Claude Code's ACP adapter (0.107.0) through a helper's turn,
/// Claude Code's (2.1.319) permission hook input, and its OpenTelemetry.
struct RecordedAgentTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/live"))
        return try Data(contentsOf: url)
    }

    // MARK: ACP: a helper's turn

    /// The adapter's messages as heed's client hands them on: updates to the helper, permissions asked and allowed.
    static func helperTurn(worktree: String) throws -> (run: HelperRun, messages: [JSONValue]) {
        let text = try String(decoding: fixture("acp-claude-helper.jsonl"), as: UTF8.self)
        let messages = text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        var run = HelperRun(
            kind: .green, ref: PullRef(repo: Repo(org: "acme", name: "live"), number: 1), title: "live",
            agent: "claude", adapter: "claude via ACP", sessionID: nil, prBranch: "main", branch: "main",
            worktree: worktree, startedAt: Date(timeIntervalSince1970: 0), cap: 0
        )
        let at = Date(timeIntervalSince1970: 1)
        for message in messages {
            switch message["method"]?.string {
            case ACP.Method.sessionUpdate:
                if let update = message["params"]?["update"].flatMap(ACPUpdate.init) { run.apply(update, at: at) }
            case ACP.Method.requestPermission:
                let request = try #require(message["params"].flatMap(ACPPermissionRequest.init))
                run.ask(request, id: message["id"] ?? .null, at: at)
                #expect(run.permission?.title == "Edit a.py")
                run.answered("allowed")
            default: break
            }
        }
        return (run, messages)
    }

    @Test func aHelperReadsTheAdaptersRealTurn() throws {
        // heed's worktree is /tmp/…; the agent names it /private/tmp/…, as macOS resolves it.
        let (run, messages) = try Self.helperTurn(worktree: "/tmp/heed-live-acp/repo")
        let info = try ACPAgentInfo(#require(messages.first?["result"]))
        #expect(info.protocolVersion == 1)
        #expect(info.name == "Claude Agent")
        #expect(info.version == "0.107.0")
        #expect(messages.last?["result"]?["stopReason"]?.string.flatMap(ACPStopReason.init(rawValue:)) == .endTurn)

        let tools = run.recentTools(10)
        #expect(tools.map(\.title) == ["Read a.py", "Edit a.py", "Edit a.py"])
        #expect(tools.map(\.kind) == [.read, .edit, .edit])
        #expect(tools.allSatisfy { $0.status == .completed && $0.paths == ["a.py"] })
        #expect(tools[0].output?.hasPrefix("1\tdef foo():") == true, "the Read's output, without its fence")
        #expect(tools[1].diffs.map(\.path) == ["a.py"])
        #expect(tools[1].diffs.first?.lines.contains { $0.kind == .added && $0.text == "def bar():" } == true)
        #expect(tools[2].diffs.first?.lines.contains { $0.kind == .added && $0.text == "print(bar())" } == true)
        #expect(run.files == [HelperFile(path: "a.py", added: 2, removed: 2)])

        #expect(run.approvals == 2)
        #expect(run.feed.filter { if case .permission = $0.body { true } else { false } }.map(\.body) == [
            .permission(title: "Edit a.py", answer: "allowed"), .permission(title: "Edit a.py", answer: "allowed"),
        ])
        #expect(run.usage == HelperUsage(tokens: 25405, window: 1_000_000, cost: 0.00376304))

        let message = run.feed.reversed().lazy.compactMap { entry -> String? in
            if case let .message(text) = entry.body { return text }
            return nil
        }.first ?? ""
        let closeOut = HelperPrompt.closeOut(message)
        #expect(closeOut.did == ["renamed foo to bar"])
        #expect(closeOut.summary.hasPrefix("I renamed `foo` to `bar`"))
    }

    @Test func pathsAreShownRelativeToTheHelpersWorktree() {
        var run = HelperRun(
            kind: .green, ref: PullRef(repo: Repo(org: "o", name: "r"), number: 1), title: "t", agent: "claude",
            adapter: "claude via ACP", sessionID: nil, prBranch: "b", branch: "heed/b", worktree: "/w/heed/r/green-b",
            startedAt: Date(), cap: 0
        )
        #expect(run.local("/w/heed/r/green-b/src/a.cs") == "src/a.cs")
        #expect(run.local("/private/w/heed/r/green-b/src/a.cs") == "src/a.cs")
        #expect(run.local("/w/heed/r/green-b") == ".")
        // Not in it: a sibling with the same prefix, and anything elsewhere.
        #expect(run.local("/w/heed/r/green-bb/a.cs") == "/w/heed/r/green-bb/a.cs")
        #expect(run.local("/etc/hosts") == "/etc/hosts")

        run.apply(.toolCall(ACPToolCall(
            id: "t", title: "Edit /w/heed/r/green-b/src/a.cs", kind: .edit, status: .pending,
            content: [.diff(path: "/w/heed/r/green-b/src/a.cs", oldText: "a", newText: "b")],
            paths: ["/w/heed/r/green-b/src/a.cs"]
        )), at: Date())
        let tool = run.recentTools(1).first
        #expect(tool?.title == "Edit src/a.cs")
        #expect(tool?.paths == ["src/a.cs"])
        #expect(tool?.diffs.map(\.path) == ["src/a.cs"])
        #expect(run.files.map(\.path) == ["src/a.cs"])

        // A worktree heed does not know yet (still starting) leaves paths as they came.
        run.worktree = ""
        #expect(run.local("/w/heed/r/green-b/src/a.cs") == "/w/heed/r/green-b/src/a.cs")
    }

    @Test func toolOutputLosesItsMarkdownFence() {
        #expect(HelperRun.unfenced("```\n1\tdef foo():\n2\t    return 1\n```") == "1\tdef foo():\n2\t    return 1")
        #expect(HelperRun.unfenced("```swift\nlet a = 1\n```\n") == "let a = 1")
        // An opening fence with no close keeps what follows; text with no fence is as it was.
        #expect(HelperRun.unfenced("```\nhalf") == "half")
        #expect(HelperRun.unfenced("ok\n```") == "ok\n```")
    }

    // MARK: Approvals: Claude Code's permission hook input

    @Test func claudesPermissionHookInputIsReadAsAnAsk() throws {
        let input = try Self.fixture("claude-permission-request.json")
        let ask = try #require(PermissionHook.ask(
            ["hook", "claude", "PermissionRequest"], input: input,
            environment: [HeedEnvironment.sessionID: "s1", HeedEnvironment.pane: "p1"], now: Date()
        ))
        #expect(ask.session == "s1")
        #expect(ask.pane == "p1")
        #expect(ask.agent == "claude")
        #expect(ask.subagent == nil)
        #expect(ask.tool == "Bash")
        #expect(ask.command == "touch allowed.txt")
        #expect(ask.why == "Create empty file allowed.txt")
        #expect(ask.mode == "default")
        #expect(ask.cwd == "/private/tmp/heed-live-perm/repo")
        // Its suggestions were a directory and a mode, no allow rule: nothing for "always in this repo".
        #expect(ask.rules.isEmpty)
        #expect(PermissionRisk.tags(for: ask, roots: ["/private/tmp/heed-live-perm/repo"]).isEmpty)
        let allow = try #require(PermissionHook.output(PermissionAnswer(.allow, always: true), for: ask))
        let decision = try #require(
            (JSONSerialization.jsonObject(with: allow) as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        )
        #expect(decision["hookEventName"] as? String == "PermissionRequest")
        #expect((decision["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect((decision["decision"] as? [String: Any])?["updatedPermissions"] == nil)
    }

    // MARK: OpenTelemetry: one `claude -p` turn

    @Test func claudesRealExportsAreReadIntoATurn() throws {
        let session = "c01c2af8-c2e9-465d-9935-12b3c649a316"
        let records = try [
            "claude-otlp-logs-0.json",
            "claude-otlp-logs-1.json",
            "claude-otlp-traces-2.json",
            "claude-otlp-metrics-3.json",
        ]
        .reduce(TelemetryRecords()) { try $0 + TelemetryReader.records(OTLPJSON.decode(Self.fixture($1))) }
        #expect(records.spans.allSatisfy { $0.agent == "claude" && $0.agentSession == session })
        #expect(records.prompts.count == 1)
        #expect(records.prompts.first?.agentSession == session)
        #expect(records.prompts.first?.text == nil, "a redacted prompt is no text")
        // Claude Code exports deltas (temporality 1).
        #expect(records.usage.contains { abs(($0.cost ?? 0) - 0.00232302) < 1e-9 })
        #expect(records.usage.contains { $0.tokens.output == 4 && !$0.cumulative })

        let context = TelemetryContext(
            sessions: [session: .init(title: "live", repo: "live", agent: "claude")], byAgentSession: [session: session]
        )
        let spans = TelemetryResolve.spans(records, context: context)
        #expect(spans.allSatisfy { $0.heedSession == session })
        let turn = try #require(spans.first { $0.kind == .turn })
        #expect(turn.detail == "turn 1")
        // The answer's request: its span, with the cost its event carried, counted once; and Claude Code's own
        // classifier request, which reports no cost.
        let model = spans.filter { $0.kind == .model }
        #expect(model.count == 2)
        let answer = try #require(model.first { $0.key == "req_011Ch2V7P4nuQPNDf3HNhxpz" })
        #expect(!answer.fromEvent)
        #expect(answer.model == "claude-haiku-5-5")
        #expect(abs((answer.cost ?? 0) - 0.00232302) < 1e-9)
        #expect(answer.tokens == TokenCounts(input: 2, output: 4, cacheRead: 11382, cacheWrite: 11035))
        #expect(model.allSatisfy { $0.traceID == turn.traceID })
    }
}
