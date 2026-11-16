import Foundation
@testable import HeedCore
import Testing

struct LoadTests {
    @Test func aLoadKeepsWhatWasThereWhileItRuns() {
        var load = Load<Int>.loaded(1)
        load.start()
        #expect(load.isLoading)
        #expect(load.value == 1)
    }

    @Test func aReplacedLoadFinishingLateChangesNothing() {
        var load = Load<String>.idle
        let first = load.start()
        let second = load.start()
        let r1 = load.finish(first, with: "old")
        #expect(!r1)
        #expect(load.isLoading)
        #expect(load.token == second)
        let r2 = load.finish(second, with: "new")
        #expect(r2)
        #expect(load == .loaded("new"))
        // The first one landing after the second has finished does not overwrite it either.
        let r3 = load.finish(first, with: "old")
        #expect(!r3)
        #expect(load == .loaded("new"))
    }

    /// The diff overlay's race: a cancelled load giving up must not end the load that replaced it.
    @Test func aCancelledLoadGivingUpLeavesTheNextOneLoading() {
        var load = Load<Int>.loaded(1)
        let cancelled = load.start()
        let next = load.start()
        let r4 = load.abandon(cancelled)
        #expect(!r4)
        #expect(load.isLoading)
        let r5 = load.abandon(next)
        #expect(r5)
        #expect(load == .loaded(1))
    }

    @Test func aStaleFailureIsIgnored() {
        var load = Load<Int>.idle
        let first = load.start()
        _ = load.start()
        let r6 = load.fail(first, "timed out")
        #expect(!r6)
        #expect(load.error == nil)
        #expect(load.isLoading)
    }

    /// A thread that failed shows why only until it is asked for again: the retry shows "loading", not the old error.
    @Test func aRetryForgetsTheEarlierFailureButKeepsTheValue() {
        var load = Load<Int>.loaded(1)
        let token = load.start()
        load.fail(token, "offline")
        #expect(load.error == "offline")
        #expect(load.value == 1)
        load.start()
        #expect(load.error == nil)
        #expect(load.isLoading)
        #expect(load.value == 1)
    }

    @Test func nothingFinishesWhenNothingIsLoading() {
        var load = Load<Int>.idle
        let r7 = load.finish(LoadToken(), with: 1)
        #expect(!r7)
        let r8 = load.fail(LoadToken(), "x")
        #expect(!r8)
        let r9 = load.abandon(LoadToken())
        #expect(!r9)
        #expect(load == .idle)
    }
}

struct TestRunTests {
    @Test func aRunningTestHasNoAnswerOrError() {
        let run = TestRun<DecisionTestAnswer>.running
        #expect(run.isRunning)
        #expect(run.answer == nil)
        #expect(run.error == nil)
    }

    @Test func aTestStartsUnlessOneIsRunning() {
        #expect(TestRun<AgentTestAnswer>.canStart(over: nil))
        #expect(!TestRun<AgentTestAnswer>.canStart(over: .running))
        #expect(TestRun<AgentTestAnswer>.canStart(over: .failed("x")))
        #expect(TestRun.canStart(over: .passed(AgentTestAnswer(text: "hi"))))
    }

    @Test func summaries() {
        let agent = AgentTestAnswer(text: "Hello!", model: "claude-haiku", seconds: 2.94, cost: 0.00026)
        #expect(agent.summary == "“Hello!” · claude-haiku · 2.9s · $0.0003")
        #expect(AgentTestAnswer(text: "Hi").summary == "“Hi”")
        #expect(DecisionTestAnswer(text: "done (confidence 90%)", seconds: 0.6).summary
            == "done (confidence 90%) · 0.6s")
    }
}

struct SyncQueueTests {
    /// The race it fixes: gr during a poll was dropped by `guard !syncing`; now it runs once the poll ends.
    @Test func aForcedAskDuringASyncRunsAfterIt() {
        var queue = SyncQueue()
        let poll = queue.ask(SyncRequest(force: false, parts: []))
        #expect(poll == SyncRequest(force: false, parts: []))
        let r101 = queue.ask(SyncRequest(force: true, parts: []))
        #expect(r101 == nil)
        let next = queue.finished()
        #expect(next?.force == true)
        #expect(queue.running)
        let r102 = queue.finished()
        #expect(r102 == nil)
        #expect(!queue.running)
    }

    @Test func asksMadeMeanwhileMergeIntoOne() {
        var queue = SyncQueue()
        _ = queue.ask(SyncRequest(force: false, parts: []))
        let r103 = queue.ask(SyncRequest(force: false, parts: [.pulls]))
        #expect(r103 == nil)
        let r104 = queue.ask(SyncRequest(force: false, parts: [.issues]))
        #expect(r104 == nil)
        let next = queue.finished()
        #expect(next?.parts == [.pulls, .issues])
        #expect(next?.scheduled == false)
        let r105 = queue.finished()
        #expect(r105 == nil)
    }

    @Test func aSingleAskFetchesWhatItDidBefore() {
        let due: (Bool) -> Set<GitHubPart> = { force in force ? Set(GitHubPart.allCases) : [.inbox] }
        // Named parts: just those, no teams.
        let named = SyncRequest(force: true, parts: [.pulls])
        #expect(named.parts(due: due) == [.pulls])
        #expect(!named.refreshesTeams)
        // Nothing named: the schedule's, every part and the teams when forced.
        #expect(SyncRequest(force: false, parts: []).parts(due: due) == [.inbox])
        let forced = SyncRequest(force: true, parts: [])
        #expect(forced.parts(due: due) == Set(GitHubPart.allCases))
        #expect(forced.refreshesTeams)
    }

    @Test func aMergedAskKeepsTheScheduleAndTheNamedParts() {
        let due: (Bool) -> Set<GitHubPart> = { _ in [.inbox] }
        let merged = SyncRequest(force: false, parts: [.pulls]).merged(with: SyncRequest(force: true, parts: []))
        #expect(merged.force)
        #expect(merged.refreshesTeams)
        #expect(merged.parts(due: due) == [.inbox, .pulls])
    }
}
