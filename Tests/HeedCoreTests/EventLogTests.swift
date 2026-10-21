import Foundation
@testable import HeedCore
import Testing

struct EventLogTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `domain.json` as builds before the event log wrote it (format 6): history with timelines, two sessions with
    /// timelines.
    private func oldCache(in dir: URL) throws -> URL {
        let fixture = try #require(Bundle.module.url(
            forResource: "domain-v6",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let file = dir.appendingPathComponent("domain.json")
        try FileManager.default.copyItem(at: fixture, to: file)
        return file
    }

    private func noteCount(_ log: EventLog) async throws -> Int {
        try await log.events(kinds: [.note], limit: 10000).count
    }

    // MARK: Migration

    @Test func anOldCacheMovesItsHistoryAndTimelinesIntoTheLog() async throws {
        let dir = try folder()
        let file = try oldCache(in: dir)
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.history.count == 7)
        #expect(loaded.session("s1")?.timeline.count == 3)

        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let adopted = await log.adopt(loaded)
        // The app sees exactly what it saw before.
        #expect(adopted == loaded)
        #expect(try await log.history().map(\.id) == loaded.history.map(\.id))
        // 3 + 2 session lines, and the closed sessions' own (3 or 2 each).
        let lines = loaded.sessions.map(\.timeline.count).reduce(0, +)
            + loaded.history.map(\.session.timeline.count).reduce(0, +)
        #expect(try await noteCount(log) == lines)

        // Taking in again (the next launch, or a cache an older build wrote to since) adds nothing twice.
        _ = await log.adopt(loaded)
        #expect(try await noteCount(log) == lines)
        #expect(try await log.history().count == 7)
    }

    @Test func theDomainFileNoLongerKeepsWhatTheLogKeeps() async throws {
        let dir = try folder()
        let file = try oldCache(in: dir)
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let adopted = await log.adopt(DomainStore.load(from: file))
        let store = DomainStore(domain: adopted, file: file, log: log)
        await store.flushAll()

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let domain = try #require(raw?["domain"] as? [String: Any])
        // The fields stay, empty, so an older build still reads the file.
        #expect((domain["history"] as? [Any])?.isEmpty == true)
        let sessions = try #require(domain["sessions"] as? [[String: Any]])
        #expect(sessions.allSatisfy { ($0["timeline"] as? [Any])?.isEmpty == true })

        // And the next launch puts it all back together from both.
        let relaunched = await log.adopt(DomainStore.load(from: file))
        #expect(relaunched == adopted)
    }

    @Test func aDomainThatDoesNotReadNoLongerHidesHistory() async throws {
        let dir = try folder()
        let file = try oldCache(in: dir)
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        _ = await log.adopt(DomainStore.load(from: file))
        // A newer build's cache: moved aside, the domain starts empty...
        let cached = CachedDomain(version: CachedDomain.currentVersion + 1, domain: .empty)
        try JSONEncoder.heed.encode(cached).write(to: file)
        let fresh = await DomainStore.load(from: file)
        #expect(fresh.history.isEmpty)
        // ...but history comes from the log.
        let adopted = await log.adopt(fresh)
        #expect(adopted.history.count == 7)
    }

    /// While you were away reads closed sessions from the history the log keeps, also when the domain file did not
    /// read.
    @Test func theAwaySummaryReadsClosedSessionsFromTheLog() async throws {
        let dir = try folder()
        let file = try oldCache(in: dir)
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let loaded = await DomainStore.load(from: file)
        _ = await log.adopt(loaded)
        try Data("not json".utf8).write(to: file)
        let domain = await log.adopt(DomainStore.load(from: file))

        let newest = try #require(loaded.history.first)
        let summary = AwaySummary.build(
            events: AwaySummary.events(from: domain), waiting: [],
            since: newest.closedAt.addingTimeInterval(-60), now: newest.closedAt.addingTimeInterval(60)
        )
        let closed = try #require(summary.days.first?.groups.first { $0.kind == .closed })
        #expect(closed.rows.map(\.subject) == [newest.session.worktreeName])
        #expect(closed.rows[0].text == "\(newest.outcome.rawValue) · \(newest.session.title)")
    }

    // MARK: Writing as the domain changes

    private func session(_ id: String = "s", state: ObservedState = ObservedState(.working)) -> Session {
        var session = Session(
            id: id, title: "Fix anchors", repos: [Repo(org: "acme", name: "api")], branch: "fix-anchors",
            agent: "claude", state: state, lastActivity: Date(timeIntervalSince1970: 1000),
            createdAt: Date(timeIntervalSince1970: 900)
        )
        session.worktreePaths = ["/wt/api/fix-anchors"]
        session.host = "devbox"
        return session
    }

    private func events(_ writes: [EventLogWrite]) -> [LoggedEvent] {
        writes.flatMap { write -> [LoggedEvent] in
            if case let .events(events) = write { return events }
            return []
        }
    }

    @Test func aNewSessionIsStartedWithItsTimeline() {
        var new = session()
        new.record("started · claude · 2 panes", at: Date(timeIntervalSince1970: 900))
        let logged = events(DomainEvents.writes(before: .empty, changes: [.sessionUpserted(new)], now: .now))
        #expect(logged.map(\.kind) == [.sessionStarted, .note])
        #expect(logged[0].at == new.createdAt)
        #expect(logged[0].repo == "acme/api" && logged[0].host == "devbox" && logged[0]
            .worktree == "/wt/api/fix-anchors")
        #expect(logged[1].text == "started · claude · 2 panes")
    }

    @Test func stateChangesAreLoggedReportedOrGuessed() {
        let old = session()
        let domain = Domain(sessions: [old])
        var asking = old
        asking.state = ObservedState(.asking, source: .guessed, reason: "3 questions")
        asking.lastActivity = Date(timeIntervalSince1970: 2000)
        let logged = events(DomainEvents.writes(before: domain, changes: [.sessionUpserted(asking)], now: .now))
        #expect(logged.map(\.kind) == [.state, .questionAsked])
        #expect(logged.allSatisfy { $0.guessed })
        #expect(logged[0].payload == ["state": "asking", "from": "working", "reason": "3 questions"])
        #expect(logged[0].at == asking.lastActivity)

        var answered = asking
        answered.state = ObservedState(.working)
        let next = events(DomainEvents.writes(
            before: Domain(sessions: [asking]), changes: [.sessionUpserted(answered)], now: .now
        ))
        #expect(next.map(\.kind) == [.state, .questionAnswered])
        #expect(!next[0].guessed)

        // The next tool of a working turn changes nothing worth a row.
        var busy = old
        busy.lastActivity = Date(timeIntervalSince1970: 3000)
        busy.activity = "running tests"
        #expect(DomainEvents.writes(before: domain, changes: [.sessionUpserted(busy)], now: .now).isEmpty)
    }

    @Test func parkingTrackingAndNewTimelineLinesAreLogged() {
        let old = session()
        var new = old
        new.parked = true
        let ref = PullRef(repo: Repo(org: "acme", name: "api"), number: 7)
        new.track(ref, because: "opened by claude", at: Date(timeIntervalSince1970: 1500))
        let logged = events(DomainEvents.writes(
            before: Domain(sessions: [old]),
            changes: [.sessionUpserted(new)],
            now: .now
        ))
        #expect(logged.map(\.kind) == [.sessionParked, .pullTracked, .note])
        #expect(logged[1].subject == "acme/api#7")
        #expect(logged[2].text == "tracking PR api#7 (opened by claude)")
    }

    @Test func aTimelineAtItsCapStillLogsOnlyTheNewLine() {
        var old = session()
        for minute in 0 ..< Session.timelineLimit {
            old.record("line \(minute)", at: Date(timeIntervalSince1970: Double(minute * 60)))
        }
        var new = old
        new.record("the new one", at: Date(timeIntervalSince1970: 99999))
        let logged = events(DomainEvents.writes(
            before: Domain(sessions: [old]),
            changes: [.sessionUpserted(new)],
            now: .now
        ))
        #expect(logged.map(\.text) == ["the new one"])
    }

    @Test func closingThenRefiningTheOutcomeIsOneClose() {
        let open = session()
        let entry = HistoryEntry(session: open, closedAt: Date(timeIntervalSince1970: 5000), outcome: .closed)
        let writes = DomainEvents.writes(before: Domain(sessions: [open]), changes: [.sessionClosed(entry)], now: .now)
        #expect(events(writes).map(\.kind) == [.sessionClosed])
        #expect(writes.contains(.closed(entry)))
        var refined = entry
        refined.outcome = .merged
        let again = DomainEvents.writes(before: Domain(history: [entry]), changes: [.sessionClosed(refined)], now: .now)
        #expect(events(again).isEmpty)
        #expect(again == [.closed(refined)])
    }

    @Test func reopeningIsNotStarting() {
        let closed = session()
        let entry = HistoryEntry(session: closed, closedAt: Date(timeIntervalSince1970: 5000), outcome: .closed)
        let writes = DomainEvents.writes(
            before: Domain(history: [entry]), changes: [.historyRemoved(closed.id), .sessionUpserted(closed)],
            now: Date(timeIntervalSince1970: 6000)
        )
        #expect(writes.first == .reopened(closed.id))
        #expect(events(writes).map(\.kind) == [.sessionReopened])
        #expect(events(writes)[0].at == Date(timeIntervalSince1970: 6000))
    }

    @Test func worktreesAreCreatedAndRemovedOnlyAgainstAnEarlierListing() {
        let repo = Repo(org: "acme", name: "api")
        let main = Worktree(repo: repo, path: "/code/api", branch: "main", head: "a", isMain: true)
        let old = Worktree(repo: repo, path: "/wt/api/old", branch: "old", head: "b", isMain: false)
        let new = Worktree(repo: repo, path: "/wt/api/new", branch: "new", head: "c", isMain: false)
        // The first listing is what exists, not what was made.
        #expect(DomainEvents.writes(before: .empty, changes: [.worktreesListed(repo: repo, [main, old])], now: .now)
            .isEmpty)
        let logged = events(DomainEvents.writes(
            before: Domain(worktrees: [main, old]), changes: [.worktreesListed(repo: repo, [main, new])], now: .now
        ))
        #expect(logged.map(\.kind) == [.worktreeCreated, .worktreeRemoved])
        #expect(logged.map(\.worktree) == ["/wt/api/new", "/wt/api/old"])
        #expect(logged[0].text == "new")
    }

    @Test func aMergeSeenBySyncAndDetailIsLoggedOnce() async throws {
        let ref = PullRef(repo: Repo(org: "acme", name: "api"), number: 7)
        func pull(_ state: PullRequest.State) -> PullRequest {
            PullRequest(
                ref: ref, title: "Fix", url: ref.url, state: state, isDraft: false, headBranch: "fix", review: nil,
                checks: CheckSummary(), unresolvedThreads: 0, updatedAt: .now
            )
        }
        var tracking = session()
        tracking.trackedPRs = [ref]
        let before = Domain(sessions: [tracking], github: GitHubState(pulls: [pull(.open)]))
        let synced = DomainEvents.writes(
            before: before, changes: [.githubSynced(GitHubState(pulls: [pull(.merged)]))], now: .now
        )
        #expect(events(synced).map(\.kind) == [.pullMerged])
        #expect(events(synced)[0].session == "s")

        var open = PullDetail(
            ref: ref, title: "Fix", body: "", author: "you", baseBranch: "main", headBranch: "fix", additions: 1,
            deletions: 0, commitCount: 1, headSHA: "a", reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(), closes: [], fetchedAt: .now
        )
        var merged = open
        merged.state = "MERGED"
        open.state = "OPEN"
        let detailed = DomainEvents.writes(
            before: Domain(pullDetails: [ref.description: open]), changes: [.pullDetailFetched(merged)], now: .now
        )
        #expect(events(detailed).map(\.kind) == [.pullMerged])

        let log = try EventLog(path: folder().appendingPathComponent("heed.sqlite").path)
        await log.write(synced + detailed)
        #expect(try await log.events(kinds: [.pullMerged]).count == 1)
    }

    @Test func theStoreWritesToTheLogInOrderAndKeepsHistoryThere() async throws {
        let dir = try folder()
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let store = DomainStore(file: dir.appendingPathComponent("domain.json"), log: log, writeDelay: .seconds(60))
        var open = session()
        await store.apply(.sessionUpserted(open))
        open.state = ObservedState(.done)
        open.lastActivity = Date(timeIntervalSince1970: 2000)
        await store.apply(.sessionUpserted(open))
        let entry = HistoryEntry(session: open, closedAt: Date(timeIntervalSince1970: 3000), outcome: .merged)
        await store.apply(.sessionClosed(entry))
        // Batched: nothing is written before the delay or a flush.
        #expect(try await log.events().isEmpty)
        await store.flushAll()
        #expect(try await log.events().map(\.kind) == [.sessionClosed, .state, .sessionStarted])
        #expect(try await log.history() == [entry])

        await store.apply([.historyRemoved(open.id), .sessionUpserted(open)])
        await store.flushAll()
        #expect(try await log.history().isEmpty)
        #expect(try await log.events(kinds: [.sessionReopened]).count == 1)
    }

    @Test func timelinesComeBackNewestFiftyOldestFirst() async throws {
        let log = try EventLog(path: folder().appendingPathComponent("heed.sqlite").path)
        let open = session()
        await log.append((0 ..< 60).map {
            LoggedEvent(at: Date(timeIntervalSince1970: Double($0)), kind: .note, about: open, text: "line \($0)")
        })
        let timeline = try await log.timelines(of: ["s", "other"])
        #expect(timeline["s"]?.count == Session.timelineLimit)
        #expect(timeline["s"]?.first?.text == "line 10")
        #expect(timeline["s"]?.last?.text == "line 59")
        #expect(timeline["other"] == nil)
    }

    @Test func eventsAreQueriedByRangeAndSession() async throws {
        let log = try EventLog(path: folder().appendingPathComponent("heed.sqlite").path)
        let one = session("one")
        let two = session("two")
        await log.append([
            LoggedEvent(at: Date(timeIntervalSince1970: 10), kind: .sessionStarted, about: one),
            LoggedEvent(
                at: Date(timeIntervalSince1970: 20),
                kind: .state,
                about: two,
                guessed: true,
                payload: ["state": "asking"]
            ),
            LoggedEvent(at: Date(timeIntervalSince1970: 30), kind: .sessionClosed, about: one),
        ])
        let range = try await log.events(from: Date(timeIntervalSince1970: 15), to: Date(timeIntervalSince1970: 30))
        #expect(range.map(\.kind) == [.sessionClosed, .state])
        #expect(range[1].guessed && range[1].payload == ["state": "asking"])
        #expect(try await log.events(session: "one").map(\.kind) == [.sessionClosed, .sessionStarted])
    }
}
