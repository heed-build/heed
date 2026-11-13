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

    @Test func theRangeIsSetAgainstTheOneBefore() {
        let events = [
            // This week: two merges, an hour of work; the week before: one merge, two hours.
            event(2, .pullMerged, "a", subject: "acme/api#2"),
            event(30, .pullMerged, "b", subject: "acme/api#3"),
            event(24 * 9, .pullMerged, "c", subject: "acme/api#1"),
            event(5, .state, "a", state: .working), event(4, .state, "a", state: .idle),
            event(24 * 9, .state, "c", state: .working), event(24 * 9 - 2, .state, "c", state: .idle),
            // Long ago: in neither.
            event(24 * 30, .pullMerged, "z", subject: "acme/api#0"),
        ]
        let board = Dashboard.build(
            events: events, sessions: [], closed: [], pulls: GitHubState(), days: 7, now: now, calendar: calendar
        )
        #expect(board.merged == 2 && board.mergedBefore == 1)
        #expect(board.agentTime == 3600 && board.agentTimeBefore == 2 * 3600)
        #expect(board.mergedPerDay.reduce(0, +) == 2 && board.mergedPerDay[6] == 1 && board.mergedPerDay[5] == 1)
        #expect(DashboardWords.delta(Double(board.merged), Double(board.mergedBefore), percent: false) == "▲ 1")
        #expect(DashboardWords.delta(board.agentTime, board.agentTimeBefore, percent: true) == "▼ 50%")
        #expect(DashboardWords.delta(1, 0, percent: true) == nil && DashboardWords.delta(1, nil, percent: false) == nil)
        let headline = board.headline
        #expect(headline.lead + headline.figure + headline
            .tail == "A good week: 2 PRs merged, 1 more than the week before.")
        #expect(headline.detail.hasPrefix("Your agents worked 1 h 0 m."))
        // The calendar is twelve weeks whatever the range, from a Monday to today.
        #expect(calendar.component(.weekday, from: board.calendarStart) == 2)
        #expect(board.calendar.count > 77 && board.calendar.count <= 84 && board.calendar.last == 3600)
        #expect(board.calendar.reduce(0, +) == 3 * 3600)
    }

    @Test func streaksCountDaysInARowAndTodayWithoutOneDoesNotBreakIt() {
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: today)! }
        let running: Set<Date> = [day(1), day(2), day(3), day(6)]
        #expect(Dashboard.currentStreak(running, today: today, calendar: calendar) == 3)
        #expect(Dashboard.currentStreak(running.union([today]), today: today, calendar: calendar) == 4)
        #expect(Dashboard.currentStreak([day(2)], today: today, calendar: calendar) == 0)
        let longest = Dashboard.longestStreak([day(10), day(9), day(8), day(3), day(2), day(1)], calendar: calendar)
        #expect(longest.count == 3 && longest.from == day(10))
        #expect(Dashboard.longestStreak([], calendar: calendar).count == 0)
    }

    @Test func mostAtOnceCountsOverlapsInsideTheWindowOnly() {
        let intervals = [(at(10), at(5)), (at(8), at(6)), (at(7), at(6.5)), (at(6), at(1)), (at(30), at(20))]
        let most = Dashboard.mostAtOnce(intervals, within: at(12) ... now)
        #expect(most.count == 3 && most.at == at(7))
        // One that ends as another starts does not overlap it.
        #expect(Dashboard.mostAtOnce([(at(3), at(2)), (at(2), at(1))], within: at(5) ... now).count == 1)
        #expect(Dashboard.mostAtOnce([(at(30), at(20))], within: at(12) ... now).count == 0)
    }

    @Test func waitsRunFromTheFirstQuestionToItsAnswer() {
        let events = [
            event(5, .questionAsked, "a"), event(4.9, .questionAsked, "a"), event(4.5, .questionAnswered, "a"),
            event(3, .questionAsked, "b"), event(2.9, .questionAnswered, "b"),
            // An answer with no question the log saw waited for nothing heed knows of.
            event(2, .questionAnswered, "c"),
            // Before the range.
            event(24 * 8, .questionAsked, "d"), event(24 * 8 - 1, .questionAnswered, "d"),
        ]
        let waits = Dashboard.waits(events)
        #expect(waits.map(\.session) == ["d", "a", "b"])
        #expect(waits.map(\.wait) == [3600, 1800, 360])
        let board = Dashboard.build(
            events: events, sessions: [], closed: [], pulls: GitHubState(), days: 7, now: now, calendar: calendar
        )
        #expect(board.medianWait == (1800 + 360) / 2 && board.medianWaitBefore == 3600)
        #expect(board.waited == 2160 && board.longestWait == 1800 && board.answered == 3)
        #expect(Dashboard.median([3, 1, 2]) == 2 && Dashboard.median([]) == nil)
    }

    @Test func shippedTellsEachMergeWithItsTitleAgentAndHowLongItTook() {
        let events = [
            LoggedEvent(
                at: at(10),
                kind: .sessionStarted,
                session: "a",
                repo: "acme/api",
                text: "Fix the toc",
                payload: ["agent": "claude"]
            ),
            event(8, .pullMerged, "a", repo: "acme/api", subject: "acme/api#12"),
            event(7, .pullMerged, "a", repo: "acme/api", subject: "acme/api#12"),
            event(2, .pullMerged, nil, repo: "acme/web", subject: "acme/web#7"),
            event(9, .sessionClosed, "a"),
        ]
        var closedEvent = events[4]
        closedEvent.text = "merged"
        let all = Array(events.prefix(4)) + [closedEvent, LoggedEvent(
            at: at(6), kind: .sessionClosed, session: "x", text: "abandoned"
        ), LoggedEvent(at: at(9.5), kind: .sessionStarted, session: "x", payload: ["agent": "codex"])]
        var pulls = GitHubState()
        pulls.pulls = [PullRequest(
            ref: PullRef(repo: Repo(org: "acme", name: "web"), number: 7), title: "Web fix", url: "", state: .merged,
            isDraft: false, headBranch: "fix", review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: now
        )]
        let board = Dashboard.build(
            events: all, sessions: [], closed: [], pulls: pulls, days: 7, now: now, calendar: calendar
        )
        #expect(board.shipped.map(\.ref) == ["acme/web#7", "acme/api#12"])
        #expect(board.shipped.map(\.title) == ["Web fix", "Fix the toc"])
        #expect(board.shipped[1].agent == "claude" && board.shipped[1].took == 2 * 3600)
        #expect(board.shipped[1].pull == PullRef(repo: Repo(org: "acme", name: "api"), number: 12))
        #expect(board.shipped[0].took == nil && board.fastest == 2 * 3600)
        #expect(board.agents.map(\.agent) == ["claude", "codex"])
        #expect(board.agents[0].merged == 1 && board.agents[1].abandoned == 1 && board.agents[1].ended == 1)
        // Bests: the fastest merge and the busiest day (two merged today), both from this week.
        #expect(board.bests.map(\.kind) == [.fastestMerge, .mostAtOnce, .mostInADay])
        #expect(board.bests[0].value == "2 h" && board.bests[0].detail == "Fix the toc, today" && board.bests[0]
            .current)
        #expect(board.bests[1].value == "2 sessions")
    }
}

