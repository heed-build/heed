import Foundation
@testable import HeedCore
import Testing

struct DashboardTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon on a fixed day, UTC.
    private let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86400 + 12 * 3600))

    private func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    private func event(
        _ hoursAgo: Double, _ kind: EventKind, _ session: String? = nil, repo: String? = nil, subject: String? = nil,
        state: AgentState? = nil, guessed: Bool = false, agent: String? = nil
    ) -> LoggedEvent {
        var payload: [String: String] = [:]
        if let state { payload["state"] = state.rawValue }
        if let agent { payload["agent"] = agent }
        return LoggedEvent(
            at: at(hoursAgo), kind: kind, session: session, repo: repo, subject: subject, guessed: guessed,
            payload: payload
        )
    }

    private func session(_ id: String, agent: String, repo: String, cost: Double? = nil) -> Session {
        var session = Session(
            id: id, title: id, repos: [Repo(org: "acme", name: repo)], branch: id, agent: agent,
            state: ObservedState(.done)
        )
        session.usage = AgentUsage(model: "m", tokens: TokenCounts(input: 1000, output: 200), costUSD: cost)
        return session
    }

    @Test func sumsTheRangeFromTheLog() {
        let events = [
            event(30, .sessionStarted, "a", repo: "acme/api", agent: "claude"),
            event(30, .state, "a", state: .working),
            event(28, .state, "a", state: .idle),
            event(5, .sessionStarted, "b", repo: "acme/web", agent: "codex"),
            event(5, .state, "b", state: .working, guessed: true),
            event(4, .state, "b", state: .done),
            event(3, .pullMerged, "a", subject: "acme/api#1"),
            event(3, .pullMerged, "a", subject: "acme/api#1"),
            event(2, .questionAnswered, "b"),
            // Before the range: not counted.
            event(24 * 10, .sessionStarted, "old", repo: "acme/api", agent: "claude"),
            event(24 * 10, .state, "old", state: .working),
            event(24 * 10 - 1, .state, "old", state: .done),
        ]
        let board = Dashboard.build(
            events: events, sessions: [
                session("a", agent: "claude", repo: "api", cost: 1.5),
                session("b", agent: "codex", repo: "web"),
            ],
            closed: [], pulls: GitHubState(), days: 7, now: now, calendar: calendar
        )
        #expect(board.sessions == 2 && board.merged == 1 && board.answered == 1)
        #expect(board.agentTime == 3 * 3600 && board.estimated)
        #expect(board.byAgent.map(\.name) == ["claude", "codex"] && board.byAgent[1].estimated)
        #expect(board.byRepo.map(\.name) == ["api", "web"])
        #expect(board.tokens == 2400 && board.cost == 1.5)
        #expect(board.perDay.count == 7)
        // Yesterday 06:00–08:00, today 07:00–08:00.
        #expect(board.perDay[5] == 2 * 3600 && board.perDay[6] == 3600)
        #expect(board.recent.map(\.id) == ["b", "a"])
        #expect(board.level(board.perDay[5]) == 4 && board.level(board.perDay[6]) == 2 && board.level(0) == 0)
    }

    @Test func aStretchOverMidnightIsSplitAndTheLastOneRunsToNow() {
        let events = [
            event(14, .sessionStarted, "a", agent: "claude"),
            event(14, .state, "a", state: .working), // 22:00 yesterday, still working
        ]
        let board = Dashboard.build(
            events: events, sessions: [], closed: [], pulls: GitHubState(), days: 7, now: now, calendar: calendar
        )
        #expect(board.perDay[5] == 2 * 3600 && board.perDay[6] == 12 * 3600)
        #expect(board.agentTime == 14 * 3600)
        // Agent and repo from the start event when the session is gone from the domain.
        #expect(board.byAgent.first?.name == "claude" && board.byRepo.first?.name == "unknown")
    }

    @Test func emptyWhenNothingWasRecorded() {
        let board = Dashboard.build(
            events: [], sessions: [], closed: [], pulls: GitHubState(), days: 28, now: now, calendar: calendar
        )
        #expect(board.isEmpty && board.cost == nil && board.perDay.count == 28)
        // A session whose agent reported tokens but no cost: no cost, not $0.
        let started = [event(1, .sessionStarted, "b", agent: "codex")]
        let noCost = Dashboard.build(
            events: started, sessions: [session("b", agent: "codex", repo: "web")], closed: [], pulls: GitHubState(),
            days: 7, now: now, calendar: calendar
        )
        #expect(noCost.tokens == 1200 && noCost.cost == nil)
    }

    @Test func outcomesAreWords() {
        let closed = HistoryEntry(session: session("c", agent: "claude", repo: "api"), closedAt: now, outcome: .merged)
        var parked = session("p", agent: "claude", repo: "api")
        parked.parked = true
        #expect(Dashboard.outcome(closed.session, closed: closed, pulls: GitHubState()) == "merged")
        #expect(Dashboard.outcome(parked, closed: nil, pulls: GitHubState()) == "parked")
    }
}
