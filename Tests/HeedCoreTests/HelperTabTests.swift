import Foundation
@testable import HeedCore
import Testing

/// `send_to = "tab"` and `send_after_idle`: a dedicated agent for get it green / merged, and not sending while you
/// work.
struct HelperTabTests {
    @Test func whichTabAPRNeedsAndWhenItIsDone() {
        #expect(HelperTabs.goal(for: .failing(2)) == .green)
        #expect(HelperTabs.goal(for: .changes(1)) == .green)
        #expect(HelperTabs.goal(for: .conflicted("conflicts")) == .merged)
        #expect(HelperTabs.goal(for: .green) == nil)
        #expect(HelperTabs.done(.green, status: .green))
        #expect(HelperTabs.done(.green, status: .passing))
        #expect(!HelperTabs.done(.green, status: .failing(1)))
        #expect(!HelperTabs.done(.merged, status: .green))
        #expect(HelperTabs.done(.merged, status: .closed(merged: true)))
        #expect(HelperTabs.canClose(.idle) && HelperTabs.canClose(nil) && !HelperTabs.canClose(.working))
        let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 12)
        #expect(HelperTabs.title(.green, ref: ref, pullCount: 1) == "get it green")
        #expect(HelperTabs.title(.merged, ref: ref, pullCount: 2) == "get it merged #12")
    }

    @Test func aBusyHelperPutsItsSessionInNeedsYou() {
        let session = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.idle))
        #expect(SessionGroup.of(session, pilot: SessionPilot(helperNeedsYou: true)) == .needsYou)
        #expect(SessionGroup.of(session, pilot: SessionPilot()) == .parked)
    }

    @Test func settingsParseWithOverrides() {
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        send_after_idle = "15m"
        send_to = "tab"
        [repos."o/r"]
        send_after_idle = "0"
        send_to = "session"
        [orgs.bad]
        send_to = "elsewhere"
        """)
        #expect(problems.map(\.path) == ["orgs.bad.send_to"])
        let pilot = config?.pilot ?? PilotRules()
        #expect(pilot.defaults.sendAfterIdle == 900 && pilot.defaults.sendTo == .tab)
        let repo = pilot.resolve(Repo(org: "o", name: "r"))
        #expect(repo.sendAfterIdle == 0 && repo.sendTo == .session)
        #expect(HeedConfig.default.pilot.defaults.sendAfterIdle == 300)
        #expect(PilotDuration.text(30) == "30s" && PilotDuration.text(0) == "0" && PilotDuration.text(300) == "5m")
    }

    @Test func notWhileYouWorkInIt() {
        let now = Date()
        let typed = now.addingTimeInterval(-120)
        #expect(Delivery.verdict(state: .idle, lastTyped: typed, now: now, typingGrace: 300)
            == .wait("you're working in it (sends 5m after your last keystroke)"))
        #expect(Delivery.verdict(state: .idle, lastTyped: typed, now: now, typingGrace: 60) == .deliver)
        // 0 still keeps the short grace.
        #expect(Delivery.verdict(state: .idle, lastTyped: now.addingTimeInterval(-5), now: now, typingGrace: 0)
            == .wait("you typed in its pane just now"))
    }
}
