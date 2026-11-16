import Foundation
@testable import HeedCore
import Testing

/// A helper's life as events (`HelperRun.apply`), a pilot run's state (`PilotRun.State`), and the one way a PR's
/// author is checked before something starts on it.
struct HelperLifecycleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0.addingTimeInterval(60) }
    private var t2: Date { t0.addingTimeInterval(120) }

    private func helper(_ phase: HelperRun.Phase = .working) -> HelperRun {
        var run = HelperRun(
            id: "h1", kind: .green, ref: PullRef(repo: Repo(org: "o", name: "r"), number: 7), title: "t",
            agent: "claude", adapter: "claude via ACP", sessionID: "s1", prBranch: "b", branch: "heed/b",
            worktree: "/wt/h", startedAt: t0, cap: 0
        )
        run.phase = phase
        return run
    }

    @Test func readyStartsItWorkingWithItsNote() {
        var run = helper(.starting)
        #expect(run.apply(.ready(note: "claude started in /wt/h"), at: t0) == [])
        #expect(run.phase == .working)
        #expect(run.feed.count == 1)
    }

    @Test func readyAfterItWasThrownAwayChangesNothing() {
        var run = helper(.closed("thrown away"))
        #expect(run.apply(.ready(note: "late"), at: t0) == nil)
        #expect(run.phase == .closed("thrown away"))
        #expect(run.feed.isEmpty)
    }

    @Test func aTurnStartsAfterItEndedButNotOnceItIsOver() {
        var done = helper(.done(.endTurn))
        done.closeOut = HelperCloseOut(summary: "x")
        #expect(done.apply(.turnStarted, at: t0) == [])
        #expect(done.phase == .working && done.closeOut == nil)
        var failed = helper(.failed("gone"))
        #expect(failed.apply(.turnStarted, at: t0) == nil)
        var closed = helper(.closed("pushed"))
        #expect(closed.apply(.turnStarted, at: t0) == nil)
    }

    @Test func aTurnsEndIsReadByWhyItWasCancelled() {
        var run = helper()
        #expect(run.apply(.turnEnded(.endTurn, cancel: nil, connected: true), at: t0) == [.finishTurn])
        #expect(run.phase == .done(.endTurn))

        run = helper()
        #expect(run.apply(.turnEnded(.cancelled, cancel: .pause, connected: true), at: t0) == [])
        #expect(run.phase == .paused)

        run = helper()
        #expect(run
            .apply(.turnEnded(.cancelled, cancel: .steer("go on"), connected: true), at: t0) == [.steer("go on")])
        #expect(run.phase == .working)

        run = helper()
        #expect(run.apply(.turnEnded(.cancelled, cancel: .steer("go on"), connected: false), at: t0) == [])
        #expect(run.phase == .paused)

        run = helper(.asking)
        #expect(run.apply(.turnEnded(.cancelled, cancel: .stop("its cap"), connected: true), at: t0) == [.finishTurn])
        #expect(run.phase == .stopped("its cap"))
    }

    @Test func aLateTurnEndDoesNotReopenAHelperYouTookOver() {
        var run = helper(.closed("taken over"))
        run.endedAt = t0
        #expect(run.apply(.turnEnded(.cancelled, cancel: .stop("you took it over"), connected: true), at: t1) == nil)
        #expect(run.phase == .closed("taken over"))
        #expect(run.endedAt == t0)
    }

    @Test func stoppingAPausedHelperFinishesIt() {
        var run = helper(.paused)
        #expect(run.apply(.stopped("ran 30m"), at: t0) == [.finishTurn])
        #expect(run.phase == .stopped("ran 30m"))
        var done = helper(.done(.endTurn))
        #expect(done.apply(.stopped("ran 30m"), at: t0) == nil)
    }

    @Test func failuresNeedALiveHelperAndAreRecorded() {
        var starting = helper(.starting)
        #expect(starting.apply(.couldNotStart("no worktree"), at: t0) == [.recordFailure("no worktree")])
        #expect(starting.phase == .failed("no worktree") && starting.endedAt == t0)

        var working = helper()
        #expect(working.apply(.turnFailed("broken pipe"), at: t0) == [.recordFailure("broken pipe")])
        #expect(working.phase == .failed("broken pipe") && working.endedAt == nil)

        var exited = helper()
        #expect(exited.apply(.agentExited("its agent exited"), at: t0) == [.recordFailure("its agent exited")])
        #expect(exited.phase == .failed("its agent exited"))

        var closed = helper(.closed("pushed"))
        #expect(closed.apply(.couldNotStart("late"), at: t0) == nil)
        #expect(closed.apply(.turnFailed("late"), at: t0) == nil)
        #expect(closed.apply(.agentExited("late"), at: t0) == nil)
        #expect(closed.phase == .closed("pushed"))
    }

    @Test func aCloseOutLandsOnlyWhileItWaitsForOne() {
        var run = helper(.done(.endTurn))
        let files = [HelperFile(path: "a.swift", added: 2, removed: 1)]
        #expect(run.apply(.closeOut(HelperCloseOut(summary: "did it"), files: files, keep: false), at: t1) == [])
        #expect(run.closeOut?.summary == "did it" && run.files == files && run.endedAt == t1)

        // Closed out while git was asked: the late close-out neither moves its end nor replaces what it was.
        run.phase = .closed("pushed")
        #expect(run.apply(.closeOut(HelperCloseOut(summary: "late"), files: [], keep: false), at: t2) == nil)
        #expect(run.closeOut?.summary == "did it" && run.endedAt == t1)
    }

    @Test func theFakeWorldKeepsItsCloseOut() {
        var run = helper(.stopped("x"))
        run.closeOut = HelperCloseOut(summary: "kept")
        _ = run.apply(.closeOut(HelperCloseOut(summary: "Stopped in the fake world."), files: nil, keep: true), at: t0)
        #expect(run.closeOut?.summary == "kept")
    }

    @Test func closingKeepsTheFirstEndAndAFailedHelperCloses() {
        var done = helper(.done(.endTurn))
        done.endedAt = t0
        #expect(done.apply(.closed("pushed abc"), at: t1) == [])
        #expect(done.phase == .closed("pushed abc") && done.endedAt == t0)
        #expect(done.apply(.closed("thrown away"), at: t2) == nil)
        #expect(done.phase == .closed("pushed abc"))

        var failed = helper(.failed("no worktree"))
        #expect(failed.apply(.closed("thrown away"), at: t1) == [])
        #expect(failed.phase == .closed("thrown away") && failed.endedAt == t1)
    }

    @Test func aPartsEndKeepsWhatItHas() {
        var run = helper(.done(.endTurn))
        _ = run.apply(.partEnded(summary: HelperCloseOut(summary: "swarm's")), at: t0)
        #expect(run.endedAt == t0 && run.closeOut?.summary == "swarm's")
        _ = run.apply(.partEnded(summary: HelperCloseOut(summary: "again")), at: t1)
        #expect(run.endedAt == t0 && run.closeOut?.summary == "swarm's")
    }
}

