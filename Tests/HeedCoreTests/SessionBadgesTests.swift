import Foundation
@testable import HeedCore
import Testing

/// Kind and size badges: what a session's work is, and how big it got.
struct SessionBadgesTests {
    private func session(branch: String = "feature/x", kind: WorkKind? = nil) -> Session {
        var result = Session(
            title: "t", repos: [Repo(org: "o", name: "r")], branch: branch, agent: "claude",
            state: ObservedState(.working)
        )
        result.kind = kind
        return result
    }

    @Test func sizeIsSmallMediumOrLargeAndNothingWhenUnchanged() {
        #expect(WorkSize.of(lines: nil, files: nil) == nil)
        #expect(WorkSize.of(lines: 0, files: 0) == nil)
        #expect(WorkSize.of(lines: 99, files: 3) == .small)
        #expect(WorkSize.of(lines: 100, files: 3) == .medium)
        #expect(WorkSize.of(lines: 800, files: 20) == .medium)
        #expect(WorkSize.of(lines: 801, files: 2) == .large)
        #expect(WorkSize.of(lines: 40, files: 21) == .large)
    }

    @Test func aKindGivenWinsThenThePRsTitleThenTheBranch() {
        #expect(SessionBadges.kind(of: session(kind: .docs), pullTitles: ["fix: x"]) == .docs)
        #expect(SessionBadges.kind(of: session(), pullTitles: ["fix(nav): redirects"]) == .fix)
        #expect(SessionBadges.kind(of: session(branch: "chore/tidy")) == .chore)
        #expect(SessionBadges.kind(of: session(branch: "bump/swift")) == .chore)
        #expect(SessionBadges.kind(of: session(branch: "no-prefix")) == nil)
        var chat = session()
        chat.workspace = .chat(ChatFolder(.scratch, path: "/tmp/c"))
        #expect(SessionBadges.kind(of: chat, pullTitles: ["feat: x"]) == nil)
    }

    @Test func conventionalTitlesReadAsKinds() {
        #expect(SessionBadges.conventionalKind("feat: release commands") == .feat)
        #expect(SessionBadges.conventionalKind("refactor!: drop the old store") == .refactor)
        #expect(SessionBadges.conventionalKind("perf(index): faster") == .refactor)
        #expect(SessionBadges.conventionalKind("ci: cache swift") == .chore)
        #expect(SessionBadges.conventionalKind("Release commands for serverless") == nil)
        #expect(SessionBadges.conventionalKind("Note: this is prose") == nil)
        #expect(SessionBadges.conventionalKind("see https://x") == nil)
    }

    @Test func theNextKindWraps() {
        #expect(SessionBadges.next(after: nil) == .feat)
        #expect(SessionBadges.next(after: .feat) == .fix)
        #expect(SessionBadges.next(after: .plan) == .feat)
    }

    @Test func sizesAddUpOverASessionsWorktreesAndOnlyWhenMeasured() {
        let measured = WorktreeStatus(changedFiles: 1, upstream: nil)
        var sized = measured
        sized.added = 120
        sized.removed = 30
        sized.files = 4
        func worktree(_ path: String, _ status: WorktreeStatus) -> Worktree {
            Worktree(repo: Repo(org: "o", name: "r"), path: path, branch: "b", head: "0", isMain: false, status: status)
        }
        let pending = PendingChanges([worktree("/a", sized), worktree("/b", sized)])
        #expect(pending.lines == 300)
        #expect(pending.files == 8)
        #expect(PendingChanges([worktree("/c", measured)]).lines == nil)
    }

    @Test func gitsShortStatIsRead() {
        let stat = Git.parseShortStat(" 3 files changed, 120 insertions(+), 8 deletions(-)\n")
        #expect(stat.files == 3 && stat.added == 120 && stat.removed == 8)
        let one = Git.parseShortStat(" 1 file changed, 1 insertion(+)")
        #expect(one.files == 1 && one.added == 1 && one.removed == 0)
        let none = Git.parseShortStat("")
        #expect(none.files == 0 && none.added == 0)
    }

    @Test func sortingBySizePutsTheBiggestFirst() {
        let small = Session(id: "s", title: "s", repos: [], branch: "", agent: "", state: ObservedState(.working))
        let big = Session(id: "b", title: "b", repos: [], branch: "", agent: "", state: ObservedState(.working))
        let list = SessionList([small, big], view: SessionsView(sort: .size), size: { $0.id == "b" ? 900 : 10 })
        #expect(list.ordered.map(\.id) == ["b", "s"])
    }

    @Test func theLedgerKeepsTheKindAsText() throws {
        let entry = Ledger.facts(
            session: session(branch: "fix/anchors"), closed: nil, pulls: GitHubState(), previous: nil
        )
        #expect(entry.kind == "fix")
        #expect(entry.workKind == .fix)
        var unknown = entry
        unknown.kind = "quest"
        let read = try JSONDecoder().decode(LedgerEntry.self, from: JSONEncoder().encode(unknown))
        #expect(read.kind == "quest")
        #expect(read.workKind == nil)
    }
}
