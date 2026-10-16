import Foundation
@testable import HeedCore
import Testing

struct QuietTurnTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds one observation and returns whether it was quiet.
    private func observe(
        _ quiet: inout QuietTurn, _ text: String, at seconds: TimeInterval, hook: TimeInterval? = nil,
        after: TimeInterval = QuietTurn.after
    ) -> Bool {
        quiet.isQuiet(
            pane: "p", text: text, lastHook: hook.map { start.addingTimeInterval($0) },
            now: start.addingTimeInterval(seconds), after: after
        )
    }

    @Test func quietOnlyWhenTheScreenAndHooksAreStillLongEnough() {
        var quiet = QuietTurn()
        let results = [
            observe(&quiet, "a", at: 0),
            observe(&quiet, "a", at: 10),
            observe(&quiet, "a", at: 21),
            // The screen moved: it starts over.
            observe(&quiet, "b", at: 22),
            observe(&quiet, "b", at: 30),
            // A recent hook keeps it from being quiet, however still the screen.
            observe(&quiet, "b", at: 50, hook: 40),
            observe(&quiet, "b", at: 61, hook: 40),
        ]
        #expect(results == [false, false, true, false, false, false, true])
    }

    @Test func codexInterruptLeavesTheSessionIdle() {
        #expect(AgentIntegration.codexHook(event: "Interrupt", input: ["turn_id": "t1"]) == [
            .state(.idle, reason: "interrupted"),
        ])
        #expect(AgentIntegration.codexEvents.contains("Interrupt"))
    }

    @Test func runsWaitLongerAndForgettingStartsOver() {
        var quiet = QuietTurn()
        let first = observe(&quiet, "x", at: 0, after: QuietTurn.runAfter)
        let early = observe(&quiet, "x", at: 30, after: QuietTurn.runAfter)
        let late = observe(&quiet, "x", at: 61, after: QuietTurn.runAfter)
        quiet.forget(pane: "p")
        let afterForget = observe(&quiet, "x", at: 62)
        #expect([first, early, late, afterForget] == [false, false, true, false])
        #expect(QuietTurn.applies(to: "cursor"))
        #expect(QuietTurn.applies(to: "codex"))
        #expect(!QuietTurn.applies(to: "claude"))
    }
}
