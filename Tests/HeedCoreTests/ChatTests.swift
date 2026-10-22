import Foundation
@testable import HeedCore
import Testing

/// A chat is a session without repos: it runs in a folder. Everything that reads a repo, branch or worktree must leave
/// it alone rather than guess one.
struct ChatTests {
    private let repo = Repo(org: "o", name: "r")

    private func chat(
        _ kind: ChatFolder.Kind = .scratch, path: String = "/tmp/chats/2026-10-21-cron-weekdays",
        state: AgentState = .working
    ) -> Session {
        Session(
            id: "c", title: "Cron line for weekdays", prompt: "What cron line runs at nine on weekdays",
            repos: [], branch: "", agent: "claude", state: ObservedState(state),
            workspace: .chat(ChatFolder(kind, path: path))
        )
    }

    // MARK: The model

    @Test func aChatHasAFolderAndNoBranch() {
        let session = chat()
        #expect(session.isChat)
        #expect(session.chat == ChatFolder(.scratch, path: "/tmp/chats/2026-10-21-cron-weekdays"))
        #expect(session.directory == "/tmp/chats/2026-10-21-cron-weekdays")
        #expect(session.branches.isEmpty)
        // Named after its title: it has no worktree folder or branch to go by.
        #expect(session.worktreeName == "Cron line for weekdays")
        let work = Session(title: "Fix it", repos: [repo], branch: "fix/it", agent: "claude", state: .init(.idle))
        #expect(!work.isChat)
        #expect(work.branches == ["fix/it"])
        #expect(work.worktreeName == "fix/it")
    }

    @Test func aChatRoundTripsAndOlderSessionsLoadAsWorktreeSessions() throws {
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(Session.self, from: encoder.encode(chat(.folder, path: "/tmp/x")))
        #expect(decoded.workspace == .chat(ChatFolder(.folder, path: "/tmp/x")))
        // A session in worktrees writes no chat key, so its file is what it was before chats.
        let work = Session(title: "Fix it", repos: [repo], branch: "fix/it", agent: "claude", state: .init(.idle))
        let json = try #require(String(data: encoder.encode(work), encoding: .utf8))
        #expect(!json.contains("\"chat\""))
        #expect(try JSONDecoder().decode(Session.self, from: Data(json.utf8)).workspace == .worktrees)
    }

    @Test func aChatOwnsNoWorktreeAndTracksNoPR() {
        var session = chat()
        let worktree = Worktree(
            repo: repo,
            path: "/tmp/chats/2026-10-21-cron-weekdays",
            branch: "",
            head: "abc",
            isMain: false
        )
        #expect(!session.owns(worktree))
        let ref = PullRef(repo: repo, number: 7)
        let added = session.track(ref, because: "opened by claude")
        #expect(!added)
        #expect(session.trackedPRs.isEmpty)
        let pull = PullRequest(
            ref: ref, title: "", url: "", state: .open, isDraft: false, headBranch: "", review: nil,
            checks: CheckSummary(), unresolvedThreads: 0, updatedAt: Date()
        )
        #expect(PullTracking.changes(sessions: [session], pulls: [pull]).isEmpty)
        #expect(BranchFollowing.follow(session, worktrees: [worktree]) == session)
    }

    @Test func aClosedChatIsClosedNotAbandoned() {
        #expect(HistoryEntry.outcome(closing: chat()) == .closed)
        let work = Session(title: "Fix it", repos: [repo], branch: "fix/it", agent: "claude", state: .init(.idle))
        #expect(HistoryEntry.outcome(closing: work) == .abandoned)
    }

    @Test func whileYouWereAwayNamesAChatByItsTitle() {
        let waiting = AwaySummary.waiting(from: [chat(state: .asking)])
        #expect(waiting.map(\.name) == ["Cron line for weekdays"])
        let closed = HistoryEntry(session: chat(), closedAt: Date(), outcome: .closed)
        let events = AwaySummary.events(from: Domain(history: [closed]))
        #expect(events.map(\.subject) == ["Cron line for weekdays"])
    }

