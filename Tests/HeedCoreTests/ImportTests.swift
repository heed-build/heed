import Foundation
@testable import HeedCore
import Testing

struct TypeaheadTests {
    @Test func typingNarrowsAndReturnPicks() {
        var typeahead = Typeahead(items: ["acme/docs-toolkit", "acme/kibana", "globex/curb"]) { [$0] }
        for key in ["d", "o", "c"] {
            _ = typeahead.handle(KeyStroke(key))
        }
        #expect(typeahead.matches == ["acme/docs-toolkit"])
        _ = typeahead.handle(KeyStroke("u", .control))
        _ = typeahead.handle(KeyStroke("n", .control))
        guard case let .picked(item) = typeahead.handle(KeyStroke("CR")) else {
            Issue.record("expected a pick")
            return
        }
        #expect(item == "acme/kibana")
        guard case .cancel = typeahead.handle(.escape) else {
            Issue.record("expected cancel")
            return
        }
    }
}

struct StartWorkRepoSearchTests {
    private let records = (["docs-toolkit", "docs-website", "markgraph"] + (1 ... 8).map { "extra-\($0)" }).map {
        RepoRecord(repo: Repo(org: "acme", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    @Test func anyRepoCanBePickedBySearchAndGetsAChip() {
        var form = StartWorkForm(repos: records, settings: .default)
        _ = form.handle(.escape) // stop editing the prompt
        _ = form.handle(KeyStroke("j")) // kind
        _ = form.handle(KeyStroke("j")) // repo field
        #expect(form.field == .repo)
        _ = form.handle(KeyStroke("/"))
        #expect(form.repoSearch != nil)
        for key in ["x", "t", "r", "a", "-", "7"] {
            _ = form.handle(KeyStroke(key))
        }
        _ = form.handle(KeyStroke("CR"))
        #expect(form.repoSearch == nil)
        #expect(form.selectedRepos == ["acme/extra-7"])
        #expect(form.repoChoices.contains { $0.repo.id == "acme/extra-7" })
    }

    @Test func theChipBeforeTheChatChipOpensSearch() {
        var form = StartWorkForm(repos: records, settings: .default)
        _ = form.handle(.escape)
        _ = form.handle(KeyStroke("j"))
        _ = form.handle(KeyStroke("j"))
        for _ in 0 ..< 20 {
            _ = form.handle(KeyStroke("l"))
        }
        // The last chip is the chat chip; search is the one before it.
        #expect(form.repoCursor == form.chatChipIndex)
        _ = form.handle(KeyStroke("h"))
        #expect(form.repoCursor == form.repoChoices.count)
        _ = form.handle(KeyStroke("Space"))
        #expect(form.repoSearch != nil)
        _ = form.handle(.escape)
        #expect(form.repoSearch == nil)
    }
}

@Suite(.scratch)
struct ImportTests {
    private func home(with transcript: String, for directory: String) throws -> String {
        let home = try Scratch.folder("heed-import").path
        let folder = AgentIntegration.claudeProjectFolder(directory)
        let project = "\(home)/.claude/projects/\(folder)"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try transcript.write(toFile: "\(project)/abc-123.jsonl", atomically: true, encoding: .utf8)
        return home
    }

    @Test func findsClaudeSessionsAndTheirFirstRealPrompt() throws {
        let transcript = """
        {"type":"summary","summary":"x"}
        {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the redirect loop\\nin /reference"}]}}
        {"type":"assistant","message":{"role":"assistant","content":"ok"}}
        """
        let home = try home(with: transcript, for: "/wt/docs/fix.loop")
        let found = Import.claudeSessions(directory: "/wt/docs/fix.loop", home: home)
        #expect(found.map(\.id) == ["abc-123"])
        #expect(found.first?.prompt == "Fix the redirect loop\nin /reference")
        #expect(Import.claudeSessions(directory: "/elsewhere", home: home).isEmpty)
    }

    @Test func claudeProjectFoldersReplaceEverythingButLettersAndDigits() {
        // As found on disk: _ and . become - too.
        #expect(AgentIntegration.claudeProjectFolder("/Users/me/atlas/.claude/worktrees/bridge-cse_01GML")
            == "-Users-me-atlas--claude-worktrees-bridge-cse-01GML")
    }

    @Test func importResumesTheFoundSessionOrStartsFresh() {
        let worktree = Worktree(
            repo: Repo(org: "acme", name: "docs-toolkit"), path: "/wt/docs/fix", branch: "fix/loop", head: "abc",
            isMain: false
        )
        let claude = AgentProfile.builtIn[0]
        let found = Import.AgentSession(agent: "claude", id: "abc-123", modified: Date(), prompt: "Fix the loop\nmore")
        let resumed = Import.session(for: worktree, agent: claude, resume: found, integration: nil)
        guard case let .sessionUpserted(session) = resumed[0], case let .layoutChanged(_, layout) = resumed[1] else {
            Issue.record("expected a session and a layout")
            return
        }
        #expect(session.title == "Fix the loop")
        #expect(session.agentSessionID == "abc-123")
        #expect(session.branch == "fix/loop")
        #expect(layout.tabs[0].tree.panes[0].command?.posix == "claude --resume abc-123")
        #expect(layout.tabs[0].tree.panes[0].directory == "/wt/docs/fix")

        let fresh = Import.session(for: worktree, agent: claude, resume: nil, integration: nil)
        guard case let .sessionUpserted(freshSession) = fresh[0],
              case let .layoutChanged(_, freshLayout) = fresh[1]
        else {
            Issue.record("expected a session and a layout")
            return
        }
        #expect(freshSession.title == "fix/loop")
        #expect(freshLayout.tabs[0].tree.panes[0].command?.posix == "claude")
    }

    /// Writes `transcript` as `<id>.jsonl` into the project folder of `directory` under `home`, modified at `modified`.
    private func write(
        _ transcript: String, id: String, directory: String, home: String, modified: Date
    ) throws {
        let project = "\(home)/.claude/projects/\(AgentIntegration.claudeProjectFolder(directory))"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let file = "\(project)/\(id).jsonl"
        try transcript.write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file)
    }

    private func transcript(_ prompt: String, cwd: String) -> String {
        """
        {"type":"permission-mode","permissionMode":"default","sessionId":"x"}
        {"type":"user","cwd":"\(cwd)","message":{"role":"user","content":"\(prompt)"}}
        """
    }

    @Test func listsEveryClaudeSessionNewestFirstWithTheFolderItRanIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let now = Date()
        // The project folder's name loses the `_` and `.`; the transcript's cwd keeps them.
        try write(
            transcript("Fix the loop", cwd: "/wt/docs/fix_loop.v2"), id: "old", directory: "/wt/docs/fix_loop.v2",
            home: home, modified: now.addingTimeInterval(-600)
        )
        try write(
            transcript("Sort my notes", cwd: "/Users/me/notes"), id: "new", directory: "/Users/me/notes", home: home,
            modified: now
        )
        try write(
            transcript("Already in heed", cwd: "/wt/a"), id: "known", directory: "/wt/a", home: home, modified: now
        )
        try write(
            #"{"type":"user","cwd":"/wt/b","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            id: "empty", directory: "/wt/b", home: home, modified: now
        )
        // A subagent's transcript, in a folder of its own: not a session to import.
        let subagents = "\(home)/.claude/projects/\(AgentIntegration.claudeProjectFolder("/Users/me/notes"))/new/subagents"
        try FileManager.default.createDirectory(atPath: subagents, withIntermediateDirectories: true)
        try transcript("A subagent", cwd: "/Users/me/notes")
            .write(toFile: "\(subagents)/agent-1.jsonl", atomically: true, encoding: .utf8)
        let found = Import.allClaudeSessions(home: home, excluding: ["known"])
        #expect(found.map(\.id) == ["new", "old"])
        #expect(found.map(\.directory) == ["/Users/me/notes", "/wt/docs/fix_loop.v2"])
        #expect(found.map(\.prompt) == ["Sort my notes", "Fix the loop"])
        #expect(Import.allClaudeSessions(home: home, limit: 1).map(\.id).count <= 1)
        #expect(Import.allClaudeSessions(home: "/nowhere").isEmpty)
    }

