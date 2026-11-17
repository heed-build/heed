import Foundation
@testable import HeedCore
import Testing

/// Whether a PR's queued feedback goes out, and where: each gate in the order the app meets it.
struct FeedbackDeliveryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let worker = SwarmWorker(
        id: "w-a", task: "g/a", owner: GoalItem.Owner(agent: "codex", model: nil), host: "lead", repo: "acme/site",
        branch: "swarm/g/a", base: "main", worktree: "/wt/a", startedAt: now, endedAt: now, outcome: .turnOver
    )

    /// Auto-feed on and watching, an open PR from someone trusted, a session that tracks it, no run working: heed
    /// starts a run of its own.
    private func facts(
        explicit: Bool = false,
        trusted: Bool? = true,
        handback: SwarmHandback.Route = .pilot("its swarm is gone"),
        _ change: (inout FeedbackDelivery.Facts) -> Void = { _ in }
    ) -> FeedbackDelivery.Facts {
        var facts = FeedbackDelivery.Facts(
            explicit: explicit, queued: true, causedByPullEvent: true, state: .open,
            effective: PullFeedback.Effective(watching: true, green: .auto, maxRounds: 3),
            roundsExhausted: false, paused: false, isFixture: false, tutor: false, runIn: .background, swarm: false,
            hasSession: true, runWorking: false, needsHandback: false,
            trusted: { trusted }, handback: { handback }
        )
        change(&facts)
        return facts
    }

    private func decide(_ facts: FeedbackDelivery.Facts) -> FeedbackDelivery.Decision {
        FeedbackDelivery.decide(facts)
    }

    @Test func startsARunWhenEverythingAllows() {
        #expect(decide(facts()) == .startRun(handback: nil))
    }

    @Test func nothingQueuedSendsNothing() {
        #expect(decide(facts(explicit: true) { $0.queued = false }) == .nothingQueued)
    }

    @Test func heedsOwnSendingIsCausedByThePullEvent() {
        #expect(decide(facts { $0.causedByPullEvent = false }) == .attributeCause)
        // You sending it is its own cause.
        #expect(decide(facts(explicit: true) { $0.causedByPullEvent = false }) == .startRun(handback: nil))
    }

    @Test func aMergedOrClosedPullHasNothingLeftToFix() {
        #expect(decide(facts { $0.state = .merged }) == .finished(.merged))
        #expect(decide(facts(explicit: true) { $0.state = .closed }) == .finished(.closed))
        // Not known yet counts as open.
        #expect(decide(facts { $0.state = nil }) == .startRun(handback: nil))
    }

    @Test func autoFeedHoldsWhatItDoesNotSend() {
        let off = PullFeedback.Effective(watching: true, green: .ask, maxRounds: 3)
        #expect(decide(facts { $0.effective = off }) == .held(stuck: false))
        let unwatched = PullFeedback.Effective(watching: false, green: .auto, maxRounds: 3)
        #expect(decide(facts { $0.effective = unwatched }) == .held(stuck: false))
        #expect(decide(facts { $0.paused = true }) == .held(stuck: false))
        #expect(decide(facts { $0.roundsExhausted = true }) == .held(stuck: true))
        // Out of rounds with auto-feed off is not stuck: it was never sending.
        #expect(decide(facts { $0.roundsExhausted = true
            $0.effective = off
        }) == .held(stuck: false))
        // You send it whatever auto-feed says.
        #expect(decide(facts(explicit: true) { $0.effective = off
            $0.roundsExhausted = true
            $0.paused = true
        }) == .startRun(handback: nil))
    }

    @Test func onItsOwnARunStartsOnlyForATrustedAuthor() {
        #expect(decide(facts(trusted: false)) == .heldForAuthor)
        #expect(decide(facts(trusted: nil)) == .resolveTrust)
        #expect(decide(facts(explicit: true, trusted: false)) == .startRun(handback: nil))
    }

    @Test func theTrustBookIsReadOnlyPastTheGates() {
        var reads = 0
        let counting = facts {
            $0.state = .merged
            $0.trusted = {
                reads += 1
                return true
            }
        }
        _ = decide(counting)
        #expect(reads == 0)
        var fixture = counting
        fixture.state = .open
        fixture.isFixture = true
        _ = decide(fixture)
        #expect(reads == 0)
    }

    @Test func aHelperTakesItUnlessThePullIsASwarms() {
        #expect(decide(facts { $0.runIn = .helper }) == .helper)
        #expect(decide(facts { $0.runIn = .helper
            $0.swarm = true
        }) == .startRun(handback: nil))
        // A helper needs no session.
        #expect(decide(facts { $0.runIn = .helper
            $0.hasSession = false
        }) == .helper)
    }

    @Test func withoutASessionNothingIsSent() {
        #expect(decide(facts { $0.hasSession = false }) == .noSession)
    }

    @Test func aFixtureDoesNoIO() {
        #expect(decide(facts(trusted: false) { $0.isFixture = true }) == .fixture(tutor: false))
        #expect(decide(facts { $0.isFixture = true
            $0.tutor = true
        }) == .fixture(tutor: true))
        // Not even a helper.
        #expect(decide(facts { $0.isFixture = true
            $0.runIn = .helper
        }) == .fixture(tutor: false))
    }

    @Test func runInSessionTypesItUnlessThePullIsASwarms() {
        #expect(decide(facts { $0.runIn = .session }) == .inSession)
        #expect(decide(facts { $0.runIn = .session
            $0.swarm = true
        }) == .startRun(handback: nil))
    }

    @Test func oneRunPerPullAtATime() {
        #expect(decide(facts { $0.runWorking = true }) == .waitForRun)
    }

    @Test func aSwarmsHandbackGoesWhereItsRouteSays() {
        let swarm: (inout FeedbackDelivery.Facts) -> Void = {
            $0.swarm = true
            $0.needsHandback = true
        }
        #expect(decide(facts(handback: .worker(Self.worker), swarm)) == .returnToWorker(Self.worker))
        #expect(decide(facts(handback: .wait("its worker is on it"), swarm)) == .waitForWorker("its worker is on it"))
        #expect(decide(facts(handback: .pilot("gone"), swarm)) == .startRun(handback: "gone"))
        // Items that need no worker, or a pull that is no swarm's, start a run with no handback.
        #expect(decide(facts(handback: .worker(Self.worker)) { $0.swarm = true }) == .startRun(handback: nil))
        #expect(decide(facts(handback: .worker(Self.worker)) { $0.needsHandback = true }) == .startRun(handback: nil))
    }
}
