import Foundation
@testable import HeedCore
import Testing

/// Where a hook message goes (a reviewer's, worker's or run's pane, or the session's agent) and what it does there.
struct HookRouterTests {
    private let panes = HookRouter.Panes(retired: ["old"], reviews: ["rev"], workers: ["wrk"], runs: ["run"])

    // MARK: Route

    @Test func anUnverifiedMessageIsUnheardWhateverItsPane() {
        #expect(HookRouter.route(verified: false, pane: "run", panes: panes) == .unheard)
        #expect(HookRouter.route(verified: false, pane: nil, panes: panes) == .unheard)
    }

    @Test func eachKnownPaneRoutesToItsOwner() {
        #expect(HookRouter.route(verified: true, pane: "old", panes: panes) == .retired)
        #expect(HookRouter.route(verified: true, pane: "rev", panes: panes) == .review(pane: "rev"))
        #expect(HookRouter.route(verified: true, pane: "wrk", panes: panes) == .worker(pane: "wrk"))
        #expect(HookRouter.route(verified: true, pane: "run", panes: panes) == .run(pane: "run"))
        #expect(HookRouter.route(verified: true, pane: "agent", panes: panes) == .session)
        #expect(HookRouter.route(verified: true, pane: nil, panes: panes) == .session)
    }

    @Test func aRetiredPaneWinsAndAReviewerBeatsAWorkerBeatsARun() {
        let all = HookRouter.Panes(retired: [], reviews: ["p"], workers: ["p"], runs: ["p"])
        #expect(HookRouter.route(verified: true, pane: "p", panes: all) == .review(pane: "p"))
        var some = all
        some.reviews = []
        #expect(HookRouter.route(verified: true, pane: "p", panes: some) == .worker(pane: "p"))
        some.workers = []
        #expect(HookRouter.route(verified: true, pane: "p", panes: some) == .run(pane: "p"))
        some.retired = ["p"]
        #expect(HookRouter.route(verified: true, pane: "p", panes: some) == .retired)
    }

    // MARK: Reported state

    @Test func aGuessIsDoneAndAPromptIsIdle() {
        #expect(HookRouter.reported(.state(.asking, reason: "q")) == .asking)
        #expect(HookRouter.reported(.guess(.asking, reason: nil)) == .done)
        #expect(HookRouter.reported(.atPrompt) == .idle)
        #expect(HookRouter.reported(.title("t")) == nil)
        #expect(HookRouter.reported(.taskExit(code: 0)) == nil)
    }

    // MARK: Reviews

    @Test func aReviewerThatExitsNonZeroDidNotStart() {
        #expect(HookRouter.review(.taskExit(code: 1), worked: false) == .didNotStart)
        #expect(HookRouter.review(.taskExit(code: 0), worked: true) == .ignore)
        #expect(HookRouter.review(.notify("hi"), worked: true) == .ignore)
    }

