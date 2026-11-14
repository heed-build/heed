import Foundation
@testable import HeedCore
import Testing

/// A helper against the real Claude Code ACP adapter: heed's `ACPClient` starts it, opens a session in a throwaway
/// repo, prompts it, answers its permission, and reads its turn into a `HelperRun` and its close-out, as the app does.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveACPTests {
    @Test(.timeLimit(.minutes(5))) func aHelperRenamesAFunctionThroughTheClaudeAdapter() async throws {
        let folder = try Live.scratch("acp")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await Live.repo(in: folder, files: ["a.py": "def foo():\n    return 1\n\n\nprint(foo())\n"])
        let base = await HelperGit.head(repo)

        // The adapter heed would pick, with `[helpers] command` as the docs suggest for npx (or HEED_LIVE_ACP).
        let command = ProcessInfo.processInfo.environment["HEED_LIVE_ACP"]
            ?? "npx -y @agentclientprotocol/claude-agent-acp"
        let adapter = try #require(ACPAgents.chosen(
            HelperSettings(agent: "claude", command: command),
            defaultAgent: "claude"
        ))
        let executable = adapter.executable.contains("/") ? adapter.executable : try Live.which(adapter.executable)
        var environment = Live.cleanEnvironment()
        environment["ANTHROPIC_MODEL"] = Live.model
        let process = try ACPProcessTransport(
            executable: executable, arguments: adapter.arguments, directory: repo, environment: environment
        )
        let transport = RecordingTransport(process)
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Live.keep("acp.jsonl", transport.log.all.joined(separator: "\n")) }

        let info = try await client.initialize(clientVersion: "live")
        #expect(info.protocolVersion == 1)
        let session = try await client.newSession(cwd: repo, timeout: .seconds(120))
        #expect(!session.isEmpty)
        // Claude's adapter starts a session in Claude Code's auto mode unless your settings name another, and auto
        // asks nothing. Manual (`default`) asks before each edit: that is the permission round trip under test.
        _ = try await client.request(
            "session/set_mode", ["sessionId": .string(session), "modeId": "default"], timeout: .seconds(30)
        )

        // The helper as the app keeps it: every update applied, a permission asked and allowed once.
        let helper = HelperBox(HelperRun(
            kind: .green, ref: PullRef(repo: Repo(org: "acme", name: "live"), number: 1), title: "live",
            agent: "claude", adapter: adapter.title, sessionID: nil, prBranch: "main", branch: "main",
            worktree: repo, startedAt: Date(), cap: 0
        ))
        let asked = LiveLog<ACPPermissionRequest>()
        let updates = LiveLog<ACPUpdate>()
        let reader = Task {
            for await event in client.events {
                switch event {
                case let .update(_, update):
                    updates.append(update)
                    helper.mutate { $0.apply(update, at: Date()) }
                case let .permission(id, _, request):
                    asked.append(request)
                    helper.mutate { $0.ask(request, id: id, at: Date()) }
                    let allow = request.option(.allowOnce) ?? request.options.first { $0.kind == .allowAlways }
                    await client.answerPermission(id, optionID: allow?.id)
                    helper.mutate { $0.answered("allowed") }
                case .closed:
                    return
                }
            }
        }

        let stop = try await client.prompt(sessionID: session, text: """
        In a.py, rename the function foo to bar, including where it is called. Use your file edit tool, change \
        nothing else and run no commands. When done, end your reply with exactly this line:
        heed-did: renamed foo to bar
        """)
        #expect(stop == .endTurn)
        // Updates sent just before the prompt's answer are in by now.
        try await Task.sleep(for: .seconds(1))
        await client.close()
        reader.cancel()

        let run = helper.value
        let text = try String(contentsOfFile: (repo as NSString).appendingPathComponent("a.py"), encoding: .utf8)
        #expect(text.contains("def bar("), "the agent edited the file")
        #expect(!text.contains("foo"))

        // Tool calls: titled, with a diff of a.py heed draws as lines out and in.
        let tools = run.recentTools(20)
        Live.keep(
            "acp-helper.txt",
            "\(run.feed.map(\.body))\n\nplan: \(run.plan)\nusage: \(run.usage)\nfiles: \(run.files)"
        )
        #expect(!tools.isEmpty, "tool calls reached the feed")
        #expect(tools.allSatisfy { $0.title != "a tool call" && !$0.title.isEmpty }, "every tool call has a title")
        #expect(tools.allSatisfy { !$0.title.contains(repo) && !$0.title.contains("/private/") }, "titles name a.py")
        #expect(tools.contains { $0.title.hasSuffix(" a.py") })
        #expect(tools.allSatisfy { $0.output?.hasPrefix("```") != true }, "output without its fence")
        let edit = tools.first { !$0.diffs.isEmpty }
        let diff = try #require(edit?.diffs.first, "an edit came with a diff")
        #expect(diff.path == "a.py")
        #expect(diff.added >= 1 && diff.removed >= 1)
        #expect(diff.lines.contains { $0.kind == .added && $0.text.contains("def bar(") })
        #expect(run.files.map(\.path) == ["a.py"])
        #expect(tools.contains { $0.status == .completed })

        // The permissions it asked in manual mode, read with their options and answered.
        #expect(!asked.all.isEmpty, "manual mode asks before an edit")
        for request in asked.all {
            #expect(!request.options.isEmpty)
            #expect(request.option(.allowOnce) != nil)
        }
        #expect(run.permission == nil)
        #expect(run.approvals == asked.all.count)

        // Usage, when the adapter reports it.
        let usage = updates.all.compactMap { update -> (Int, Int, Double?)? in
            if case let .usage(used, size, cost, _) = update { return (used, size, cost) }
            return nil
        }
        if let last = usage.last {
            #expect(last.0 > 0 && last.1 > 0, "context used and window")
            #expect(run.usage.tokens == last.0)
        }

        // The close-out, from its last message and git.
        let message = run.feed.reversed().lazy.compactMap { entry -> String? in
            if case let .message(text) = entry.body { return text }
            return nil
        }.first ?? ""
        let closeOut = HelperPrompt.closeOut(message)
        #expect(closeOut.did.contains { $0.localizedCaseInsensitiveContains("bar") }, "heed-did read: \(message)")
        let changes = await HelperGit.changes(worktree: repo, base: base ?? "HEAD")
        #expect(changes.dirty)
        #expect(changes.files.contains { $0.path == "a.py" })
    }
}

/// The helper under test, changed from the event reader and read at the end.
final class HelperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var run: HelperRun

    init(_ run: HelperRun) { self.run = run }

    func mutate(_ body: (inout HelperRun) -> Void) { lock.withLock { body(&run) } }
    var value: HelperRun { lock.withLock { run } }
}