struct PilotRunStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func run() -> PilotRun {
        PilotRun(
            id: "r1", ref: PullRef(repo: Repo(org: "o", name: "r"), number: 7), sessionID: "s", goal: .green,
            agent: "codex", model: nil, startedAt: t0, items: 1, prBranch: "b", branch: "heed/b", worktree: "/wt",
            startSHA: "a"
        )
    }

    @Test func aRunEndsThroughEndingOnce() {
        var run = run()
        #expect(run.state == .running && run.isRunning && !run.isEnding)
        run.beginEnding()
        #expect(run.isEnding && run.isRunning && run.endedAt == nil && run.outcome == nil)
        run.end(.pushed(2), at: t0)
        #expect(run.state == .ended(.pushed(2), at: t0) && !run.isRunning)
        // A late end (a timeout after it ended) changes nothing, nor does ending again.
        run.end(.timedOut, at: t0.addingTimeInterval(5))
        run.beginEnding()
        #expect(run.outcome == .pushed(2) && run.endedAt == t0)
    }

    @Test func itIsStoredAsItAlwaysWas() throws {
        var ended = run()
        ended.end(.failed("no agent"), at: t0)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ended)) as? [String: Any])
        #expect(json["endedAt"] != nil && json["outcome"] != nil && json["ending"] == nil)
        #expect(try JSONDecoder().decode(PilotRun.self, from: JSONEncoder().encode(ended)) == ended)

        var ending = run()
        ending.beginEnding()
        #expect(try JSONDecoder().decode(PilotRun.self, from: JSONEncoder().encode(ending)).isEnding)
        #expect(try JSONDecoder().decode(PilotRun.self, from: JSONEncoder().encode(run())).state == .running)
    }

    @Test func anEndWithNoOutcomeReadsAsInterrupted() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run())) as? [String: Any])
        json["endedAt"] = 0
        let decoded = try JSONDecoder().decode(PilotRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.outcome == .interrupted && !decoded.isRunning)
    }

    @Test func aKnownAuthorIsTrustedWithoutAskingGitHub() async {
        let book = PullTrustBook()
        let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 7)
        book.record(PullAuthorship(author: "ann", association: "OWNER", crossRepository: false), for: ref)
        #expect(await book.resolveOnGitHub(ref, viewer: "me", trustedAuthors: [], caller: "test"))
        let stranger = PullRef(repo: Repo(org: "o", name: "r"), number: 8)
        book.record(PullAuthorship(author: "eve", association: "NONE", crossRepository: true), for: stranger)
        #expect(await !book.resolveOnGitHub(stranger, viewer: "me", trustedAuthors: [], caller: "test"))
    }
}
