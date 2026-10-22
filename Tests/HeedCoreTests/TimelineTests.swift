import Foundation
@testable import HeedCore
import Testing

struct TimelineTests {
    private let repo = Repo(org: "acme", name: "api")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    private func session(_ id: String, _ title: String, chat: Bool = false) -> Session {
        var session = Session(
            id: id, title: title, repos: chat ? [] : [repo], branch: "fix-auth", agent: "codex",
            state: ObservedState(.done)
        )
        if chat { session.workspace = .chat(ChatFolder(.scratch, path: "/chats/regex")) }
        return session
    }

    private func event(
        _ minutesAgo: Double, _ kind: EventKind, session: String? = nil, path: String? = nil, host: String? = nil,
        subject: String? = nil, text: String = "", guessed: Bool = false, payload: [String: String] = [:]
    ) -> LoggedEvent {
        LoggedEvent(
            at: at(minutesAgo), kind: kind, session: session, repo: repo.slug, host: host, worktree: path,
            subject: subject, text: text, guessed: guessed, payload: payload
        )
    }

    @Test func eventsBecomeLinesNewestFirst() {
        let domain = Domain(
            worktrees: [Worktree(repo: repo, path: "/wt/api/fix-auth", branch: "fix-auth", head: "", isMain: false)],
            sessions: [session("s", "Fix the auth check")]
        )
        let events = [
            event(60, .sessionStarted, session: "s", text: "Fix the auth check"),
            event(59, .worktreeCreated, path: "/wt/api/fix-auth", text: "fix-auth"),
            event(30, .pullTracked, session: "s", subject: "acme/api#12"),
            event(20, .questionAnswered, session: "s"),
            event(10, .pullMerged, session: "s", subject: "acme/api#12", text: "merged"),
            event(5, .state, session: "s", payload: ["state": "idle"]),
            event(4, .note, session: "s", text: "something"),
        ]
        let items = Timeline.items(from: events, domain: domain)
        #expect(items.map(\.lead) == [
            "PR merged:", "You answered", "PR tracked:", "Worktree created:", "Session started:",
        ])
        #expect(items.map(\.kind) == [.prs, .questions, .prs, .worktrees, .sessions])
        #expect(items[0].name == "#12" && items[0].badge == "merged" && items[0].detail == "api · Fix the auth check")
        #expect(items[1].name == "codex")
        #expect(items[3].name == "fix-auth" && !items[3].gone)
        // A worktree's line belongs to the session that worked there: R reopens it, its agent time shows.
        #expect(items[3].session == "s")
        #expect(items[4].detail == "api · codex")
    }

    @Test func aRemovedWorktreeIsGoneAndSaysWhatWasSaved() {
        let events = [
            event(120, .worktreeCreated, path: "/wt/api/old-spike", host: "devbox", text: "old-spike"),
            event(
                10,
                .worktreeArchived,
                host: "devbox",
                subject: "heed/archive/old-spike",
                text: "saved 3 unpushed commits as heed/archive/old-spike"
            ),
            event(9.9, .worktreeRemoved, path: "/wt/api/old-spike", host: "devbox", text: "old-spike"),
        ]
        let items = Timeline.items(from: events, domain: Domain())
        #expect(items.map(\.lead) == ["Worktree removed:", "Worktree created:"])
        #expect(items.allSatisfy { $0.gone })
        #expect(items[0].saved == "saved 3 unpushed commits as heed/archive/old-spike")
        #expect(items[0].place == "@devbox")
        // The same branch saved on another machine is another worktree's.
        let elsewhere = Timeline.items(from: [events[1], event(
            9.9,
            .worktreeRemoved,
            path: "/wt/api/old-spike",
            text: "old-spike"
        )], domain: Domain())
        #expect(elsewhere.first { $0.event == .worktreeRemoved }?.saved == nil)
        #expect(elsewhere.contains { $0.lead == "Work saved:" && $0.name == "old-spike" })
    }

    @Test func chatsAreTheirOwnKind() {
        let domain = Domain(history: [HistoryEntry(
            session: session("c", "Regex for anchors", chat: true),
            closedAt: at(1),
            outcome: .closed
        )])
        let items = Timeline.items(
            from: [event(30, .sessionStarted, session: "c"), event(1, .sessionClosed, session: "c", text: "closed")],
            domain: domain
        )
        #expect(items.map(\.kind) == [.chats, .chats])
        #expect(items.map(\.lead) == ["Chat closed:", "Chat started:"])
        #expect(items[0].name == "Regex for anchors")
    }

    @Test func filtersByKindRepoPlaceAndGone() {
        var gone = TimelineItem(
            id: "1", at: now, kind: .worktrees, event: .worktreeRemoved, lead: "", name: "", detail: "", badge: "",
            repo: "acme/api", host: "devbox", session: nil, worktree: nil
        )
        gone.gone = true
        var filter = TimelineFilter()
        #expect(filter.matches(gone))
        filter.showGone = false
        #expect(!filter.matches(gone))
        filter = TimelineFilter()
        filter.cyclePlace(among: ["local", "devbox"], named: "@devbox")
        #expect(filter.place == "devbox" && filter.matches(gone))
        filter.cyclePlace(among: ["local", "devbox"])
        #expect(filter.place == nil)
        filter.cycleRepo(among: ["acme/api", "acme/web"], named: "web")
        #expect(filter.repo == "acme/web" && !filter.matches(gone))
        filter.cycleRepo(among: ["acme/api", "acme/web"])
        #expect(filter.repo == nil)
        filter.cycleKind()
        #expect(filter.kinds == [.sessions] && !filter.matches(gone))
        filter.cycleKind()
        #expect(filter.kinds == [.worktrees] && filter.matches(gone))
        for _ in 0 ..< 4 {
            filter.cycleKind()
        }
        #expect(filter.kinds == Set(TimelineItem.Kind.allCases))
        filter.cycleKind("prs")
        #expect(filter.kinds == [.prs])
        filter.cycleKind("all")
        #expect(filter.kinds.count == TimelineItem.Kind.allCases.count)
    }

    @Test func daysAreTitledAsTheAwaySummaryTitlesThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let items = Timeline.items(from: [
            event(5, .sessionStarted, session: "a", text: "A"),
            event(10, .sessionStarted, session: "b", text: "B"),
            event(60 * 24 + 5, .sessionStarted, session: "c", text: "C"),
        ], domain: Domain())
        let days = Timeline.days(items, now: now, calendar: calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday"])
        #expect(days.map(\.indices) == [[0, 1], [2]])
    }

    @Test func agentTimeSumsWorkingStretchesAndMarksGuesses() {
        let states = [
            event(100, .state, session: "s", payload: ["state": "working"]),
            event(70, .state, session: "s", payload: ["state": "idle"]),
            event(50, .state, session: "s", payload: ["state": "working"]),
            event(40, .state, session: "s", payload: ["state": "asking"]),
            event(10, .state, session: "s", guessed: true, payload: ["state": "working"]),
        ]
        let worked = Timeline.agentTime(states.reversed(), now: now)
        #expect(worked.time.map { Int($0.rounded()) } == 50 * 60)
        #expect(worked.estimated)
        #expect(Timeline.agentTime(Array(states.prefix(4)), now: now).estimated == false)
        #expect(Timeline.agentTime([], now: now).time == nil)
    }

    @Test func factsSayHowLongAWorktreeLived() {
        let events = [
            event(300, .worktreeCreated, path: "/wt/api/x", text: "x"),
            event(60, .worktreeRemoved, path: "/wt/api/x", text: "x"),
        ]
        let items = Timeline.items(from: events, domain: Domain())
        let facts = Timeline.facts(for: items[0], events: events, states: [], now: now)
        #expect(facts.lived?.from == at(300) && facts.lived?.to == at(60))
        #expect(facts.agentTime == nil)
        let still = Timeline.facts(for: items[1], events: [events[0]], states: [], now: now)
        #expect(still.lived?.to == nil)
    }
}

