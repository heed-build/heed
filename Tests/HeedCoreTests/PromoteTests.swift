import Foundation
@testable import HeedCore
import Testing

/// `chat.promote`: a chat becomes work in a worktree, and its conversation goes along: resumed for claude, a handoff
/// prompt for every other agent.
struct PromoteTests {
    private let records = ["docs-toolkit", "markgraph"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func promotion(
        agent: String = "claude", resume: String? = "c1d2", kind: ChatFolder.Kind = .scratch,
        files: [String] = ["crontab.txt", "notes.md"]
    ) -> Promotion {
        Promotion(
            chatID: "c", chatTitle: "Cron line for weekdays", chatAgent: agent, resumeID: resume,
            folder: ChatFolder(kind, path: "/chats/2026-10-21-cron"),
            transcript: resume.map { "/home/.claude/projects/-chats-2026-10-21-cron/\($0).jsonl" },
            prompts: ["What cron line runs at nine on weekdays?", "And only in October?"], files: files
        )
    }

    private func agent(_ name: String) -> AgentProfile? { AgentProfile.builtIn.first { $0.name == name } }

    // MARK: The prompts

    @Test func theHandoffPromptCarriesTheTranscriptThePromptsAndTheFiles() {
        let text = Handoff.promotion(
            promotion(), task: "Add the nightly job to the deploy scripts", branch: "feature/nightly-job",
            instructions: "Run mise run test first."
        )
        #expect(text.contains("started as a chat with claude (\"Cron line for weekdays\")"))
        #expect(text.contains("on the branch feature/nightly-job"))
        #expect(text.contains("Add the nightly job to the deploy scripts"))
        #expect(text.contains("transcript is /home/.claude/projects/-chats-2026-10-21-cron/c1d2.jsonl"))
        #expect(text.contains("- What cron line runs at nine on weekdays?\n- And only in October?"))
        #expect(text.contains("in /chats/2026-10-21-cron, not copied here: crontab.txt, notes.md"))
        #expect(text.hasSuffix("Run mise run test first."))
        var copied = promotion()
        copied.copyFiles = true
        #expect(Handoff.promotion(copied, task: "", branch: "b").contains("were copied here: crontab.txt"))
        let bare = Handoff.promotion(promotion(resume: nil, files: []), task: "", branch: "b")
        #expect(!bare.contains("transcript"))
        #expect(!bare.contains("files"))
    }

    @Test func aResumedClaudeIsOnlyToldWhereItIsNow() {
        let text = Handoff.promotionResumed(promotion(), task: "Add the job", branch: "feature/job")
        #expect(text.contains("now work in a git worktree, on the branch feature/job"))
        #expect(text.contains("Add the job"))
        #expect(!text.contains("transcript"))
    }

    @Test func onlyClaudeIntoClaudeResumes() {
        #expect(promotion().resuming(with: agent("claude")) == "c1d2")
        #expect(promotion().resuming(with: agent("codex")) == nil)
        #expect(promotion(agent: "codex").resuming(with: agent("claude")) == nil)
        #expect(promotion(resume: nil).resuming(with: agent("claude")) == nil)
    }

    // MARK: Reading the chat

    @Test func aTranscriptsPromptsAreItsUserTurnsWithText() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"What cron line runs at nine?"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"0 9 * * 1-5"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: injected"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"And in October?"}]}}"#,
            "not json",
        ]
        #expect(ClaudeTranscript.prompts(in: lines.joined(separator: "\n"))
            == ["What cron line runs at nine?", "And in October?"])
        let many = (1 ... 20).map { #"{"type":"user","message":{"content":"p\#($0)"}}"# }.joined(separator: "\n")
        let kept = ClaudeTranscript.prompts(in: many, limit: 4)
        // The first says what it was about; then the latest.
        #expect(kept == ["p1", "p18", "p19", "p20"])
        #expect(ClaudeTranscript.path(id: "x", directory: "/a/b.c", home: "/h") == "/h/.claude/projects/-a-b-c/x.jsonl")
    }

    @Test func filesAreListedAndCopiedWithoutOverwriting() throws {
        let root = NSTemporaryDirectory() + "heed-promote-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let chat = root + "/chat", worktree = root + "/wt"
        for folder in [chat, worktree, chat + "/.cursor"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try "a".write(toFile: chat + "/notes.md", atomically: true, encoding: .utf8)
        try "b".write(toFile: chat + "/crontab.txt", atomically: true, encoding: .utf8)
        try "mine".write(toFile: worktree + "/notes.md", atomically: true, encoding: .utf8)
        let files = Promote.files(in: chat)
        #expect(files == ["crontab.txt", "notes.md"])
        #expect(Promote.copy(files, from: chat, to: worktree) == ["crontab.txt"])
        #expect(try String(contentsOfFile: worktree + "/notes.md", encoding: .utf8) == "mine")
        #expect(FileManager.default.fileExists(atPath: worktree + "/crontab.txt"))
    }

    // MARK: The form

    @Test func promotingStartsWorkWithTheChatsAgentAndNoChatChip() {
        var form = StartWorkForm(
            repos: records, settings: .default, prompt: "Add the nightly job to markgraph",
            promotion: promotion(agent: "codex", resume: nil)
        )
        #expect(form.agent?.name == "codex")
        #expect(form.selectedRepos == ["o/markgraph"])
        _ = form.handle(.escape)
        _ = form.handle(KeyStroke("j"))
        for _ in 0 ..< 10 {
            _ = form.handle(KeyStroke("l"))
        }
        // The last stop is search: promoting is work in a repo.
        #expect(form.repoCursor == form.repoChoices.count)
        #expect(form.options == [.autostart, .planFirst, .shellSplit, .copyFiles])
        let plan = form.plan
        #expect(plan.promotion?.chatID == "c")
        let line = plan.command?.posix ?? ""
        #expect(line.hasPrefix("codex '"))
        #expect(line.contains("started as a chat with codex"))
    }

    @Test func claudeIntoClaudeResumesTheChatsSession() {
        let form = StartWorkForm(
            repos: records, settings: .default, prompt: "Add the job to markgraph", promotion: promotion()
        )
        let line = form.plan.command?.posix ?? ""
        #expect(line.hasPrefix("claude --resume c1d2 '"))
        #expect(line.contains("now work in a git worktree"))
    }

    @Test func copyingIsOfferedOnlyForAScratchChatWithFiles() {
        let picked = StartWorkForm(repos: records, settings: .default, promotion: promotion(kind: .folder))
        #expect(!picked.options.contains(.copyFiles))
        let empty = StartWorkForm(repos: records, settings: .default, promotion: promotion(files: []))
        #expect(!empty.options.contains(.copyFiles))
        var form = StartWorkForm(repos: records, settings: .default, promotion: promotion())
        _ = form.handle(.escape)
        // Prompt, repo, worktree, agent, model, effort, then the options.
        for key in ["j", "j", "j", "j", "j", "j", "l", "l", "l", "Space"] {
            _ = form.handle(KeyStroke(key))
        }
        #expect(form.promotion?.copyFiles == true)
    }

    // MARK: Executing

    @Test func promotingMakesTheWorktreeAndCarriesTheChatsSession() async throws {
        let repoPath = NSTemporaryDirectory() + "heed-promote-repo-\(UUID().uuidString)"
        let root = repoPath + "-wt"
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
            ["commit", "-q", "--allow-empty", "-m", "first"],
        ] {
            _ = try await ProcessRunner.output("git", ["-C", repoPath] + args, caller: "test")
        }
        let record = try #require(await Git.record(at: repoPath))
        var settings = WorkSettings.default
        settings.worktreeRoot = root
        var plan = StartWorkPlan(
            prompt: "Add the nightly job", repos: [record], name: "feature/nightly-job", agent: agent("claude"),
            sessionID: "new"
        )
        plan.promotion = promotion()
        let domain = try await Domain(repos: [record]).applying(StartWork.execute(plan, settings: settings))
        let session = try #require(domain.session("new"))
        let path = settings.worktreePath(repo: record.repo, name: "feature/nightly-job")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!session.isChat)
        #expect(session.agentSessionID == "c1d2")
        #expect(session.timeline.last?.text == "promoted from chat “Cron line for weekdays” · its conversation resumed")
        let pane = domain.layouts["new"]?.tabs.first?.tree.panes.first
        #expect(pane?.directory == session.worktreePaths.first)
        #expect(pane?.command?.posix.hasPrefix("claude --resume c1d2 '") == true)
    }

    @Test func aPromotedChatIsKeptAsPromotedInTheEventLog() async throws {
        let chat = Session(
            id: "c", title: "Cron", repos: [], branch: "", agent: "claude", state: .init(.idle),
            workspace: .chat(ChatFolder(.scratch, path: "/chats/c"))
        )
        let entry = HistoryEntry(session: chat, closedAt: Date(), outcome: .promoted)
        let writes = DomainEvents.writes(
            before: Domain(sessions: [chat]), changes: [.sessionClosed(entry)], now: Date()
        )
        let closed = writes.flatMap { write -> [LoggedEvent] in if case let .events(e) = write { e } else { [] } }
        #expect(closed.map(\.text) == ["promoted"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        await log.write(writes)
        #expect(try await log.history().first?.outcome == .promoted)
    }

    @Test func promoteIsAShortFormAndAChatMenuItem() {
        #expect(CommandAliases.resolve("promote") == CommandInvocation(name: "chat.promote"))
        var facts = ContextMenus.SessionFacts(id: "c", title: "Cron")
        facts.chat = true
        let names = ContextMenus.session(facts).compactMap { if case let .item(item) = $0 { item } else { nil } }
            .map(\.command.name)
        #expect(names.contains("chat.promote"))
        let work = ContextMenus.session(ContextMenus.SessionFacts(id: "s", title: "Fix"))
            .compactMap { if case let .item(item) = $0 { item } else { nil } }.map(\.command.name)
        #expect(!work.contains("chat.promote"))
    }
}
