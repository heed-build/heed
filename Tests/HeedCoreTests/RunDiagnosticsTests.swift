import Foundation
@testable import HeedCore
import Testing

struct RunDiagnosticsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func journal(clean: Bool = false, boot: Date? = nil) -> RunJournal {
        RunJournal(
            pid: 7957, version: "0.50.1 (396)", started: start, lastBeat: start.addingTimeInterval(3600),
            boot: boot ?? start.addingTimeInterval(-86400), footprintMB: 812, clean: clean
        )
    }

    @Test func aRunThatDidNotQuitIsReportedLost() {
        let text = journal().lostRun(
            rebootedSince: start.addingTimeInterval(-86400),
            now: start.addingTimeInterval(7200)
        )
        #expect(text?.contains("pid 7957") == true)
        #expect(text?.contains("after 60 min") == true)
        #expect(text?.contains("812 MB") == true)
        #expect(text?.contains("60 min passed") == true)
        #expect(text?.contains("restarted") == false)
    }

    @Test func aCleanQuitIsNotReported() {
        #expect(journal(clean: true).lostRun(rebootedSince: start, now: start) == nil)
    }

    @Test func aRestartInBetweenIsSaid() {
        let text = journal().lostRun(rebootedSince: start.addingTimeInterval(5000), now: start.addingTimeInterval(7200))
        #expect(text?.contains("the Mac restarted in between") == true)
    }

    @Test func theJournalRoundTripsThroughItsFile() throws {
        let dir = try folder()
        #expect(RunJournal.read(in: dir) == nil)
        journal().write(in: dir)
        #expect(RunJournal.read(in: dir) == journal())
    }

    @Test func theLogAppendsLinesAndRollsOver() throws {
        let dir = try folder()
        let log = RunLog(directory: dir, maxBytes: 200, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        for index in 0 ..< 10 {
            log.write(.info, "line \(index) " + String(repeating: "x", count: 40))
        }
        log.drain()
        let current = try String(contentsOf: log.file, encoding: .utf8)
        let older = try String(contentsOf: log.file.appendingPathExtension("1"), encoding: .utf8)
        #expect(current.contains("line 9"))
        #expect(older.contains(" INFO line "))
        #expect(current.count < 400)
    }

    @Test func theStoreCountsWhatItWroteAndWhoAsked() async throws {
        let dir = try folder()
        let store = DomainStore(
            domain: Fixtures.main,
            file: dir.appendingPathComponent("domain.json"),
            writeDelay: .milliseconds(1)
        )
        let session = try #require(Fixtures.main.sessions.first)
        await store.apply(.sessionUpserted(session))
        await store.flush()
        let stats = await store.takeStats()
        #expect(stats.writes >= 1)
        #expect(stats.bytes > 0)
        #expect(stats.changes["sessionUpserted"] == 1)
        #expect(stats.summary.contains("sessionUpserted ×1"))
        #expect(stats.sizes.first?.bytes ?? 0 >= stats.sizes.last?.bytes ?? 0, "largest first")
        #expect(stats.summary.contains("heaviest: "))
        #expect(await store.takeStats() == DomainStore.Stats())
    }
}
