import Foundation
@testable import HeedCore
import Testing

/// Quitting with Browse runs live says so, and names them.
struct BrowseQuitNoticeTests {
    private func run(_ number: Int, _ phase: BrowseRun.Phase) -> BrowseRun {
        let item = BrowseItem(
            repo: Repo(org: "acme", name: "docs"), number: number,
            title: ExternalText("t", source: .issueTitle, author: .unknown), author: "mara"
        )
        return BrowseRun(
            item: item, verb: .fix, agent: "claude", adapter: "acp", name: "n", branch: "b", worktree: "/w",
            phase: phase, startedAt: Date(), cap: 1
        )
    }

    @Test func noRunsSaysNothing() {
        #expect(BrowseQuitNotice.lines(for: []).isEmpty)
        #expect(BrowseQuitNotice.lines(for: [run(1, .failed("x")), run(2, .closed("closed"))]).isEmpty)
    }

    @Test func liveRunsAreNamedAndTheWorktreeIsPromised() {
        let lines = BrowseQuitNotice.lines(for: [run(7, .working), run(8, .done(.endTurn)), run(9, .failed("x"))])
        #expect(lines.first == "2 Browse agent runs are live and will stop")
        #expect(lines.contains { $0.contains("acme/docs#7") })
        #expect(lines.contains { $0.contains("acme/docs#8") })
        #expect(!lines.contains { $0.contains("#9") })
        #expect(lines.last == "Unpushed work is kept in its worktree")
    }

    @Test func manyAreCounted() {
        let lines = BrowseQuitNotice.lines(for: (1 ... 8).map { run($0, .working) })
        #expect(lines.contains("and 3 more"))
    }
}
