import Foundation
@testable import HeedCore
import Testing

struct TypeaheadTests {
    @Test func typingNarrowsAndReturnPicks() {
        var typeahead = Typeahead(items: ["elastic/docs-builder", "elastic/kibana", "nullean/curb"]) { [$0] }
        for key in ["d", "o", "c"] {
            _ = typeahead.handle(KeyStroke(key))
        }
        #expect(typeahead.matches == ["elastic/docs-builder"])
        _ = typeahead.handle(KeyStroke("u", .control))
        _ = typeahead.handle(KeyStroke("n", .control))
        guard case let .picked(item) = typeahead.handle(KeyStroke("CR")) else {
            Issue.record("expected a pick")
            return
        }
        #expect(item == "elastic/kibana")
        guard case .cancel = typeahead.handle(.escape) else {
            Issue.record("expected cancel")
            return
        }
    }
}

struct StartWorkRepoSearchTests {
    private let records = (["docs-builder", "docs-content", "mermaider"] + (1 ... 8).map { "extra-\($0)" }).map {
        RepoRecord(repo: Repo(org: "elastic", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    @Test func anyRepoCanBePickedBySearchAndGetsAChip() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        _ = form.handle(.escape) // stop editing the prompt
        _ = form.handle(KeyStroke("j")) // repo field
        #expect(form.field == .repo)
        _ = form.handle(KeyStroke("/"))
        #expect(form.repoSearch != nil)
        for key in ["x", "t", "r", "a", "-", "7"] {
            _ = form.handle(KeyStroke(key))
        }
        _ = form.handle(KeyStroke("CR"))
        #expect(form.repoSearch == nil)
        #expect(form.selectedRepos == ["elastic/extra-7"])
        #expect(form.repoChoices.contains { $0.repo.id == "elastic/extra-7" })
    }

    @Test func theLastChipOpensSearch() {
        var form = StartWorkForm(repos: records, history: [], settings: .default)
        _ = form.handle(.escape)
        _ = form.handle(KeyStroke("j"))
        for _ in 0 ..< 20 {
            _ = form.handle(KeyStroke("l"))
        }
        #expect(form.repoCursor == form.repoChoices.count)
        _ = form.handle(KeyStroke("Space"))
        #expect(form.repoSearch != nil)
        _ = form.handle(.escape)
        #expect(form.repoSearch == nil)
    }
}

struct ImportTests {
    private func home(with transcript: String, for directory: String) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
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
            repo: Repo(org: "elastic", name: "docs-builder"), path: "/wt/docs/fix", branch: "fix/loop", head: "abc",
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
        #expect(layout.tabs[0].tree.panes[0].command == "claude --resume abc-123")
        #expect(layout.tabs[0].tree.panes[0].directory == "/wt/docs/fix")

        let fresh = Import.session(for: worktree, agent: claude, resume: nil, integration: nil)
        guard case let .sessionUpserted(freshSession) = fresh[0],
              case let .layoutChanged(_, freshLayout) = fresh[1]
        else {
            Issue.record("expected a session and a layout")
            return
        }
        #expect(freshSession.title == "fix/loop")
        #expect(freshLayout.tabs[0].tree.panes[0].command == "claude")
    }
}
