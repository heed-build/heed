import Foundation
@testable import HeedCore
import Testing

struct ScreenTextTests {
    @Test func stripsEscapeSequencesAndControlCharacters() {
        let screen = "\u{1B}[1;32mDone\u{1B}[0m in 3s\u{1B}]0;title\u{07}\n\u{1B}(Bplain\u{08}\r\n\u{1B}[2Kcleared\tline"
        #expect(ScreenText.clean(screen) == "Done in 3s\nplain\ncleared line")
    }

    @Test func stripsBoxDrawingAndSpinnerGlyphs() {
        let screen = """
        ╭──────────────────────────╮
        │ Do you want to proceed?  │
        │ ❯ 1. Yes                 │
        ╰──────────────────────────╯
        ✻ Thinking… (esc to interrupt)
        ⠋ Building
        · Pondering
        ▌▐ bar
        """
        #expect(ScreenText.clean(screen) == """
         Do you want to proceed?
         ❯ 1. Yes
         Thinking… (esc to interrupt)
         Building
         Pondering
         bar
        """)
    }

    @Test func keepsAMiddleDotInsideALine() {
        #expect(ScreenText.clean("done · quiet") == "done · quiet")
    }

    @Test func collapsesBlankRunsAndTrimsTheEnds() {
        let screen = "\n\n  \nfirst   \n\n\n\n│   │\nsecond\n\n\n"
        #expect(ScreenText.clean(screen) == "first\n\nsecond")
    }

    @Test func keepsOnlyTheLastLines() {
        let screen = (1 ... 50).map { "line \($0)" }.joined(separator: "\n")
        let cleaned = ScreenText.clean(screen, lines: 30)
        let lines = cleaned.split(separator: "\n")
        #expect(lines.count == 30)
        #expect(lines.first == "line 21")
        #expect(lines.last == "line 50")
        // Blank rows below the prompt of a screen that is not full do not use up the lines.
        let padded = screen + String(repeating: "\n   ", count: 40)
        #expect(ScreenText.clean(padded, lines: 30) == cleaned)
    }

    @Test func anEmptyScreenIsEmpty() {
        #expect(ScreenText.clean("") == "")
        #expect(ScreenText.clean("\n │ \n\u{1B}[0m\n") == "")
    }
}

struct ScreenSamplerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func aReportedChangeIsLabelledAndAGuessedOneIsNot() {
        let working = ObservedState(.working)
        #expect(ScreenSnapshot.source(from: working, to: ObservedState(.blocked)) == .reported)
        #expect(ScreenSnapshot.source(from: working, to: ObservedState(.asking, source: .guessed)) == .guessed)
        // No change of state: nothing to keep, whatever the source says.
        #expect(ScreenSnapshot.source(from: working, to: working) == nil)
        #expect(ScreenSnapshot.source(from: ObservedState(.idle, source: .guessed), to: ObservedState(.idle)) == nil)
        #expect(ScreenSnapshot.Source.reported.labelled)
        #expect(ScreenSnapshot.Source.sampled.labelled)
        #expect(!ScreenSnapshot.Source.guessed.labelled)
    }

    @Test func whileWorkingAtMostOneSampleEveryFewMinutes() {
        var sampler = ScreenSampler()
        sampler.reported(session: "s", state: .working, at: at(0))
        let every = ScreenSampler.workingEvery
        let taken = [0, 1, every - 1, every, every + 1, 2 * every - 1, 2 * every].map {
            sampler.sampleWorking(session: "s", now: at($0))
        }
        #expect(taken == [false, false, false, true, false, false, true])
    }

    @Test func aSessionNotSeenStartingWorkWaitsAWholeIntervalFirst() {
        var sampler = ScreenSampler()
        // Working since before heed started: the first sample is a full interval away, not at once.
        let taken = [0, ScreenSampler.workingEvery - 1, ScreenSampler.workingEvery].map {
            sampler.sampleWorking(session: "s", now: at($0))
        }
        #expect(taken == [false, false, true])
    }

    @Test func leavingWorkStopsTheClockAndComingBackRestartsIt() {
        var sampler = ScreenSampler()
        let every = ScreenSampler.workingEvery
        sampler.reported(session: "s", state: .working, at: at(0))
        sampler.reported(session: "s", state: .blocked, at: at(10))
        sampler.reported(session: "s", state: .working, at: at(every - 5))
        let taken = [every + 1, 2 * every - 5].map { sampler.sampleWorking(session: "s", now: at($0)) }
        #expect(taken == [false, true])
    }

    @Test func aSampleAfterLeavingWorkWaitsAWholeIntervalAgain() {
        var sampler = ScreenSampler()
        sampler.reported(session: "s", state: .working, at: at(0))
        sampler.reported(session: "s", state: .blocked, at: at(10))
        let taken = sampler.sampleWorking(session: "s", now: at(ScreenSampler.workingEvery + 1))
        #expect(!taken)
    }

    @Test func sessionsHaveTheirOwnClocks() {
        var sampler = ScreenSampler()
        sampler.reported(session: "a", state: .working, at: at(0))
        sampler.reported(session: "b", state: .working, at: at(100))
        let a = sampler.sampleWorking(session: "a", now: at(ScreenSampler.workingEvery))
        let b = sampler.sampleWorking(session: "b", now: at(ScreenSampler.workingEvery))
        #expect(a && !b)
    }

    @Test func guessesAreRateLimitedPerSession() {
        var sampler = ScreenSampler()
        let every = ScreenSampler.guessedEvery
        let taken = [0, 1, every - 1, every].map { sampler.takeGuessed(session: "s", now: at($0)) }
        #expect(taken == [true, false, false, true])
        let other = sampler.takeGuessed(session: "other", now: at(1))
        sampler.forget(session: "s")
        let afterForget = sampler.takeGuessed(session: "s", now: at(every + 1))
        #expect(other && afterForget)
    }
}

struct ScreenSnapshotStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    private func snapshot(
        _ ago: TimeInterval, agent: String = "claude", state: AgentState = .blocked,
        source: ScreenSnapshot.Source = .reported,
        text: String = "Do you want to proceed?"
    ) -> ScreenSnapshot {
        ScreenSnapshot(
            at: now.addingTimeInterval(-ago), session: "s1", agent: agent, state: state,
            previous: source == .reported ? .working : nil, source: source, remote: false, text: text
        )
    }

    @Test func keepsWhatItIsGivenWithEveryField() async throws {
        let log = try EventLog(path: ":memory:")
        let kept = ScreenSnapshot(
            at: now, session: "s1", agent: "codex", state: .asking, previous: .working, source: .reported,
            remote: true, text: "Which one?\n❯ 1. Yes"
        )
        await log.record(kept, keepDays: 30, now: now)
        #expect(try await log.screenSnapshots() == [kept])
    }

    @Test func dropsWhatIsOlderThanTheRetention() async throws {
        let log = try EventLog(path: ":memory:")
        for ago in [0, 2 * day, 29 * day, 31 * day, 90 * day] {
            await log.record(snapshot(ago), keepDays: 365, now: now)
        }
        #expect(try await log.screenSnapshots().count == 5)
        let removed = await log.pruneScreens(now: now, keepDays: 30)
        #expect(removed == 2)
        #expect(try await log.screenSnapshots().map(\.at) == [0, 2 * day, 29 * day].map { now.addingTimeInterval(-$0) })
    }

    @Test func recordingPrunesToo() async throws {
        let log = try EventLog(path: ":memory:")
        await log.record(snapshot(40 * day), keepDays: 365, now: now)
        await log.record(snapshot(0), keepDays: 30, now: now)
        #expect(try await log.screenSnapshots().count == 1)
    }

    @Test func dropsTheOldestPastTheSizeCap() async throws {
        let log = try EventLog(path: ":memory:")
        let text = String(repeating: "x", count: 100)
        for minute in 0 ..< 10 {
            await log.record(snapshot(Double(minute) * 60, text: text), keepDays: 30, now: now)
        }
        let removed = await log.pruneScreens(now: now, keepDays: 30, maxBytes: 350)
        #expect(removed == 7)
        #expect(try await log.screenSnapshots().map(\.at) == [0, 60, 120].map { now.addingTimeInterval(-$0) })
        #expect(try await log.screenCounts(now: now).bytes == 300)
    }

    @Test func countsSplitLabelledByAgentAndStateFromUnlabelled() async throws {
        let log = try EventLog(path: ":memory:")
        for item in [
            snapshot(0, state: .blocked), snapshot(60, state: .blocked), snapshot(120, state: .asking),
            snapshot(180, agent: "codex", state: .idle), snapshot(240, state: .working, source: .sampled),
            snapshot(300, agent: "gemini", state: .blocked, source: .guessed),
            snapshot(360, agent: "gemini", state: .working, source: .guessed),
        ] {
            await log.record(item, keepDays: 30, now: now)
        }
        let counts = try await log.screenCounts(now: now)
        #expect(counts.labelled == [
            ScreenSnapshotCounts.Labelled(agent: "claude", state: .asking, count: 1),
            ScreenSnapshotCounts.Labelled(agent: "claude", state: .blocked, count: 2),
            ScreenSnapshotCounts.Labelled(agent: "claude", state: .working, count: 1),
            ScreenSnapshotCounts.Labelled(agent: "codex", state: .idle, count: 1),
        ])
        #expect(counts.unlabelled == 2)
        #expect(counts.total == 7)
    }

    @Test func countsTheLastSevenDaysPerDayOldestFirst() async throws {
        let log = try EventLog(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.startOfDay(for: now).addingTimeInterval(12 * 3600)
        for ago in [0, 0, day, 3 * day, 6 * day, 7 * day, 10 * day] {
            await log.record(snapshot(now.timeIntervalSince(noon) + ago), keepDays: 30, now: now)
        }
        let counts = try await log.screenCounts(now: now, calendar: calendar)
        #expect(counts.days.map(\.count) == [1, 0, 0, 1, 0, 1, 2])
        #expect(counts.days.last?.day == calendar.startOfDay(for: now))
        #expect(counts.days.first?.day == calendar.startOfDay(for: now.addingTimeInterval(-6 * day)))
    }

    @Test func deleteAllEmptiesIt() async throws {
        let log = try EventLog(path: ":memory:")
        await log.record(snapshot(0), keepDays: 30, now: now)
        await log.record(snapshot(60, source: .guessed), keepDays: 30, now: now)
        await log.deleteScreens()
        #expect(try await log.screenSnapshots().isEmpty)
        #expect(try await log.screenCounts(now: now) == ScreenSnapshotCounts.empty(now: now))
    }
}

struct LocalSettingsTests {
    @Test func offByDefaultAndKeptThirtyDays() {
        let config = ConfigLoader.decode(ConfigLoader.defaultSource).config
        #expect(config?.local == LocalSettings())
        #expect(LocalSettings().recordScreens == false)
        #expect(LocalSettings().keepDays == 30)
    }

    @Test func readsTheLocalTable() {
        let (config, problems) = ConfigLoader.decode("[local]\nrecord_screens = true\nkeep_days = 7\n")
        #expect(problems.isEmpty)
        #expect(config?.local == LocalSettings(recordScreens: true, keepDays: 7))
    }

    @Test func refusesAKeepDaysOutOfRange() {
        let (config, problems) = ConfigLoader.decode("[local]\nkeep_days = 0\n")
        #expect(config?.local.keepDays == 30)
        #expect(problems.map(\.path) == ["local.keep_days"])
    }
}
