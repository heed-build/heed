import Foundation
@testable import HeedCore
import Testing

struct HunchTrainingRunTests {
    /// The race: Stop cancelled the outer task while the detached run went on and adopted its head. A run asked to
    /// stop never adopts, even when it finishes anyway.
    @Test func aStoppedRunThatFinishesAnywayDoesNotAdopt() {
        var run = HunchTrainingRun.idle
        let started = run.start()
        #expect(started)
        run.progressed(0.5)
        #expect(run == .running(0.5))
        let stopped = run.stop()
        #expect(stopped)
        let v1 = run.finish(succeeded: true, cancelled: false)
        #expect(v1 == .stopped)
        #expect(run == .idle)
    }

    @Test func lateProgressAndASecondStartAreIgnored() {
        var run = HunchTrainingRun.idle
        run.progressed(0.3)
        #expect(run == .idle)
        _ = run.start()
        let again = run.start()
        #expect(!again)
        _ = run.stop()
        run.progressed(0.9)
        #expect(run == .stopping)
        #expect(run.progress == .some(nil))
    }

    @Test func howARunEnds() {
        var run = HunchTrainingRun.idle
        _ = run.start()
        let v2 = run.finish(succeeded: true, cancelled: false)
        #expect(v2 == .finished)
        _ = run.start()
        let v3 = run.finish(succeeded: false, cancelled: false)
        #expect(v3 == .failed)
        _ = run.start()
        let v4 = run.finish(succeeded: false, cancelled: true)
        #expect(v4 == .stopped)
        #expect(HunchTrainingRun.idle.progress == nil)
    }
}

struct AgentConversationTests {
    @Test func aTurnGathersTheReplyOnlyWhileItRuns() {
        var conversation = AgentConversation(root: "/r")
        let v5 = conversation.beginTurn()
        #expect(v5 == nil)
        conversation.received("early")
        #expect(conversation.exitInterrupts)
        // No client yet: no turn even once the session is known.
        conversation.connected(session: "s")
        let v6 = conversation.beginTurn()
        #expect(v6 == nil)
        #expect(!conversation.exitInterrupts)
        let v7 = conversation.endTurn()
        #expect(v7 == nil)
    }

    /// Events, replies and clients for an earlier conversation are dropped: the slot holds another by then.
    @Test func whatArrivesForAClosedOrReplacedConversationIsDropped() {
        var slot: AgentConversation? = AgentConversation(root: "/r")
        let first = slot!.id
        let client = AgentConversation.close(&slot)
        #expect(client == nil)
        let late = AgentConversation.update(&slot, first) { $0.connected(session: "s") }
        #expect(!late)
        slot = AgentConversation(root: "/r")
        let stale = AgentConversation.update(&slot, first) { $0.failed("old") }
        #expect(!stale)
        #expect(slot?.phase == .connecting)
        let current = AgentConversation.update(&slot, slot!.id) { $0.failed("now") }
        #expect(current)
        #expect(slot?.phase == .failed("now"))
    }

    @Test func pathsAccumulate() {
        var conversation = AgentConversation(root: nil)
        conversation.read(["a"])
        conversation.read(["b", "c"])
        #expect(conversation.paths == ["a", "b", "c"])
    }
}

struct ConversationChecksTests {
    /// The race: two checks of a session ran off the main actor and reported in any order; the older one could land
    /// last and win.
    @Test func anOlderCheckReportingLastIsIgnored() {
        var checks = ConversationChecks()
        let older = checks.begin(["s"])
        let newer = checks.begin(["s"])
        // The older one answering while the newer still runs is not the answer.
        let early = checks.report("s", exists: true, generation: older)
        #expect(!early)
        #expect(checks["s"] == .checking(generation: newer, last: nil))
        let applied = checks.report("s", exists: false, generation: newer)
        #expect(applied)
        let stale = checks.report("s", exists: true, generation: older)
        #expect(!stale)
        #expect(checks["s"] == .missing)
        #expect(!checks["s"].onDisk)
    }

    @Test func unknownIsNotThereAndARecheckKeepsTheLastAnswer() {
        var checks = ConversationChecks()
        #expect(checks["s"] == .unknown)
        #expect(!checks["s"].onDisk)
        let first = checks.begin(["s"])
        checks.report("s", exists: true, generation: first)
        #expect(checks["s"].onDisk)
        _ = checks.begin(["s"])
        #expect(checks["s"].onDisk)
        checks.forget("s")
        #expect(checks["s"] == .unknown)
        // A report for a check from before it was forgotten does not bring it back.
        let late = checks.report("s", exists: true, generation: first)
        #expect(!late)
        checks.set("s", exists: true)
        #expect(checks["s"] == .present)
    }
}

struct PromotionFlowTests {
    private func ask(_ session: String) -> HandoffAsk {
        HandoffAsk.begin(
            session: session, agent: "claude", state: .working, hasAgentPane: true, host: nil, timeout: 60,
            now: Date(timeIntervalSince1970: 0)
        )!
    }

    /// The race: a delivery matched the ask by session only, so one sent for an ask that closed landed on the next
    /// ask for the same session.
    @Test func aDeliveryLandsOnlyOnTheAskItWasSentFor() {
        var flow = PromotionFlow(GoalPromotion(session: "s1", title: "T", statement: "x"))
        let first = ask("s1")
        flow.ask(first)
        let second = ask("s1")
        flow.ask(second)
        let late = flow.updateAsk(first.id) { $0.delivered(.failed("old")) }
        #expect(!late)
        #expect(flow.handoff == second)
        let current = flow.updateAsk(second.id) { $0.skip() }
        #expect(current)
        #expect(flow.handoff?.isOpen == false)
    }

    @Test func noAskForAnotherSession() {
        var flow = PromotionFlow(GoalPromotion(session: "s1", title: "T", statement: "x"))
        let other = flow.ask(ask("s2"))
        #expect(!other)
        #expect(flow.handoff == nil)
        flow.ask(ask("s1"))
        flow.edit { $0.title = "Renamed" }
        #expect(flow.handoff != nil)
        flow.edit { $0.session = "s2" }
        #expect(flow.handoff == nil)
    }
}

struct WizardActivityTests {
    /// The race: a plan turn still running when the goal was discarded wrote to the deleted goal.
    @Test func aTurnEndingAfterDiscardIsDropped() {
        var activity = WizardActivity.idle
        let turn = activity.think()!
        let (allowed, cancel) = activity.discard()
        #expect(allowed)
        #expect(cancel == turn)
        let applied = activity.thought(turn)
        #expect(!applied)
        let v8 = activity.think()
        #expect(v8 == nil)
        let twice = activity.discard()
        #expect(!twice.allowed)
        activity.discardFailed()
        #expect(activity == .idle)
    }

    @Test func aTurnEndsOnce() {
        var activity = WizardActivity.idle
        let turn = activity.think()!
        let first = activity.thought(turn)
        #expect(first)
        let again = activity.thought(turn)
        #expect(!again)
    }
}
