import Foundation
@testable import HeedCore
import Testing

/// A Browse Chat run against the real Claude Code ACP adapter on haiku: heed makes the temporary worktree in a
/// throwaway repo, starts the agent in it, answers every permission with `BrowsePolicy` (Chat), reads its turn into a
/// `BrowseRun`, and removes the worktree and its branch when the run closes. Nothing leaves the machine but the
/// prompt.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveBrowseTests {
    @Test(.timeLimit(.minutes(5))) func aChatRunReadsRefusesItsEditAndLeavesNothingBehind() async throws {
        let folder = try Live.scratch("browse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repoPath = try await Live.repo(in: folder, files: ["a.py": "def foo():\n    return 1\n\n\nprint(foo())\n"])
        let record = RepoRecord(repo: Repo(org: "acme", name: "live"), path: repoPath, defaultBranch: "main")
        let item = BrowseItem(
            repo: record.repo, number: 7,
            title: ExternalText("What does foo return?", source: .issueTitle, author: .unknown), author: "someone"
        )

        // The worktree heed makes for the run.
        let plan = BrowseWorktree.plan(for: item, defaultBranch: "main", root: folder.path + "/wt", suffix: "5eed01")
        let worktree = try await BrowseWorktree.create(plan, in: record)
        #expect(FileManager.default.fileExists(atPath: worktree + "/a.py"))

        let command = ProcessInfo.processInfo.environment["HEED_LIVE_ACP"]
            ?? "npx -y @agentclientprotocol/claude-agent-acp"
        let adapter = try #require(ACPAgents.chosen(
            HelperSettings(agent: "claude", command: command),
            defaultAgent: "claude"
        ))
        let executable = adapter.executable.contains("/") ? adapter.executable : try Live.which(adapter.executable)
        var environment = Live.cleanEnvironment()
        // Only haiku: the cheapest model, and the only one these checks may use.
        environment["ANTHROPIC_MODEL"] = "claude-haiku-4-5"
        let transport = try RecordingTransport(ACPProcessTransport(
            executable: executable, arguments: adapter.arguments, directory: worktree, environment: environment
        ))
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Live.keep("browse-chat.jsonl", transport.log.all.joined(separator: "\n")) }
        _ = try await client.initialize(clientVersion: "live")
        let session = try await client.newSession(cwd: worktree, timeout: .seconds(120))
        // Manual mode asks before each edit or command: that is what the policy answers.
        _ = try await client.request(
            "session/set_mode", ["sessionId": .string(session), "modeId": "default"], timeout: .seconds(30)
        )

        let box = RunBox(BrowseRun(
            item: item, verb: .chat, agent: "claude", adapter: adapter.title, name: plan.name, branch: plan.branch,
            worktree: worktree, phase: .working, startedAt: Date(), cap: 0
        ))
        let context = BrowsePolicy.Context(
            verb: .chat, worktree: worktree, repo: record.repo, defaultBranch: "main",
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
        let asked = LiveLog<(call: ACPToolCall, answer: BrowsePolicy.Answer)>()
        let reader = Task {
            for await event in client.events {
                switch event {
                case let .update(_, update):
                    box.mutate { $0.apply(update, at: Date()) }
                case let .permission(id, _, request):
                    let answer = BrowsePolicy.answer(request, context)
                    asked.append((request.toolCall, answer))
                    if let why = answer.refusal {
                        box.mutate { $0.refused(
                            request.toolCall.command ?? request.toolCall.title ?? "a tool",
                            why: why,
                            at: Date()
                        ) }
                    }
                    await client.answerPermission(id, optionID: answer.optionID)
                case .closed:
                    return
                }
            }
        }

        let prompt = BrowseRunPrompt.start(
            box.value, item: item,
            place: BrowseRunPrompt.Place(worktree: worktree, branch: plan.branch, defaultBranch: "main")
        ) + "\n\nThis is a test of heed. Read a.py and say what foo returns. Then, to check that heed's refusal "
            + "works, try to create the file notes.txt with your file edit tool; if you are refused, say so in one "
            + "sentence. Run no commands."
        let stop = try await client.prompt(sessionID: session, text: prompt)
        #expect(stop == .endTurn)
        try await Task.sleep(for: .seconds(1))
        await client.close()
        reader.cancel()

        var run = box.value
        _ = run.apply(.turnEnded(stop, cancel: nil, connected: true), at: Date())
        #expect(run.phase == .done(.endTurn))
        let lines = BrowseFeed.lines(run.story.feed)
        Live.keep(
            "browse-chat-feed.txt",
            lines.map { "\($0.kind.rawValue): \($0.text) \($0.detail ?? "")" }.joined(separator: "\n")
        )
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.kind == .read }, "it read a.py: \(lines.map(\.text))")
        let said = lines.filter { $0.kind == .said }.map(\.text).joined(separator: " ")
        #expect(said.contains("1"), "it said what foo returns: \(said)")

        // Chat never edits: the file is not there, and a refusal, if it tried, is in the feed.
        #expect(!FileManager.default.fileExists(atPath: worktree + "/notes.txt"), "the edit was refused")
        #expect(try String(contentsOfFile: worktree + "/a.py", encoding: .utf8).contains("def foo"))
        let edits = asked.all.filter { [.edit, .delete, .move].contains($0.call.kind ?? .other) }
        #expect(edits.allSatisfy { $0.answer.refusal != nil }, "every edit it asked for was refused")
        #expect(
            !edits.isEmpty,
            "it tried the edit the test asked for; asked: \(asked.all.map { $0.call.kind?.rawValue ?? "?" })"
        )
        #expect(lines.contains { $0.kind == .refused } == !edits.isEmpty)

        // Closing removes the worktree and its branch, and nothing else.
        await BrowseWorktree.remove(path: worktree, branch: plan.branch, in: record)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        let branches = try await ProcessRunner.output(
            "git", ["-C", repoPath, "for-each-ref", "--format=%(refname:short)", "refs/heads/"], caller: "live.browse"
        )
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }
}

final class RunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var run: BrowseRun

    init(_ run: BrowseRun) { self.run = run }

    func mutate(_ body: (inout BrowseRun) -> Void) { lock.withLock { body(&run) } }
    var value: BrowseRun { lock.withLock { run } }
}
