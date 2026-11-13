import Foundation
@testable import HeedCore
import Testing

/// Insights › History: the work that ended by day, each with its story folded under it.
struct HistoryFeedTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon on a fixed day, UTC.
    private let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86400 + 12 * 3600))
    private let api = Repo(org: "acme", name: "api")
    private let web = Repo(org: "acme", name: "web")

    private func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    private func entry(
        _ id: String, _ repo: Repo?, closed hoursAgo: Double, _ outcome: Outcome, chat: Bool = false,
        host: String? = nil
    ) -> HistoryEntry {
        var session = Session(
            id: id, title: "Title \(id)", prompt: "Prompt \(id)", repos: repo.map { [$0] } ?? [], branch: id,
            agent: "claude", state: ObservedState(.done), createdAt: at(hoursAgo + 1)
        )
        if chat { session.workspace = .chat(ChatFolder(.scratch, path: "/tmp/\(id)")) }
        session.host = host
        return HistoryEntry(session: session, closedAt: at(hoursAgo), outcome: outcome)
    }

    private func item(
        _ id: String, _ hoursAgo: Double, _ event: EventKind, _ kind: TimelineItem.Kind, session: String?,
        repo: Repo? = nil, name: String = "", badge: String = "", gone: Bool = false
    ) -> TimelineItem {
        var item = TimelineItem(
            id: id, at: at(hoursAgo), kind: kind, event: event, lead: "", name: name, detail: "", badge: badge,
            repo: repo?.slug, host: nil, session: session, worktree: nil
        )
        item.gone = gone
        return item
    }

    private var entries: [HistoryEntry] {
        [
            entry("a", api, closed: 1, .merged),
            entry("b", web, closed: 2, .abandoned),
            entry("chat", nil, closed: 3, .closed, chat: true),
            entry("old", api, closed: 30, .merged, host: "devbox"),
        ]
    }

    private var items: [TimelineItem] {
        [
            item("a1", 2, .sessionStarted, .sessions, session: "a", repo: api, badge: "started"),
            item("a2", 1.8, .worktreeCreated, .worktrees, session: "a", repo: api, name: "a"),
            item("a3", 1.5, .pullTracked, .prs, session: "a", repo: api, name: "#12"),
            item("a4", 1.2, .questionAnswered, .questions, session: "a", repo: api),
            item("a5", 1.1, .pullMerged, .prs, session: "a", repo: api, name: "#12"),
            item("a6", 1, .sessionClosed, .sessions, session: "a", repo: api, badge: "merged"),
            item("a7", 0.9, .worktreeRemoved, .worktrees, session: "a", repo: api, name: "a", gone: true),
            // No session: a quiet line of its own.
            item("loose", 4, .worktreeCreated, .worktrees, session: nil, repo: web, name: "by-hand"),
            // A session still open: left to Sessions until it ends.
            item("live", 0.5, .pullTracked, .prs, session: "s1", repo: api, name: "#13"),
            item("liveq", 0.4, .questionAnswered, .questions, session: "s1", repo: api),
        ]
    }

    private func build(_ narrowing: HistoryFeed.Narrowing = .init()) -> HistoryFeed {
        HistoryFeed.build(entries: entries, items: items, narrowing: narrowing, now: now, calendar: calendar)
    }

    @Test func foldsEachSessionsEventsIntoItsWorkAndKeepsTheRestQuiet() {
        let feed = build()
        #expect(feed.lines.map(\.id) == ["work-a", "work-b", "work-chat", "loose", "work-old"])
        let work = try? #require(feed.lines.first?.work)
        #expect(work?.story.map(\.id) == ["a1", "a2", "a3", "a4", "a5", "a6", "a7"])
        // The line under it says what happened, leaving out the worktree made with it and a merged session's end.
        let words = work?.story.compactMap { HistoryFeed.storyWord($0, outcome: work?.entry.outcome) }
        #expect(words == ["started", "PR #12", "you answered", "merged", "worktree removed"])
        #expect(feed.lines[2].work?.quiet == true && feed.lines[0].work?.quiet == false)
    }

    @Test func daysCarryTheirTotals() {
        let feed = build()
        #expect(feed.days.map(\.title) == ["Today", "Yesterday"])
        #expect(feed.days[0].indices == [0, 1, 2, 3] && feed.days[1].indices == [4])
        // Questions count whoever asked, a live session's too; a chat has no outcome to count.
        #expect(feed.days[0].totals.text == "1 merged · 1 abandoned · 2 questions answered")
        #expect(feed.days[1].totals.text == "1 merged")
    }

    @Test func narrowsByOutcomeRepoPlaceKindAndText() {
        #expect(build(.init(outcome: .merged)).lines.map(\.id) == ["work-a", "work-old"])
        var repo = TimelineFilter()
        repo.repo = "acme/web"
        #expect(build(.init(filter: repo)).lines.map(\.id) == ["work-b", "loose"])
        var place = TimelineFilter()
        place.place = "devbox"
        #expect(build(.init(filter: place)).lines.map(\.id) == ["work-old"])
        var chats = TimelineFilter()
        chats.cycleKind("chats")
        #expect(build(.init(filter: chats)).lines.map(\.id) == ["work-chat"])
        #expect(build(.init(search: "prompt chat")).lines.map(\.id) == ["work-chat"])
        // Removed worktrees hidden: out of the story too.
        var gone = TimelineFilter()
        gone.showGone = false
        #expect(build(.init(filter: gone)).lines.first?.work?.story.contains { $0.id == "a7" } == false)
    }

    @Test func everyEventUnfoldsTheOldTimeline() {
        let feed = build(.init(everyEvent: true))
        #expect(feed.lines.count == items.count)
        #expect(feed.lines.first?.id == "liveq" && feed.lines.allSatisfy { $0.work == nil })
        // With an outcome, only the events of work that ended so.
        let merged = build(.init(outcome: .merged, everyEvent: true))
        #expect(merged.lines.map(\.session) == Array(repeating: "a", count: 7))
    }

    @Test func countsBesideTheFiltersFollowTheRestOfTheNarrowing() {
        let counts = HistoryFeed.outcomeCounts(entries: entries, narrowing: .init(outcome: .merged))
        #expect(counts == [.merged: 2, .abandoned: 1, .closed: 1])
        var repo = TimelineFilter()
        repo.repo = "acme/api"
        #expect(HistoryFeed.outcomeCounts(entries: entries, narrowing: .init(filter: repo)) == [.merged: 2])
        #expect(HistoryFeed.repoCounts(entries: entries) == ["acme/api": 2, "acme/web": 1])
        var worktrees = TimelineFilter()
        worktrees.cycleKind("worktrees")
        #expect(HistoryFeed.outcomeCounts(entries: entries, narrowing: .init(filter: worktrees)).isEmpty)
        #expect(HistoryFeed.outcomeCounts(entries: entries, narrowing: .init(filter: worktrees, everyEvent: true))
            == [.merged: 2, .abandoned: 1, .closed: 1])
        let choices = HistoryFeed.choices(entries: entries, items: items)
        #expect(choices.repos == ["acme/api", "acme/web"] && choices.places == ["local", "devbox"])
    }

    @Test func theDetailTellsTheStoryInSentences() {
        let story = items.prefix(7)
        let sentences = story.map { HistoryFeed.storySentence($0, agent: "claude") }
        #expect(sentences == [
            "started · claude", "worktree a created", "opened PR #12", "you answered claude", "PR #12 merged",
            "ended, merged", "worktree removed",
        ])
    }
}
