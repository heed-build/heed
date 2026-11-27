import Foundation
@testable import HeedCore
import Testing

/// ⎋ in Browse takes the same layers off in the same order, whatever is stacked.
struct BrowseEscapeTests {
    private func state(
        overlay: Bool = false, reader: Bool = false, bulk: Bool = false, pushed: Bool = false, picks: Bool = false,
        sheet: Bool = false
    ) -> BrowseEscape.State {
        var state = BrowseEscape.State()
        state.overlay = overlay
        state.reader = reader
        state.bulk = bulk
        state.pushedReader = pushed
        state.picks = picks
        state.jumpSheet = sheet
        return state
    }

    /// Every combination of the six layers, against the order they are taken off in.
    @Test func everyCombinationTakesTheInnermostLayerFirst() {
        for bits in 0 ..< 64 {
            let on = { (bit: Int) in bits & (1 << bit) != 0 }
            let s = state(
                overlay: on(0), reader: on(1), bulk: on(2), pushed: on(3), picks: on(4), sheet: on(5)
            )
            let expected: BrowseEscape.Step =
                if on(0) || on(1) { .closeTopmost }
                else if on(2) { .cancelBulk }
                else if on(3) { .backFromReader }
                else if on(4) { .clearPicks }
                else if on(5) { .closeJumpSheet }
                else { .closeRun }
            #expect(BrowseEscape.next(state: s) == expected, "bits \(bits)")
        }
    }

    @Test func helpOverARunClosesHelpNotTheRun() {
        #expect(BrowseEscape.next(state: state(overlay: true, picks: true)) == .closeTopmost)
    }

    @Test func aPushedReaderGoesBackBeforeThePicksOrARun() {
        #expect(BrowseEscape.next(state: state(pushed: true, picks: true)) == .backFromReader)
        #expect(BrowseEscape.next(state: state(pushed: true)) == .backFromReader)
    }

    @Test func nothingStackedLeavesTheRunToItsOwnClose() {
        #expect(BrowseEscape.next(state: state()) == .closeRun)
    }
}
