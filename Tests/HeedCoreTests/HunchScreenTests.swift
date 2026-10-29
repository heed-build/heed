import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_900_000_000)

struct HunchScreenTests {
    @Test func theQuestionIsOneHunchTakes() {
        #expect(HunchRouting.hunchTakes(HunchScreen.question))
        guard case let .choice(_, options) = HunchScreen.question else {
            Issue.record("not a choice")
            return
        }
        #expect(options == ["working", "waiting for input", "stuck: looping or erroring", "done"])
        for state in HunchScreen.State.allCases {
            #expect(HunchScreen.State(option: state.option) == state)
        }
        #expect(HunchScreen.State(option: "waiting") == nil)
    }

    @Test func anAnswerIsAReadingOnlyWhenItPicksAnOption() {
        let answer = Answer(choice: "stuck: looping or erroring", probabilities: [:], confidence: 0.81)
        #expect(HunchScreen.Reading(answer, at: now) == .init(state: .stuck, confidence: 0.81, at: now))
        #expect(HunchScreen.Reading(Answer(choice: "maybe", probabilities: [:], confidence: 1), at: now) == nil)
        #expect(HunchScreen.Reading(Answer(probability: 0.9, probabilities: [:], confidence: 0.9), at: now) == nil)
        #expect(HunchScreen.Reading(state: .waiting, confidence: 0.874, at: now)
            .line == "waiting for input · Hunch 87%")
    }

    @Test func theHooksLabelThreeOfTheFourStates() {
        #expect(HunchScreen.label(.asking) == .waiting)
        #expect(HunchScreen.label(.blocked) == .waiting)
        #expect(HunchScreen.label(.working) == .working)
        #expect(HunchScreen.label(.done) == .done)
        #expect(HunchScreen.label(.idle) == nil)
        #expect(HunchScreen.label(.limited) == nil)
        #expect(HunchScreen.label(.exited) == nil)
    }

    @Test func panesAreReadOnlyWithHunchChosenAndItsModelDownloaded() {
        #expect(HunchScreen.reads(decider: .hunch, modelReady: true))
        #expect(!HunchScreen.reads(decider: .hunch, modelReady: false))
        #expect(!HunchScreen.reads(decider: .local, modelReady: true))
        #expect(!HunchScreen.reads(decider: .model, modelReady: true))
        #expect(!HunchScreen.reads(decider: nil, modelReady: true))
    }

    @Test func aPaneIsReadOnceAMinuteAtMostAndOnlyWhenItChanged() {
        var throttle = HunchScreen.Throttle()
        func due(_ pane: String, _ text: String, _ seconds: TimeInterval) -> Bool {
            throttle.due(pane: pane, text: text, now: now.addingTimeInterval(seconds))
        }
        #expect(due("p", "a", 0))
        // The same text: never, however long it stays.
        #expect(!due("p", "a", 600))
        // Changed, but within the minute.
        #expect(!due("p", "b", 59))
        #expect(due("p", "b", 60))
        // Each pane on its own.
        #expect(due("q", "b", 61))
        throttle.forget(pane: "p")
        #expect(due("p", "b", 61))
    }

    @Test func whatHunchReadsIsTheCleanedLastTwentyLinesAsSnapshotsKeepThem() {
        let screen = (1 ... 40).map { "\u{1B}[32mline \($0)\u{1B}[0m" }.joined(separator: "\n")
        let read = HunchScreen.state(ofScreen: screen).split(separator: "\n")
        #expect(read.count == 20 && read.first == "line 21" && read.last == "line 40")
        // A snapshot keeps the cleaned screen; training takes the tail of it: the same text.
        #expect(HunchScreen.tail(ScreenText.clean(screen, lines: ScreenSnapshot.lines))
            == HunchScreen.state(ofScreen: screen))
    }

    @Test func aReadingMakesASessionStateOnlyForWhatItsAgentCannotReport() {
        let waiting = HunchScreen.Reading(state: .waiting, confidence: 0.9, at: now)
        let done = HunchScreen.Reading(state: .done, confidence: 0.9, at: now)
        #expect(HunchScreen.sessionState(waiting, reported: [.working, .done]) == .asking)
        #expect(HunchScreen.sessionState(waiting, reported: [.working, .asking]) == .blocked)
        #expect(HunchScreen.sessionState(waiting, reported: [.asking, .blocked]) == nil)
        #expect(HunchScreen.sessionState(done, reported: [.working]) == .done)
        #expect(HunchScreen.sessionState(done, reported: [.working, .done]) == nil)
        #expect(HunchScreen.sessionState(.init(state: .stuck, confidence: 1, at: now), reported: []) == nil)
        #expect(HunchScreen.sessionState(.init(state: .working, confidence: 1, at: now), reported: []) == nil)
    }
}
