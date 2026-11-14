import Foundation
@testable import HeedCore
import Testing

/// The session's one helper line: which runs it lists, in what order, what it says, and when a finished run leaves
/// it. The row's short next step and the proposal's Other menu, too.
struct SessionHelperLineTests {
    private let repo = Repo(org: "acme", name: "docs-toolkit")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func run(
        _ id: String, _ number: Int, _ phase: HelperRun.Phase, kind: HelperKind = .green, session: String? = nil
    ) -> HelperRun {
        var run = HelperRun(
            id: id, kind: kind, ref: PullRef(repo: repo, number: number), title: "t", agent: "claude",
            adapter: "claude via ACP", sessionID: session, prBranch: "b\(number)",
            branch: "heed/get-it-green/b\(number)",
            worktree: "/wt/\(id)", startedAt: t0, cap: 0.5
        )
        run.phase = phase
        return run
    }

    private func tracked(_ numbers: Int...) -> [PullRef] { numbers.map { PullRef(repo: repo, number: $0) } }

    @Test func needsYouComesFirstThenWorkingThenWaiting() throws {
        var working = run("a", 2841, .working)
        working.plan = (1 ... 5).map {
            ACPPlanEntry(content: "s\($0)", status: $0 < 3 ? .completed : $0 == 3 ? .inProgress : .pending)
        }
        let runs = [working, run("b", 1920, .paused), run("c", 412, .asking), run("d", 99, .working)]
        let line = try #require(SessionHelperLine.of(
            runs, tracked: tracked(2841, 1920, 412), sessionID: "s1", leftAt: nil, dismissed: []
        ))
        #expect(line.entries.map(\.number) == [412, 2841, 1920])
        #expect(line.text
            == "▶ 3 helpers on this session's PRs · #412 needs your OK · #2841 step 3 of 5 · #1920 paused")
        #expect(line.needsYou)
    }

    @Test func oneRunIsTheLine() throws {
        let line = try #require(SessionHelperLine.of(
            [run("a", 2841, .working)], tracked: tracked(2841), sessionID: "s1", leftAt: nil, dismissed: []
        ))
        #expect(line.text == "▶ A helper is getting #2841 green · working")
        #expect(!line.needsYou)
        // A run the session started counts even when it tracks no PR.
        #expect(SessionHelperLine.of(
            [run("r", 7, .starting, kind: .review, session: "s1")], tracked: [], sessionID: "s1", leftAt: nil,
            dismissed: []
        )?.text == "▶ A helper is reviewing #7 for you · starting")
        #expect(SessionHelperLine.of(
            [run("a", 2841, .working)], tracked: tracked(1), sessionID: "s1", leftAt: nil, dismissed: []
        ) == nil)
    }

    @Test func aCloseOutWaitingIsYours() {
        #expect(SessionHelperLine.entry(run("a", 1, .done(.endTurn))).standing == .needsYou)
        #expect(SessionHelperLine.entry(run("a", 1, .stopped("cap"))).status == "stopped · needs your OK")
        #expect(SessionHelperLine.entry(run("a", 1, .failed("gone"))).status == "failed: gone")
    }

    @Test func aFinishedRunStaysUntilSeen() throws {
        var done = run("a", 2841, .closed("pushed a3f9c1d"))
        done.endedAt = t0.addingTimeInterval(60)
        done.closeOut = HelperCloseOut(pushedSHA: "a3f9c1d0e2b")
        let line = try #require(SessionHelperLine.of(
            [done], tracked: tracked(2841), sessionID: "s1", leftAt: t0, dismissed: []
        ))
        #expect(line.text == "✓ #2841 pushed a3f9c1d · pull before your next change")
        #expect(line.finished.count == 1)
        // Left the session after it finished: seen. Dismissed: seen.
        #expect(SessionHelperLine.of(
            [done], tracked: tracked(2841), sessionID: "s1", leftAt: t0.addingTimeInterval(61), dismissed: []
        ) == nil)
        #expect(SessionHelperLine.of(
            [done], tracked: tracked(2841), sessionID: "s1", leftAt: nil, dismissed: ["a"]
        ) == nil)
        #expect(!SessionHelperLine.seen(endedAt: nil, leftAt: t0, dismissed: false))
        #expect(SessionHelperLine.seen(endedAt: t0, leftAt: t0.addingTimeInterval(1), dismissed: false))
        #expect(!SessionHelperLine.seen(endedAt: t0, leftAt: t0, dismissed: false))
    }

    @Test func aStepOrAFinishChangesTheSignature() throws {
        var working = run("a", 1, .working)
        working.plan = [ACPPlanEntry(content: "x", status: .inProgress), ACPPlanEntry(content: "y", status: .pending)]
        let before = try #require(SessionHelperLine.of(
            [working], tracked: tracked(1), sessionID: "s", leftAt: nil, dismissed: []
        ))
        working.plan[0].status = .completed
        working.plan[1].status = .inProgress
        let after = try #require(SessionHelperLine.of(
            [working], tracked: tracked(1), sessionID: "s", leftAt: nil, dismissed: []
        ))
        #expect(before.signature != after.signature)
        #expect(after.text.hasSuffix("step 2 of 2"))
    }

    @Test func theRowSaysAStepOnlyWhenHeedWouldAct() {
        #expect(NextStep.merge.chip == "▶ merge it")
        #expect(NextStep.review.chip == "▶ review")
        #expect(NextStep.getGreen(steps: [], merge: true).chip == "▶ green + merge")
        #expect(NextStep.setUpAutopilot(repo).chip == "▶ set up")
        #expect(NextStep.startWork.chip == "▶ start")
        #expect(NextStep.helping(.green).chip == "▶ heed is on it")
        #expect(NextStep.nothing("waiting on others").chip == nil)
    }

    @Test func otherListsTheOtherStepsThenTheActions() {
        let pr = AttentionItem(
            id: "x", kind: .pr, repo: repo, number: 1, title: "t", url: "https://github.com/acme/docs-toolkit/pull/1",
            reasons: [.reviewRequested], updatedAt: t0, notificationID: "n1"
        )
        let entries = OtherMenu.entries(pr, own: .review, proposed: .review)
        // Reply is the action (R), not a step as well.
        #expect(entries.map(\.label) == [
            "Review", "Reply", "Start a session", "Done", "Snooze", "Mute", "GitHub",
        ])
        let issue = AttentionItem(
            id: "y", kind: .issue, repo: repo, number: 2, title: "t", url: nil, reasons: [.mentioned],
            updatedAt: t0, session: "s1"
        )
        let moved = OtherMenu.entries(issue, own: .draftReply, proposed: .startWork)
        #expect(moved.prefix(1) == [.own(.draftReply)])
        #expect(!moved.contains(.step(.startWork)))
        #expect(moved.map(\.label).contains("Go to its session") && !moved.map(\.label).contains("Mute"))
        #expect(OtherMenu.entries(issue, own: .draftReply, proposed: .draftReply).first == .step(.startWork))
    }
}
