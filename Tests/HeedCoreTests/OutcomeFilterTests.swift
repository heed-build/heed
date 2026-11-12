@testable import HeedCore
import Testing

/// `history.outcome`: the key cycles, a click on a chip names one.
@Suite struct OutcomeFilterTests {
    @Test func noWordsCyclesThroughEveryOutcomeAndBackToAll() {
        var current: Outcome?
        var seen: [Outcome?] = []
        for _ in 0 ... Outcome.allCases.count {
            current = Outcome.filter(after: current, named: [])
            seen.append(current)
        }
        #expect(seen == Outcome.allCases.map(Optional.some) + [nil])
    }

    @Test func aNameSetsThatOutcomeWhateverWasOn() {
        #expect(Outcome.filter(after: nil, named: ["merged"]) == .merged)
        #expect(Outcome.filter(after: .closed, named: ["Merged"]) == .merged)
        #expect(Outcome.filter(after: .merged, named: ["merged"]) == .merged)
    }

    @Test func allTakesTheFilterOff() {
        #expect(Outcome.filter(after: .abandoned, named: ["all"]) == nil)
    }

    /// The chip passes the raw value with its space; typed on the `:` line it splits into two words.
    @Test func cleanedUpIsFoundHoweverItIsWritten() {
        for words in [["cleaned up"], ["cleaned", "up"], ["cleaned-up"], ["cleanedup"]] {
            #expect(Outcome.filter(after: nil, named: words) == .cleanedUp, "\(words)")
        }
    }

    @Test func aNameThatIsNoOutcomeKeepsTheFilter() {
        #expect(Outcome.filter(after: .closed, named: ["nonsense"]) == .closed)
    }
}
