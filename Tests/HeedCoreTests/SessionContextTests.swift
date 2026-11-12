import Foundation
@testable import HeedCore
import Testing

/// The inspector's context: what a session is about, what was decided and left open around it, who else is in its
/// files.
struct SessionContextTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let repo = Repo(org: "o", name: "r")

    private func session(_ id: String, message: String? = nil) -> Session {
        var result = Session(
            id: id, title: id, repos: [repo], branch: id, agent: "claude", state: ObservedState(.idle),
            lastActivity: t0
        )
        result.lastMessage = message
        result.worktreePaths = ["/wt/\(id)"]
        return result
    }

    @Test func theSummaryIsTheLedgersWhileFreshElseTheAgentsLastWords() {
        var entry = LedgerEntry(id: "s", title: "s", startedAt: t0)
        entry.summary = "Checks redirects against headings."
        entry.summarizedAt = t0
        let live = session("s", message: "Done. Fixed the lint. Pushed.\n\nNext I would add tests.")
        #expect(SessionContext.summary(of: live, entry: entry) == "Checks redirects against headings.")
        entry.summarizedAt = t0.addingTimeInterval(-86400)
        #expect(SessionContext.summary(of: live, entry: entry) == "Done. Fixed the lint. Pushed.")
        #expect(SessionContext.summary(of: session("s"), entry: nil) == nil)
    }

    @Test func aLongSummaryIsCut() throws {
        let text = try #require(SessionContext.summary(
            of: session("s", message: String(repeating: "word ", count: 120)), entry: nil
        ))
        #expect(text.count <= 280)
        #expect(text.hasSuffix("…"))
    }

    private func tree() -> MindmapTree {
        var campaign = MindNode(id: "c", kind: .campaign, title: "Redirects", createdAt: t0)
        campaign.decisions = [
            .init(text: "Redirect files stay YAML", source: "x"),
            .init(text: "Anchors resolve against slugs", source: "y", pinned: true),
            .init(text: "Old rule", source: "z", supersededBy: "Anchors resolve against slugs"),
        ]
        var mine = MindNode(id: "work:s", parent: "c", kind: .work, title: "s", createdAt: t0)
        mine.entry = "s"
        mine.open = [.init(kind: .redCI, text: "lint fails", source: "s")]
        var other = MindNode(id: "work:o", parent: "c", kind: .work, title: "o", createdAt: t0)
        other.entry = "o"
        other.open = [
            .init(text: "port the tests", source: "o"),
            .init(text: "done already", source: "o", resolvedBy: "you"),
        ]
        return MindmapTree([campaign, mine, other])
    }

    @Test func decisionsAreTheCampaignsStandingOnesPinnedFirst() {
        let decided = SessionContext.decisions(for: session("s"), in: tree()).map(\.text)
        #expect(decided.first == "Anchors resolve against slugs")
        #expect(decided.contains("Redirect files stay YAML"))
        #expect(!decided.contains("Old rule"))
        #expect(SessionContext.decisions(for: session("unplaced"), in: tree()).isEmpty)
    }

    @Test func looseEndsAreItsOwnFirstThenTheCampaignsWithTheirNodes() {
        let loose = SessionContext.looseEnds(for: session("s"), in: tree())
        #expect(loose.map(\.item.text) == ["lint fails", "port the tests"])
        #expect(loose.map(\.node) == ["work:s", "work:o"])
        let prompt = SessionContext.tackle(loose.map(\.item))
        #expect(prompt.contains("1) lint fails (red CI)"))
        #expect(prompt.contains("2) port the tests (follow-up)"))
    }

    @Test func overlapsAreSessionsChangingTheSameFilesInTheSameRepo() {
        func worktree(_ owner: String, _ paths: [String], repo: Repo? = nil) -> Worktree {
            var status = WorktreeStatus()
            status.paths = paths
            return Worktree(
                repo: repo ?? self.repo, path: "/wt/\(owner)", branch: owner, head: "0", isMain: false, status: status
            )
        }
        let mine = session("s"), theirs = session("t"), elsewhere = session("e")
        let trees = [
            worktree("s", ["a.swift", "b.md"]), worktree("t", ["b.md", "c.md"]),
            worktree("e", ["b.md"], repo: Repo(org: "o", name: "other")),
        ]
        let overlaps = SessionContext.overlaps(of: mine, sessions: [mine, theirs, elsewhere], worktrees: trees)
        #expect(overlaps.map(\.session.id) == ["t"])
        #expect(overlaps.first?.files == ["b.md"])
        // Nothing measured, nothing to compare.
        #expect(SessionContext.overlaps(of: mine, sessions: [mine, theirs], worktrees: []).isEmpty)
    }

    @Test func numstatGivesLinesAndPaths() {
        let stat = Git.parseNumStat("120\t8\tdocs/a.md\n-\t-\timg.png\n3\t0\tsrc/b.swift\n")
        #expect(stat.added == 123 && stat.removed == 8)
        #expect(stat.paths == ["docs/a.md", "img.png", "src/b.swift"])
    }
}