/// The fake world tells one story: the dashboard sums the same sessions, with the same usage, the ledger shows.
struct DashboardFixtureTests {
    @Test func theDashboardAndTheLedgerAgree() throws {
        let world = Fixtures.main
        let sessions = world.sessions + world.history.map(\.session)
        for entry in Fixtures.ledger {
            let session = try #require(sessions.first { $0.id == entry.id })
            #expect(entry.usage == session.usage, "\(entry.id)")
        }
        let board = Dashboard.build(
            events: Fixtures.dashboardEvents, sessions: world.sessions, closed: world.history, pulls: world.github,
            days: 28, now: Clock.now
        )
        let started = Set(Fixtures.dashboardEvents.filter { $0.kind == .sessionStarted }.compactMap(\.session))
        let reported = sessions.filter { started.contains($0.id) }.compactMap(\.usage)
        #expect(board.tokens == reported.map { $0.tokens.allInput + $0.tokens.output }.reduce(0, +))
        #expect(board.cost == reported.compactMap(\.costUSD).reduce(0, +))
        // The ledger's biggest entry is part of it.
        let toc = try #require(Fixtures.ledger.first { $0.id == "h-fix-toc-ordering" }?.usage)
        #expect(board.tokens >= toc.tokens.allInput + toc.tokens.output)
    }
}

/// The dashboard's goals: those that moved in the range, and what the one closest to done still lacks.
struct DashboardGoalsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    private func quality(_ score: Double?, done: Bool = false, missing: [String] = [], doneAt: Date? = nil)
        -> GoalQuality
    {
        var quality = GoalQuality.empty
        quality.confidence = score.map { GoalScore(value: $0, basis: "") }
        quality.done = (done, missing)
        quality.doneAt = doneAt
        return quality
    }

    @Test func movedIsWhatCameInOrWasDoneInTheRange() {
        let goals = [
            HeedGoal(id: "nav", title: "One docs nav model", status: .done, createdAt: at(40)),
            HeedGoal(id: "anchors", title: "Anchors survive page moves", createdAt: at(30)),
            HeedGoal(id: "quiet", title: "Nothing happened", createdAt: at(30)),
            HeedGoal(id: "gone", title: "Archived", status: .archived, createdAt: at(30)),
        ]
        let evidence = [
            GoalEvidence(goal: "anchors", kind: .merged, at: at(1), source: "acme/docs#1"),
            GoalEvidence(goal: "anchors", kind: .codeReview, at: at(2), source: "reviewer"),
            GoalEvidence(goal: "anchors", kind: .pr, state: .inProgress, at: at(2), source: "acme/docs#2"),
            GoalEvidence(goal: "quiet", kind: .merged, at: at(20), source: "acme/docs#0"),
            GoalEvidence(goal: "gone", kind: .merged, at: at(1), source: "acme/docs#3"),
        ]
        let qualities = [
            "nav": quality(10, done: true, doneAt: at(3)),
            "anchors": quality(5.6, missing: ["2 criteria without evidence", "Docs 5.6 under 7"]),
            "quiet": quality(8, missing: ["Perf – under 6"]),
        ]
        let moved = DashboardGoals.moved(
            goals: goals, evidence: evidence, qualities: qualities, since: at(7), now: now
        )
        #expect(moved.map(\.id) == ["nav", "anchors"])
        #expect(moved[0].done && moved[0].score == 10)
        #expect(moved[1].steps == 2 && moved[1].merged == 1 && moved[1].score == 5.6)
        // Next: the active goal closest to done that still lacks something.
        let next = DashboardGoals.next(goals: goals, qualities: qualities)
        #expect(next?.goal == "quiet" && next?.missing == ["Perf – under 6"])
        #expect(DashboardGoals.next(goals: [], qualities: qualities) == nil)
    }
}
