import Foundation
@testable import HeedCore
import Testing

private func session(
    _ id: String,
    _ state: AgentState,
    agent: String = "claude",
    agentID: String? = "aid",
    parked: Bool = false
) -> Session {
    Session(
        id: id, title: id, prompt: "do \(id)", repos: [Repo(org: "o", name: "r")], branch: id, agent: agent,
        agentSessionID: agentID, state: ObservedState(state), parked: parked
    )
}

struct ResumeTests {
    @Test func modesFollowTheStateTheSessionWasIn() {
        let domain = Domain(sessions: [
            session("w", .working), session("b", .blocked), session("a", .asking), session("d", .done),
            session("p", .working, parked: true), session("g", .working, agent: "gemini"),
            session("n", .working, agentID: nil),
        ])
        let candidates = Resume.candidates(domain: domain, settings: .default, integration: nil)
        let modes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.mode) })
        #expect(modes == [
            "w": .resumeThenContinue, "b": .resumeOnly, "a": .resumeOnly, "d": .leftClosed,
            "g": .resumeThenContinue, "n": .startFresh,
        ])
        #expect(candidates.first { $0.id == "w" }?.command.posix == "claude --resume aid")
        #expect(candidates.first { $0.id == "g" }?.command.posix == "gemini --resume aid")
        #expect(candidates.first { $0.id == "n" }?.command.posix == "claude 'do n'")
    }

    @Test func aDroppedSessionStartsFresh() {
        let domain = Domain(sessions: [session("w", .working)])
        let candidates = Resume.candidates(domain: domain, settings: .default, integration: nil) { _ in false }
        #expect(candidates.first?.mode == .startFresh)
    }

    @Test func resumeKeepsHooksButNotTheSessionIDFlag() {
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/h"))
        let domain = Domain(sessions: [session("w", .working, agentID: "abc")])
        let command = Resume.candidates(domain: domain, settings: .default, integration: files).first?.command.posix
        #expect(command == "claude --settings /tmp/h/claude-hooks.json --resume abc")
    }

    @Test func formTicksEverySessionAndToggles() {
        let domain = Domain(sessions: [session("w", .working), session("d", .done)])
        var form = ResumeForm(candidates: Resume.candidates(domain: domain, settings: .default, integration: nil))
        #expect(form.chosen.map(\.id) == ["w", "d"])
        _ = form.handle(KeyStroke("j"))
        _ = form.handle(KeyStroke("Space"))
        #expect(form.handle(KeyStroke("CR", .command)) == .resume(form.chosen))
        #expect(form.chosen.map(\.id) == ["w"])
        #expect(form.handle(.escape) == .startEmpty)
    }

    @Test func aClickMovesTheCursorAndFlipsTheTick() {
        let domain = Domain(sessions: [session("w", .working), session("d", .done)])
        var form = ResumeForm(candidates: Resume.candidates(domain: domain, settings: .default, integration: nil))
        form.click(1)
        #expect(form.cursor == 1)
        #expect(form.chosen.map(\.id) == ["w"])
        form.click(1)
        #expect(form.chosen.map(\.id) == ["w", "d"])
        form.click(5)
        #expect(form.cursor == 1)
        #expect(form.chosen.map(\.id) == ["w", "d"])
    }

    @Test func aTickedIdleSessionSaysWhatHappens() {
        let domain = Domain(sessions: [session("d", .done, agentID: "abc"), session("i", .idle, agentID: nil)])
        let candidates = Resume.candidates(domain: domain, settings: .default, integration: nil) { _ in true }
        let resumes = try? #require(candidates.first { $0.id == "d" })
        #expect(resumes?.label(ticked: false) == "left closed")
        #expect(resumes?.label(ticked: true) == "resume")
        let fresh = try? #require(candidates.first { $0.id == "i" })
        #expect(fresh?.label(ticked: true) == "start fresh")
    }

    @Test func alwaysStillLeavesIdleAndFinishedSessionsClosed() {
        let domain = Domain(sessions: [session("w", .working), session("d", .done), session("i", .idle)])
        let candidates = Resume.candidates(domain: domain, settings: .default, integration: nil)
        #expect(candidates.filter(\.resumesWithoutAsking).map(\.id) == ["w"])
    }

    @Test func claudeSessionFilesAreFoundByEncodedDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/-Users-me-code-wt-r--x"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(folder)/abc.jsonl", contents: Data())
        #expect(AgentIntegration.hasSession(
            agent: "claude",
            id: "abc",
            directory: "/Users/me/code/wt/r/.x",
            home: home
        ) == true)
        #expect(AgentIntegration.hasSession(
            agent: "claude",
            id: "nope",
            directory: "/Users/me/code/wt/r/.x",
            home: home
        ) == false)
        #expect(AgentIntegration.hasSession(agent: "codex", id: "abc", directory: "/", home: home) == nil)
    }

    @Test func aClaudeSessionResumedFromAnotherFolderIsStillFound() throws {
        // A throwaway home with a made-up transcript: claude keeps writing a session where it began, even when
        // `--resume` continues it from another folder.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/-tmp-first-folder"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(folder)/abc.jsonl", contents: Data())
        #expect(AgentIntegration.hasSession(agent: "claude", id: "abc", directory: "/code/wt/r/x", home: home) == true)
        #expect(AgentIntegration
            .hasSession(agent: "claude", id: "gone", directory: "/code/wt/r/x", home: home) == false)
        // No projects folder at all: nothing found, no error.
        #expect(AgentIntegration.hasSession(agent: "claude", id: "abc", directory: "/x", home: home + "/none") == false)
    }
}