    @Test func aReviewEndsWhenItsTurnIsOverAfterWorking() {
        #expect(HookRouter.review(.state(.working, reason: nil), worked: false)
            == .turn(.init(state: .working, worked: true, ended: false)))
        #expect(HookRouter.review(.state(.idle, reason: nil), worked: false)
            == .turn(.init(state: .idle, worked: false, ended: false)))
        #expect(HookRouter.review(.state(.idle, reason: nil), worked: true)
            == .turn(.init(state: .idle, worked: true, ended: true)))
        #expect(HookRouter.review(.guess(.asking, reason: nil), worked: true)
            == .turn(.init(state: .done, worked: true, ended: true)))
        #expect(HookRouter.review(.state(.exited, reason: nil), worked: false)
            == .turn(.init(state: .exited, worked: false, ended: true)))
        #expect(HookRouter.review(.state(.asking, reason: nil), worked: true)
            == .turn(.init(state: .asking, worked: true, ended: false)))
    }

    // MARK: Runs

    @Test func aRunThatExitsNonZeroFailedItsSetup() {
        #expect(HookRouter.run(.taskExit(code: 2), worked: true, recorded: .some(nil)) == .setupFailed)
        #expect(HookRouter.run(.taskExit(code: 0), worked: true, recorded: .some(nil)) == .ignore)
    }

    @Test func aRunsUsageGoesOnItsRecordWhenItChangesIt() {
        let report = UsageReport(model: "m", totals: TokenCounts(input: 3, output: 4))
        let applied = AgentUsage().applying(report)
        #expect(HookRouter.run(.usage(report), worked: false, recorded: .some(nil)) == .usage(applied))
        #expect(HookRouter.run(.usage(report), worked: false, recorded: .some(applied)) == .ignore)
        // A run with no record: its usage is nobody's.
        #expect(HookRouter.run(.usage(report), worked: false, recorded: nil) == .ignore)
    }

    @Test func aRunEndsWhenItsTurnIsOverQuestionOrNot() {
        #expect(HookRouter.run(.state(.working, reason: nil), worked: false, recorded: nil)
            == .turn(.init(state: .working, worked: true, ended: false)))
        #expect(HookRouter.run(.atPrompt, worked: true, recorded: nil)
            == .turn(.init(state: .idle, worked: true, ended: true)))
        #expect(HookRouter.run(.atPrompt, worked: false, recorded: nil)
            == .turn(.init(state: .idle, worked: false, ended: false)))
        #expect(HookRouter.run(.guess(.asking, reason: "?"), worked: true, recorded: nil)
            == .turn(.init(state: .done, worked: true, ended: true)))
        #expect(HookRouter.run(.lastMessage("bye"), worked: true, recorded: nil) == .ignore)
    }

    // MARK: Takeover

    @Test func anotherKnownAgentTakesThePaneOver() {
        let known: (String) -> Bool = { $0 != "mystery" }
        #expect(HookRouter.takeover(by: "codex", current: "claude", known: known) == "codex")
        #expect(HookRouter.takeover(by: "claude", current: "claude", known: known) == nil)
        #expect(HookRouter.takeover(by: "mystery", current: "claude", known: known) == nil)
        #expect(HookRouter.takeover(by: nil, current: "claude", known: known) == nil)
    }

    // MARK: Session state

    @Test func aStateReportIsNewsEvenWhenNothingChanges() {
        let working = ObservedState(.working)
        let turn = HookRouter.session(.state(.working, reason: nil), current: working, resets: nil)
        #expect(turn?.state == working)
        #expect(turn?.settles == false)
        #expect(turn?.continues == false)
    }

    @Test func aReportTheCurrentStateOverridesIsNotNews() {
        // Cursor's done after the reply that asked you: the question stands.
        let asked = ObservedState(.asking, source: .guessed, reason: TurnEnd.question)
        #expect(HookRouter.session(.state(.done, reason: nil), current: asked, resets: nil) == nil)
    }

    @Test func aGuessOrPromptThatChangesNothingIsNotNews() {
        let done = ObservedState(.done)
        #expect(HookRouter.session(.atPrompt, current: done, resets: nil) == nil)
        let gone = ObservedState(.exited)
        #expect(HookRouter.session(.guess(.asking, reason: nil), current: gone, resets: nil) == nil)
    }

    @Test func aPromptAfterWorkingIsIdleAndSettlesAndContinues() {
        let turn = HookRouter.session(.atPrompt, current: ObservedState(.working), resets: nil)
        #expect(turn?.state == ObservedState(.idle))
        #expect(turn?.settles == true)
        #expect(turn?.continues == true)
    }

    @Test func aDoneTurnSettlesButDoesNotContinue() {
        let turn = HookRouter.session(.state(.done, reason: nil), current: ObservedState(.working), resets: nil)
        #expect(turn?.settles == true)
        #expect(turn?.continues == false)
    }

    @Test func aGuessReplacesAReportedState() {
        let turn = HookRouter.session(.guess(.asking, reason: "q"), current: ObservedState(.done), resets: nil)
        #expect(turn?.state == ObservedState(.asking, source: .guessed, reason: "q"))
    }

    @Test func rateLimitedSaysWhenItLifts() {
        let working = ObservedState(.working)
        #expect(HookRouter.session(.state(.limited, reason: nil), current: working, resets: "resets 5pm")?
            .state.reason == "rate limited · resets 5pm")
        #expect(HookRouter.session(.state(.limited, reason: "5h"), current: working, resets: "resets 5pm")?
            .state.reason == "5h · resets 5pm")
        #expect(HookRouter.session(.state(.limited, reason: nil), current: working, resets: nil)?
            .state.reason == nil)
        // Only rate limited reads when it lifts.
        var asked = 0
        _ = HookRouter.session(.state(.asking, reason: nil), current: working, resets: {
            asked += 1
            return "x"
        }())
        #expect(asked == 0)
    }

    @Test func otherKindsAreNotASessionState() {
        #expect(HookRouter.session(.title("t"), current: ObservedState(.idle), resets: nil) == nil)
    }
}
