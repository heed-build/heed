import Foundation
@testable import HeedCore
import Testing

/// Closing a run never deletes work nothing else has.
struct BrowseKeptTests {
    @Test func aCleanWorktreeIsRemoved() {
        #expect(BrowseCloseDecision.decide(unpushed: 0, dirty: 0) == .remove)
    }

    @Test func unpushedCommitsKeepTheWorktree() {
        #expect(BrowseCloseDecision.decide(unpushed: 3, dirty: 0) == .keep(unpushed: 3, dirty: 0))
    }

    @Test func uncommittedChangesKeepTheWorktree() {
        #expect(BrowseCloseDecision.decide(unpushed: 0, dirty: 2) == .keep(unpushed: 0, dirty: 2))
    }

    @Test func aWorktreeGitCouldNotReadIsKept() {
        #expect(BrowseCloseDecision.decide(unpushed: 0, dirty: nil) != .remove)
    }

    @Test func theCardNamesWhatIsAtStakeAndTheWayOut() {
        let kept = BrowseKept(unpushed: 2, dirty: 1, path: "/wt/issue-1")
        #expect(kept.message.contains("2 commits are not pushed and 1 file has changes that are not committed"))
        #expect(kept.message.contains("Kept at /wt/issue-1"))
        #expect(kept.message.contains("(s)"))
        #expect(kept.message.contains("X twice"))
        #expect(BrowseKept(unpushed: 1, dirty: 0, path: "/p").what == "1 commit is not pushed")
    }

    @Test func discardNeedsXTwiceInQuickSuccession() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var kept = BrowseKept(unpushed: 1, dirty: 0, path: "/p")
        let first = kept.pressDiscard(at: t)
        let second = kept.pressDiscard(at: t.addingTimeInterval(2))
        #expect(!first)
        #expect(second)
    }

    @Test func aSecondXMuchLaterOnlyArmsAgain() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var kept = BrowseKept(unpushed: 1, dirty: 0, path: "/p")
        _ = kept.pressDiscard(at: t)
        let late = kept.pressDiscard(at: t.addingTimeInterval(BrowseKept.discardWindow + 1))
        let next = kept.pressDiscard(at: t.addingTimeInterval(BrowseKept.discardWindow + 2))
        #expect(!late)
        #expect(next)
    }

    @Test func aKeptRunIsFoundForItsItemWhileNoRunIsCurrent() {
        let item = BrowseItem(
            repo: Repo(org: "acme", name: "docs"), number: 7,
            title: ExternalText("t", source: .issueTitle, author: .unknown), author: "mara"
        )
        var run = BrowseRun(
            item: item, verb: .fix, agent: "claude", adapter: "acp", name: "n", branch: "b", worktree: "/w",
            phase: .working, startedAt: Date(), cap: 1
        )
        _ = run.apply(.closed("closed"), at: Date())
        #expect(BrowseRuns.kept(for: item.id, in: [run]) == nil)
        run.kept = BrowseKept(unpushed: 1, dirty: 0, path: "/w")
        #expect(BrowseRuns.kept(for: item.id, in: [run])?.id == run.id)
        #expect(BrowseRuns.current(for: item.id, in: [run]) == nil)
    }
}
