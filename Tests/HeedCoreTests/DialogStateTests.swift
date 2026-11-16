import Foundation
@testable import HeedCore
import Testing

struct DialogStackTests {
    private enum Kind: Hashable, Sendable { case form, confirm, picker }

    @Test func oneOfEachKindAndClosingOneLeavesTheOthers() {
        var stack = DialogStack<Kind, String>()
        #expect(stack.isEmpty)
        stack.set(.form, "start work")
        stack.set(.confirm, "trust?")
        stack.set(.form, "start work, edited")
        #expect(stack.kinds == [.form, .confirm])
        #expect(stack[.form] == "start work, edited")
        stack.set(.confirm, nil)
        #expect(stack.kinds == [.form])
        // Closing what is not open closes nothing else.
        stack.set(.picker, nil)
        #expect(stack.kinds == [.form])
        #expect(!stack.isEmpty)
        stack.set(.form, nil)
        #expect(stack.isEmpty)
        #expect(stack[.form] == nil)
    }
}

struct StartWorkSessionTests {
    private func session() -> StartWorkSession {
        StartWorkSession(form: StartWorkForm(repos: [], settings: .default, prompt: "fix it"))
    }

    @Test func aStartWaitsForTrustThenLaunches() {
        var work = session()
        let start = work.awaitTrust()
        #expect(start != nil)
        #expect(work.isStarting)
        // A second ⌘↩ while it waits does not start again.
        let again = work.awaitTrust()
        #expect(again == nil)
        let answered = work.trustAnswered(start!)
        #expect(answered)
        #expect(work.phase == .launching)
        let late = work.trustAnswered(start!)
        #expect(!late)
    }

    /// The race: a trust question cancelled or replaced used to leave "Starting…" for good. Its answer (cancel counts)
    /// moves the start on; one for an earlier start is ignored.
    @Test func anAnswerForAnotherStartIsIgnored() {
        var work = session()
        _ = work.awaitTrust()
        let stale = work.trustAnswered(UUID())
        #expect(!stale)
        #expect(work.isStarting)
        work.fail("start failed: boom")
        #expect(!work.isStarting)
        #expect(work.error == "start failed: boom")
        // The dialog stays open to try again, and the next start is not stuck behind the last.
        let next = work.awaitTrust()
        #expect(next != nil)
        #expect(work.error == nil)
    }

    @Test func aFailureShowsUntilTheDialogOpensAgainOrStarts() {
        var work = session()
        work.fail("@mini does not answer")
        #expect(work.error == "@mini does not answer")
        work.clearFailure()
        #expect(work.phase == .editing)
        let launched = work.launch()
        #expect(launched)
        let twice = work.launch()
        #expect(!twice)
    }
}