    /// A codex rollout as codex writes it: its `session_meta`, the context codex adds as user turns, then the prompt.
    private func writeRollout(
        id: String, cwd: String, prompt: String?, home: String, day: String = "2026/10/16", modified: Date
    ) throws {
        let folder = "\(home)/.codex/sessions/\(day)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let turn = { (role: String, text: String) in
            #"{"type":"response_item","payload":{"type":"message","role":"\#(role)","content":"#
                + #"[{"type":"input_text","text":"\#(text)"}]}}"#
        }
        let rollout = [
            #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","source":"cli","base_instructions":{}}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            turn("developer", "be nice"),
            turn("user", "# AGENTS.md instructions for \(cwd)"),
            turn("user", "<environment_context>x</environment_context>"),
            prompt.map { turn("user", $0) } ?? "",
        ].joined(separator: "\n")
        let file = "\(folder)/rollout-2026-10-16T15-12-54-\(id).jsonl"
        try rollout.write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file)
    }

    @Test func listsCodexSessionsWithTheirFolderAndFirstTypedPrompt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let now = Date()
        let older = "01a13eef-69cc-72b1-8cdb-8669eda9e2be"
        let newer = "01a144d8-174f-7753-8563-979eb88117a2"
        let known = "01a143cb-1eed-77a0-925e-df568e46ed3c"
        let untyped = "01a09b2f-d881-7a81-bb52-edea7e521a52"
        try writeRollout(
            id: older, cwd: "/wt/docs/fix_loop", prompt: "Fix the loop", home: home, day: "2026/10/15",
            modified: now.addingTimeInterval(-600)
        )
        try writeRollout(id: newer, cwd: "/Users/me/notes", prompt: "Sort my notes", home: home, modified: now)
        try writeRollout(id: known, cwd: "/wt/a", prompt: "Already in heed", home: home, modified: now)
        try writeRollout(id: untyped, cwd: "/wt/b", prompt: nil, home: home, modified: now)
        let found = Import.allCodexSessions(home: home, excluding: [known])
        #expect(found.map(\.id) == [newer, older])
        #expect(found.allSatisfy { $0.agent == "codex" })
        #expect(found.map(\.directory) == ["/Users/me/notes", "/wt/docs/fix_loop"])
        #expect(found.map(\.prompt) == ["Sort my notes", "Fix the loop"])
    }

    @Test func allSessionsMixesAgentsNewestFirstAndAWorktreeGetsItsNewest() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let now = Date()
        try write(
            transcript("Claude, older", cwd: "/wt/docs/fix"), id: "claude-1", directory: "/wt/docs/fix", home: home,
            modified: now.addingTimeInterval(-600)
        )
        let codex = "01a144d8-174f-7753-8563-979eb88117a2"
        try writeRollout(id: codex, cwd: "/wt/docs/fix", prompt: "Codex, newer", home: home, modified: now)
        #expect(Import.allSessions(home: home).map(\.agent) == ["codex", "claude"])
        #expect(Import.allSessions(home: home, excluding: [codex]).map(\.id) == ["claude-1"])
        let newest = Import.newestSessions(for: ["/wt/docs/fix", "/wt/other"], home: home)
        #expect(newest["/wt/docs/fix"]?.id == codex)
        #expect(newest["/wt/other"] == nil)
    }

    @Test func aCodexSessionResumesWithCodex() {
        let codex = AgentProfile.builtIn.first { $0.name == "codex" }!
        let found = Import.AgentSession(
            agent: "codex", id: "01a1", modified: Date(), prompt: "Sort my notes", directory: "/Users/me/notes"
        )
        let changes = Import.chatSession(folder: "/Users/me/notes", agent: codex, resume: found, integration: nil)
        guard case let .layoutChanged(_, layout) = changes[1] else {
            Issue.record("expected a layout")
            return
        }
        #expect(layout.tabs[0].tree.panes[0].command?.posix == "codex resume 01a1")
    }

    @Test func aSessionOutsideAnyRepoBecomesAChatThatResumesIt() {
        let claude = AgentProfile.builtIn[0]
        let found = Import.AgentSession(
            agent: "claude", id: "abc-123", modified: Date(), prompt: "Sort my notes\ninto themes",
            directory: "/Users/me/notes"
        )
        let changes = Import.chatSession(folder: "/Users/me/notes", agent: claude, resume: found, integration: nil)
        guard case let .sessionUpserted(session) = changes[0], case let .layoutChanged(_, layout) = changes[1] else {
            Issue.record("expected a session and a layout")
            return
        }
        #expect(session.title == "Sort my notes")
        #expect(session.agentSessionID == "abc-123")
        #expect(session.repos.isEmpty)
        #expect(session.workspace == .chat(ChatFolder(.folder, path: "/Users/me/notes")))
        #expect(layout.tabs[0].tree.panes[0].command?.posix == "claude --resume abc-123")
        #expect(layout.tabs[0].tree.panes[0].directory == "/Users/me/notes")
    }
}

@Suite(.scratch)
struct PathCompletionTests {
    private func tree() throws -> String {
        let root = try Scratch.folder("heed-paths").path
        for folder in ["code/heed", "code/Heron", "code/atlas", "code/.hidden"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(folder)", withIntermediateDirectories: true)
        }
        try "x".write(toFile: "\(root)/code/help.txt", atomically: true, encoding: .utf8)
        return root
    }

    @Test func completesFoldersByPrefixIgnoringCaseAndFiles() throws {
        let root = try tree()
        #expect(PathCompletion.candidates(for: "\(root)/code/he") == ["\(root)/code/heed", "\(root)/code/Heron"])
        #expect(PathCompletion.candidates(for: "\(root)/code/").count == 3) // hidden ones and files left out
        #expect(PathCompletion.candidates(for: "\(root)/code/.h") == ["\(root)/code/.hidden"])
        #expect(PathCompletion.candidates(for: "\(root)/nope/").isEmpty)
    }

    @Test func dropsTheLastComponent() {
        #expect(PathCompletion.droppingLastComponent("~/code/heed/") == "~/code/")
        #expect(PathCompletion.droppingLastComponent("~/code/he") == "~/code/")
        #expect(PathCompletion.droppingLastComponent("~/") == "")
    }
}