struct TimelineFixtureTests {
    @Test func theFakeWorldsTimelineTellsItsSessions() {
        let domain = Fixtures.main.applying([.sessionClosed(Fixtures.closedChat)])
        let events = Fixtures.events
        let known = Set(domain.sessions.map(\.id) + domain.history.map(\.id))
        for id in Set(events.compactMap(\.session)) {
            #expect(known.contains(id), "\(id) is not in the fake world")
        }
        let items = Timeline.items(from: events, domain: domain)
        #expect(Set(items.map(\.kind)) == Set(TimelineItem.Kind.allCases))
        #expect(items.contains { $0.gone && $0.saved?.contains("heed/archive/flowchart-label-wrapping") == true })
        // A worktree that still exists is not struck through, here or on a host.
        #expect(items.contains { $0.lead == "Worktree created:" && $0.name == "fix-anchors-redirects" && !$0.gone })
        #expect(items.contains { $0.host == "devbox" && !$0.gone })
    }

    @Test func aLineHasAMenu() {
        let entries = ContextMenus.timeline(
            id: "x",
            title: "Worktree removed: old",
            kind: "worktrees",
            reopenable: true,
            onGitHub: false
        )
        let names = entries.compactMap { entry -> String? in
            if case let .item(item) = entry { item.command.name } else { nil }
        }
        #expect(names == ["history.reopen", "timeline.kind", "history.timeline"])
        let none = ContextMenus.timeline(id: "x", title: "t", kind: "prs", reopenable: false, onGitHub: true)
        #expect(!none
            .contains { if case let .item(item) = $0 { item.command.name == "history.reopen" } else { false } })
    }
}

struct TimelineStartTests {
    @Test func aSessionGoneFromTheDomainIsToldByItsStart() {
        let start = LoggedEvent(
            at: Date(timeIntervalSince1970: 100), kind: .sessionStarted, session: "c", text: "Compare exports",
            payload: ["agent": "claude", "chat": "scratch"]
        )
        let end = LoggedEvent(at: Date(timeIntervalSince1970: 200), kind: .sessionClosed, session: "c", text: "closed")
        let items = Timeline.items(from: [end, start], domain: Domain())
        #expect(items.map(\.lead) == ["Chat closed:", "Chat started:"])
        #expect(items.map(\.name) == ["Compare exports", "Compare exports"])
        #expect(items[0].badge == "closed" && items[0].detail == "claude")
    }
}