struct HistoryTests {
    @Test func closingMovesASessionIntoHistory() {
        var domain = Fixtures.main
        let session = domain.session("s6")!
        domain.apply(.sessionClosed(HistoryEntry(session: session, closedAt: Date(), outcome: .abandoned)))
        #expect(domain.session("s6") == nil)
        #expect(domain.layouts["s6"] == nil)
        #expect(domain.history.first?.id == "s6")
        domain.apply(.historyRemoved("s6"))
        #expect(!domain.history.contains { $0.id == "s6" })
    }

    @Test func outcomesBeforeGitHubKnowsBetter() {
        #expect(HistoryEntry.outcome(closing: session("a", .done)) == .abandoned)
        var withPR = session("b", .done)
        withPR.trackedPRs = [PullRef(repo: Repo(org: "o", name: "r"), number: 1)]
        #expect(HistoryEntry.outcome(closing: withPR) == .closed)
    }

    @Test func timelinesAreCapped() {
        var s = session("t", .done)
        for index in 0 ..< 60 {
            s.record("event \(index)")
        }
        #expect(s.timeline.count == Session.timelineLimit)
        #expect(s.timeline.last?.text == "event 59")
    }

    @Test func reopenRecreatesACleanedUpWorktree() async throws {
        let repoPath = FileManager.default.temporaryDirectory.appendingPathComponent("heed-reopen-\(UUID().uuidString)")
            .path
        let root = repoPath + "-wt"
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "t"],
            ["commit", "-q", "--allow-empty", "-m", "first"],
            ["branch", "feature"],
        ] {
            _ = try await ProcessRunner.output("git", ["-C", repoPath] + args, caller: "test")
        }
        let record = try #require(await Git.record(at: repoPath))
        var settings = WorkSettings.default
        settings.worktreeRoot = root
        var closed = session("x", .done)
        closed.repos = [record.repo]
        closed.branch = "feature"
        let entry = HistoryEntry(session: closed, closedAt: Date(), outcome: .cleanedUp)
        let changes = try await Reopen.execute(
            entry, domain: Domain(repos: [record], history: [entry]), settings: settings, integration: nil
        )
        let restored = Domain(repos: [record], history: [entry]).applying(changes)
        #expect(restored.history.isEmpty)
        #expect(restored.session("x")?.timeline.contains { $0.text.contains("recreated") } == true)
        #expect(FileManager.default.fileExists(atPath: settings.worktreePath(repo: record.repo, name: "feature")))
        let pane = restored.layouts["x"]?.tabs.first?.tree.panes.first
        // Claude keeps no session file for this made-up id, so the agent starts again from the prompt.
        #expect(pane?.command?.posix == "claude 'do x'")
        #expect(restored.session("x")?.timeline.last?.text == "reopened · started fresh")
    }
}