    // MARK: The event log

    @Test func theEventLogRecordsAChatAsAChatAndKeepsItInHistory() async throws {
        let started = DomainEvents.writes(before: Domain(), changes: [.sessionUpserted(chat())], now: Date())
        let events = started.flatMap { write -> [LoggedEvent] in if case let .events(e) = write { e } else { [] } }
        let start = try #require(events.first { $0.kind == .sessionStarted })
        #expect(start.payload["chat"] == "scratch")
        #expect(start.payload["folder"] == "/tmp/chats/2026-10-21-cron-weekdays")
        #expect(start.repo == nil)
        // History keeps the whole entry: a closed chat comes back from heed.sqlite as a chat.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-chatlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        await log.write([.closed(HistoryEntry(session: chat(), closedAt: Date(), outcome: .closed))])
        let back = try #require(try await log.history().first)
        #expect(back.session.chat == ChatFolder(.scratch, path: "/tmp/chats/2026-10-21-cron-weekdays"))
    }

    // MARK: Handing over

    @Test func handingAChatOverSaysNothingAboutBranchesOrGit() {
        let text = Handoff.prompt(session: chat(), from: "claude", base: "main")
        #expect(text.contains("taking over a conversation from claude"))
        #expect(text.contains("What cron line runs at nine on weekdays"))
        #expect(!text.contains("branch"))
        #expect(!text.contains("git"))
    }

    // MARK: Its menu

    @Test func aChatsMenuHasNothingThatReadsARepo() {
        var facts = ContextMenus.SessionFacts(id: "c", title: "Cron")
        facts.chat = true
        facts.hasPrompt = true
        // Even with facts a chat should never have: nothing that needs a repo shows.
        facts.pulls = 1
        facts.openPulls = 1
        facts.hasGitHubRepo = true
        facts.handoffAgents = ["codex"]
        let names = ContextMenus.session(facts).flatMap { entry -> [String] in
            switch entry {
            case let .item(item): [item.command.name]
            case let .submenu(_, items): items.map(\.command.name)
            default: []
            }
        }
        #expect(names == ["session.pin", "session.park", "work.again", "chat.promote", "agent.switch", "session.close"])
        let close = ContextMenus.session(facts).compactMap { if case let .item(item) = $0 { item } else { nil } }.last
        #expect(close?.title == "Close")
    }

    // MARK: Reopening

    @Test func reopeningAChatMakesItsScratchFolderAgainAndStartsThere() async throws {
        let root = NSTemporaryDirectory() + "heed-chat-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/2026-10-21-cron-weekdays"
        let entry = HistoryEntry(session: chat(path: path, state: .done), closedAt: Date(), outcome: .closed)
        let changes = try await Reopen.execute(
            entry, domain: Domain(history: [entry]), settings: .default, integration: nil
        )
        #expect(FileManager.default.fileExists(atPath: path))
        let restored = Domain(history: [entry]).applying(changes)
        #expect(restored.history.isEmpty)
        let session = try #require(restored.session("c"))
        #expect(session.timeline.contains { $0.text == "scratch folder made again, empty" })
        let pane = restored.layouts["c"]?.tabs.first?.tree.panes.first
        #expect(pane?.directory == path)
        #expect(pane?.role == .agent)
    }

    @Test func aPickedFolderThatIsGoneIsNotMadeAgain() async {
        let path = NSTemporaryDirectory() + "heed-chat-gone-\(UUID().uuidString)"
        let entry = HistoryEntry(session: chat(.folder, path: path, state: .done), closedAt: Date(), outcome: .closed)
        await #expect(throws: ReopenError.self) {
            _ = try await Reopen.execute(entry, domain: Domain(history: [entry]), settings: .default, integration: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
