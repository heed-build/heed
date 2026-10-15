import Foundation
@testable import HeedCore
import Testing

/// While you were away: what happened, by day and kind, and when it opens on its own.
struct AwaySummaryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    /// Tuesday 13 October 2026, 09:41 in Amsterdam.
    private var now: Date { date(13, 9, 41) }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private let ref = PullRef(repo: Repo(org: "o", name: "docs"), number: 7)

    @Test func eventsGroupByDayNewestFirstThenByKind() {
        let events = [
            AwayEvent(at: date(13, 7, 31), kind: .runs, subject: "get it green #7", text: "codex · pushed 2 commits"),
            AwayEvent(at: date(13, 6, 10), kind: .runs, subject: "get it green #7", text: "codex · timed out"),
            AwayEvent(at: date(13, 7, 52), kind: .merged, subject: "docs #6", text: "First pass"),
            AwayEvent(at: date(12, 22, 15), kind: .reviews, subject: "docs #7", text: "@r requested changes"),
            AwayEvent(at: date(12, 22, 16), kind: .reviews, subject: "docs #7", text: "2 review threads arrived"),
            // Before the window, and after now: neither shows.
            AwayEvent(at: date(12, 17, 0), kind: .merged, subject: "docs #1", text: "too early"),
            AwayEvent(at: date(13, 10, 0), kind: .merged, subject: "docs #2", text: "not yet"),
        ]
        let summary = AwaySummary.build(
            events: events, waiting: [], since: date(12, 18, 20), now: now, calendar: calendar
        )
        #expect(summary.sinceText == "since yesterday 18:20")
        #expect(summary.days.map(\.title) == ["Today", "Yesterday"])
        #expect(summary.days[0].groups.map(\.kind) == [.merged, .runs])
        // Runs stay one row each, newest first.
        #expect(summary.days[0].groups[1].rows.map(\.text) == ["codex · pushed 2 commits", "codex · timed out"])
        // A review and its threads on one PR are one row, as they happened.
        let reviews = summary.days[1].groups[0]
        #expect(reviews.kind == .reviews && reviews.rows.count == 1)
        #expect(reviews.rows[0].text == "@r requested changes · 2 review threads arrived")
        #expect(!summary.isEmpty)
    }

    @Test func emptyUnlessSomethingHappenedOrWaits() {
        let none = AwaySummary.build(events: [], waiting: [], since: date(12, 18, 0), now: now, calendar: calendar)
        #expect(none.isEmpty)
        var waiting = AwaySummary.build(
            events: [],
            waiting: [
                .init(id: "a", state: .asking, name: "a", reason: "codex · 3 questions waiting"),
                .init(id: "b", state: .blocked, name: "b", reason: "claude · wants to run make"),
            ],
            since: date(12, 18, 0), now: now, calendar: calendar
        )
        #expect(!waiting.isEmpty && waiting.selected?.id == "a")
        waiting.move(by: 5)
        #expect(waiting.selected?.id == "b")
        waiting.move(by: -9)
        #expect(waiting.selected?.id == "a")
    }

    @Test func titlesAndSinceTexts() {
        #expect(AwaySummary.dayTitle(date(11, 0, 0), now: now, calendar: calendar) == "Sunday 11 Oct")
        #expect(AwaySummary.sinceText(date(13, 7, 10), now: now, calendar: calendar) == "since 07:10")
        #expect(AwaySummary.sinceText(date(12, 0, 0), now: now, calendar: calendar) == "since yesterday")
        #expect(AwaySummary.sinceText(date(9, 18, 5), now: now, calendar: calendar) == "since Friday 18:05")
        #expect(AwaySummary.sinceText(date(2, 18, 5), now: now, calendar: calendar) == "since 2 Oct 18:05")
    }

    @Test func itOpensAfterBeingAwayLongEnough() {
        #expect(AwaySummary.shouldOffer(lastActive: date(12, 18, 0), now: now, awayHours: 8))
        #expect(!AwaySummary.shouldOffer(lastActive: date(13, 8, 0), now: now, awayHours: 8))
        #expect(!AwaySummary.shouldOffer(lastActive: nil, now: now, awayHours: 8))
        #expect(!AwaySummary.shouldOffer(lastActive: date(1, 8, 0), now: now, awayHours: 0))
    }

    @Test func askedForByHandItGoesBackToYesterdayOrTheLastAbsence() {
        let yesterday = date(12, 0, 0)
        #expect(AwaySummary.askedSince(lastAway: nil, shownAt: nil, now: now, calendar: calendar) == yesterday)
        // A weekend away, shown this morning: the whole weekend.
        let friday = date(9, 18, 0)
        #expect(AwaySummary.askedSince(lastAway: friday, shownAt: date(13, 8, 0), now: now, calendar: calendar)
            == friday)
        // Shown long ago: back to yesterday.
        #expect(AwaySummary.askedSince(lastAway: friday, shownAt: date(10, 8, 0), now: now, calendar: calendar)
            == yesterday)
    }

    @Test func theDomainTellsMergesRunsReviewsFinishedAndClosed() {
        var domain = Domain()
        domain.github.viewer = "you"
        domain.pilotLog = [
            PilotEvent(at: date(13, 7, 52), ref: ref, kind: .merged, text: "merged into main"),
            PilotEvent(at: date(13, 7, 50), ref: ref, kind: .merged, text: "squash: every merge rule held"),
            PilotEvent(at: date(13, 7, 0), ref: ref, kind: .items, text: "check lint arrived"),
            PilotEvent(at: date(13, 6, 0), ref: ref, kind: .items, text: "1 review thread arrived"),
            PilotEvent(at: date(13, 5, 0), ref: ref, kind: .sent, text: "sent 1 item"),
        ]
        var detail = PullDetail(
            ref: ref, title: "Fix anchors", body: "", author: "you", baseBranch: "main", headBranch: "fix",
            additions: 1, deletions: 0, commitCount: 1, headSHA: "a",
            reviews: [
                .init(author: "r", state: "CHANGES_REQUESTED", submittedAt: date(13, 5, 30)),
                .init(author: "you", state: "COMMENTED", submittedAt: date(13, 5, 31)),
                .init(author: "old", state: "APPROVED"),
            ],
            threads: [], failingChecks: [], checks: CheckSummary(passed: 1), closes: [], fetchedAt: now
        )
        detail.state = "MERGED"
        domain.pullDetails[ref.description] = detail
        var run = PilotRun(
            ref: ref, sessionID: "s", goal: .green, agent: "codex", model: nil, startedAt: date(13, 7, 0), items: 1,
            prBranch: "fix", branch: "heed/get-it-green/fix", worktree: "/wt", startSHA: nil
        )
        run.endedAt = date(13, 7, 6)
        run.outcome = .pushed(2)
        domain.runs = [run]
        var done = Session(
            id: "s", title: "Bump", repos: [ref.repo], branch: "bump-tests", agent: "claude",
            state: ObservedState(.done), activity: "done · PR approved", lastActivity: date(13, 5, 44)
        )
        done.worktreePaths = ["/wt/docs/bump-tests"]
        let working = Session(
            id: "w", title: "W", repos: [ref.repo], branch: "w", agent: "claude", state: ObservedState(.working),
            lastActivity: date(13, 8, 0)
        )
        let asking = Session(
            id: "q", title: "Q", repos: [ref.repo], branch: "ingest", agent: "codex",
            state: ObservedState(.asking, source: .guessed), activity: "3 questions waiting"
        )
        domain.sessions = [done, working, asking]
        domain.history = [HistoryEntry(session: working, closedAt: date(12, 20, 0), outcome: .merged)]

        let summary = AwaySummary.build(
            events: AwaySummary.events(from: domain), waiting: AwaySummary.waiting(from: domain.sessions),
            since: date(12, 18, 0), now: now, calendar: calendar
        )
        let today = summary.days[0]
        #expect(today.groups.map(\.kind) == [.merged, .runs, .finished, .reviews])
        // Both merge entries name the PR by its title, so they are one row.
        #expect(today.groups[0].rows.map(\.text) == ["Fix anchors"])
        #expect(today.groups[0].rows[0].subject == "docs #7")
        #expect(today.groups[1].rows[0].text == "codex · pushed 2 commits · 6m")
        #expect(today.groups[2].rows[0].subject == "bump-tests")
        #expect(today.groups[2].rows[0].text == "claude done · PR approved")
        // Your own review and failing checks are not news here.
        #expect(today.groups[3].rows[0].text == "@r requested changes · 1 review thread arrived")
        #expect(summary.days[1].groups.map(\.kind) == [.closed])
        #expect(summary.days[1].groups[0].rows[0].text == "merged · W")
        #expect(summary.waiting.map(\.id) == ["q"])
        #expect(summary.waiting[0].reason == "codex · 3 questions waiting" && summary.waiting[0].guessed)
    }

    @Test func thePilotLogKeepsTwoWeeksBeyondItsCount() {
        let event = { (days: Double) in
            PilotEvent(at: now.addingTimeInterval(-days * 86400), ref: ref, kind: .sent, text: "x")
        }
        let log = (0 ..< 600).map { event(Double($0) / 100) } + [event(20)]
        let kept = PilotEvent.log(log, adding: [event(0)])
        // Every event of the last two weeks stays past the 500; the three-week-old one goes.
        #expect(kept.count == 601)
        let many = Array(repeating: event(1), count: 2500)
        #expect(PilotEvent.log(many, adding: []).count == PilotEvent.logCeiling)
    }
}
