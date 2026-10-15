import Foundation
@testable import HeedCore
import Testing

/// The sidebar's Watching and Stalled: who drives a session, and what its row says.
struct WatchingTests {
    private let repo = Repo(org: "o", name: "r")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ state: AgentState, pinned: Bool = false, id: String = "s") -> Session {
        var session = Session(
            id: id,
            title: id,
            repos: [repo],
            branch: id,
            agent: "claude",
            state: ObservedState(state)
        )
        session.pinned = pinned
        return session
    }

    private let merging = PullFeedback.Effective(watching: true, green: .ask, maxRounds: 3, merge: .heed)
    private let greening = PullFeedback.Effective(watching: true, green: .auto, maxRounds: 3)
    private let watchingOnly = PullFeedback.Effective(watching: true, green: .ask, maxRounds: 3)

    @Test func needsYouThenStalledThenWatchingThenTheAgentsState() {
        let acting = SessionPilot(status: .pending, acting: true)
        #expect(SessionGroup.of(session(.idle), pilot: acting) == .watching)
        // The spinner shows, but heed drives: it stays in Watching.
        #expect(SessionGroup.of(session(.working), pilot: acting) == .watching)
        #expect(SessionGroup.of(session(.asking), pilot: acting) == .needsYou)
        #expect(SessionGroup.of(session(.idle), pilot: SessionPilot(status: .stuck("no session"))) == .needsYou)
        #expect(SessionGroup.of(session(.idle), pilot: SessionPilot(status: .stalled(rounds: 3))) == .stalled)
        #expect(SessionGroup.of(session(.blocked), pilot: SessionPilot(status: .stalled(rounds: 3))) == .needsYou)
        #expect(SessionGroup.of(session(.idle, pinned: true), pilot: acting) == .pinned)
        // Parked by you beats stalled and watching; what needs you still shows.
        var parked = session(.working)
        parked.parked = true
        #expect(SessionGroup.of(parked, pilot: SessionPilot(status: .stalled(rounds: 3))) == .parked)
        #expect(SessionGroup.of(parked, pilot: acting) == .parked)
        parked.state = ObservedState(.asking)
        #expect(SessionGroup.of(parked, pilot: acting) == .needsYou)
        // Yours: the agent's state decides again.
        let yours = SessionPilot(status: .pending, acting: true, yours: true)
        #expect(SessionGroup.of(session(.idle), pilot: yours) == .parked)
        #expect(SessionGroup.of(session(.working), pilot: yours) == .working)
        #expect(SessionGroup.of(session(.idle)) == .parked)
        #expect(SessionGroup.allCases == [.pinned, .needsYou, .stalled, .working, .watching, .parked])
    }

    @Test func aSessionYouTypedInStaysYoursUntilHeedActs() {
        #expect(!SessionPilot.yours(lastTyped: nil, lastAction: now))
        #expect(SessionPilot.yours(lastTyped: now, lastAction: nil))
        #expect(SessionPilot.yours(lastTyped: now, lastAction: now.addingTimeInterval(-60)))
        #expect(!SessionPilot.yours(lastTyped: now.addingTimeInterval(-60), lastAction: now))
        // What heed did counts; what it noticed or held back does not.
        #expect(PilotEvent.actions.isSuperset(of: [.sent, .merged, .updated, .retry]))
        #expect(PilotEvent.actions.isDisjoint(with: [.items, .waiting, .queued, .stuck, .resolved, .addressed]))
    }

    @Test func heedActsWhenItHasSomethingToDo() {
        #expect(PilotStatus.feeding.heedActing(watchingOnly))
        #expect(PilotStatus.failing(2).heedActing(greening))
        #expect(!PilotStatus.failing(2).heedActing(watchingOnly))
        #expect(PilotStatus.pending.heedActing(merging))
        #expect(PilotStatus.green.heedActing(merging))
        #expect(!PilotStatus.green.heedActing(greening))
        #expect(!PilotStatus.stalled(rounds: 3).heedActing(greening))
        #expect(!PilotStatus.paused(until: nil).heedActing(merging))
        #expect(!PilotStatus.draft.heedActing(merging))
    }

    @Test func theSessionUnderTheCursorWaitsForThePilotButNotForYou() {
        // Heed's moves wait while the cursor is on the session.
        #expect(SessionGroup.held(.watching, natural: .parked) == .watching)
        #expect(SessionGroup.held(.working, natural: .watching) == .working)
        #expect(SessionGroup.held(.parked, natural: .stalled) == .parked)
        // Yours and what needs you show at once.
        #expect(SessionGroup.held(.watching, natural: .needsYou) == .needsYou)
        #expect(SessionGroup.held(.watching, natural: .pinned) == .pinned)
        #expect(SessionGroup.held(.pinned, natural: .watching) == .watching)
        #expect(SessionGroup.held(.working, natural: .parked) == .parked)

        let sessions = [session(.idle, id: "a"), session(.idle, id: "b")]
        let acting: (Session) -> SessionPilot = { _ in SessionPilot(status: .pending, acting: true) }
        let list = SessionList(sessions, pilot: acting, hold: SessionHold(id: "a", group: .parked))
        #expect(list.group(of: "a") == .parked)
        #expect(list.group(of: "b") == .watching)
        #expect(list.ordered.map(\.id) == ["b", "a"])
        // Parking it yourself moves it at once, and so does unparking it.
        var parked = sessions
        parked[1].parked = true
        let afterPark = SessionList(parked, pilot: acting, hold: SessionHold(id: "b", group: .watching))
        #expect(afterPark.group(of: "b") == .parked)
        parked[1].parked = false
        let afterUnpark = SessionList(
            parked, pilot: acting, hold: SessionHold(id: "b", group: .parked, parked: true)
        )
        #expect(afterUnpark.group(of: "b") == .watching)
    }

    @Test func labelsSayWhatHeedIsDoing() {
        func label(_ status: PilotStatus, _ effective: PullFeedback.Effective, _ state: AgentState = .idle) -> String? {
            WatchLabel.text(status: status, effective: effective, agent: "claude", agentState: state)
        }
        #expect(label(.failing(2), greening) == "getting it green · 2 checks failing")
        #expect(label(.changes(1), greening) == "getting it green · 1 thread to address")
        #expect(label(.feeding, greening, .working) == "getting it green · claude is fixing it")
        #expect(label(.feeding, greening) == "getting it green · waiting for a push")
        #expect(label(.pending, merging) == "getting it merged · waiting for checks")
        #expect(label(.green, merging) == "getting it merged · next run")
        #expect(label(.stalled(rounds: 3), greening) == "stalled · 3 rounds without a new approval")
        #expect(label(.failing(2), watchingOnly) == nil)
    }
}
