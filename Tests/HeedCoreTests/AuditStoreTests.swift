import Foundation
@testable import HeedCore
import Testing

final class AuditStoreTests {
    /// Each test's own folder, removed when the test ends.
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("heed-audit-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private func database() throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("heed.sqlite").path
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ index: Int) -> AuditRecord {
        .action(AuditAction(
            id: "a\(index)", at: now.addingTimeInterval(Double(index)), actor: .heed, tag: .push,
            what: "pushed \(index)", command: "git push"
        ))
    }

    private func broken(_ path: String) async throws -> AuditChain.Break? {
        // A fresh start of heed: the anchor is read from its file.
        try await EventLog(path: path).audit().broken
    }

    private func edit(_ path: String, _ sql: String) throws { try SQLiteDatabase(path: path).run(sql) }

    @Test func rowsChainAndReadBack() async throws {
        let log = try EventLog(path: database())
        try await log.appendAudit([record(1), record(2)])
        try await log.appendAudit([record(3)])
        let (records, broken) = try await log.audit()
        #expect(broken == nil)
        #expect(records == [record(1), record(2), record(3)])
        let rows = try await log.auditRows()
        #expect(rows.map(\.seq) == [1, 2, 3] && rows.allSatisfy { $0.version == 2 })
        #expect(rows[0].prev == AuditChain.genesis)
        #expect(rows[1].prev == rows[0].hash && rows[2].prev == rows[1].hash)
        #expect(rows[2].hash == AuditChain.hash(
            prev: rows[1].hash, seq: 3, at: now.addingTimeInterval(3).timeIntervalSince1970, kind: "action",
            body: rows[2].body
        ))
        #expect(try await log.currentAuditAnchor() == AuditAnchor(last: rows[2].mark))
    }

    @Test func anEditedRowBreaksTheChainThere() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "UPDATE audit SET body = replace(body, 'pushed 2', 'pushed two') WHERE id = 2")
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 2 && broken.reason.contains("changed"))
    }

    @Test func anEditedTimeBreaksTheChainThere() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "UPDATE audit SET at = at + 60 WHERE id = 2")
        #expect(try await broken(path)?.seq == 2)
    }

    @Test func aRemovedRowBreaksTheChainAfterIt() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "DELETE FROM audit WHERE id = 2")
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 3 && broken.reason.contains("follow"))
    }

    @Test func rowsRemovedFromTheEndShowAndStayShownAfterTheNextWrite() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3), record(4)])
        try edit(path, "DELETE FROM audit WHERE id >= 3")
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 3 && broken.reason == "rows 3 to 4 are missing from the end")
        let reopened = try EventLog(path: path)
        try await reopened.appendAudit([record(5)])
        let after = try #require(try await self.broken(path))
        #expect(after.seq == 5 && after.reason.contains("follow"))
    }

    @Test func rowsRemovedFromTheStartShow() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "DELETE FROM audit WHERE id = 1")
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 2 && broken.reason.contains("before it are missing"))
    }

    @Test func pruningKeepsWhatIsLeftWhole() async throws {
        let path = try database()
        let log = try EventLog(path: path)
        try await log.appendAudit([record(1), record(2), record(3)])
        let later = now.addingTimeInterval(AuditChain.retention + 2.5)
        #expect(await log.pruneAudit(now: later) == 2)
        let (records, broken) = try await log.audit()
        #expect(records == [record(3)] && broken == nil)
        #expect(try await log.currentAuditAnchor().pruned?.seq == 2)
        try await log.appendAudit([record(4)])
        #expect(try await self.broken(path) == nil)
        // The rows after where pruning stopped still have to follow it.
        try edit(path, "DELETE FROM audit WHERE id = 3")
        #expect(try await self.broken(path)?.reason.contains("before it are missing") == true)
    }

    @Test func aRowWhoseTimeWasMadeOlderIsNotPrunedAndShows() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        // Row 1 made more than a year older, so pruning would take it: its time is part of its hash, so it stays.
        try edit(path, "UPDATE audit SET at = at - 400 * 86400 WHERE id = 1")
        let log = try EventLog(path: path)
        #expect(await log.pruneAudit(now: now.addingTimeInterval(86400)) == 0)
        #expect(try await log.auditRows().count == 3)
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 1 && broken.reason.contains("changed"))
    }

    @Test func aRecentRowMadeOlderDoesNotTakeTheRowsBeforeItWithIt() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "UPDATE audit SET at = at - 400 * 86400 WHERE id = 3")
        #expect(try await EventLog(path: path).pruneAudit(now: now.addingTimeInterval(86400)) == 0)
        #expect(try await broken(path)?.seq == 3)
    }

    @Test func pruningStopsAtTheFirstRowThatDoesNotHold() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2), record(3)])
        try edit(path, "UPDATE audit SET body = replace(body, 'pushed 2', 'pushed two') WHERE id = 2")
        let log = try EventLog(path: path)
        #expect(await log.pruneAudit(now: now.addingTimeInterval(AuditChain.retention + 10)) == 1)
        #expect(try await log.auditRows().map(\.seq) == [2, 3])
        #expect(try await broken(path)?.seq == 2)
    }

    /// A database from before rows covered their place and time: version-1 rows, no anchor, perhaps pruned.
    private func oldDatabase(_ path: String, pruned: Bool) throws -> [AuditChain.Row] {
        let old = try SQLiteDatabase(path: path)
        try old.migrate(Array(EventLog.schema.dropLast()))
        var prev = pruned ? AuditChain.hash(prev: AuditChain.genesis, kind: "action", body: "gone") : AuditChain.genesis
        var rows: [AuditChain.Row] = []
        for index in (pruned ? 2 : 1) ... 3 {
            let record = record(index)
            let body = try record.body()
            let hash = AuditChain.hash(prev: prev, kind: record.kind, body: body)
            try old.run(
                "INSERT INTO audit (id, at, kind, body, prev, hash) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .integer(Int64(index)),
                    SQLiteValue(record.at),
                    .text(record.kind),
                    .text(body),
                    .text(prev),
                    .text(hash),
                ]
            )
            rows.append(AuditChain.Row(
                seq: Int64(index), version: 1, at: record.at.timeIntervalSince1970, kind: record.kind, body: body,
                prev: prev, hash: hash
            ))
            prev = hash
        }
        return rows
    }

    @Test func anOldDatabaseStillHoldsAndGoesOnInTheNewForm() async throws {
        let path = try database()
        let old = try oldDatabase(path, pruned: true)
        let log = try EventLog(path: path)
        let (records, broken) = try await log.audit()
        #expect(broken == nil && records == [record(2), record(3)])
        #expect(try await log.auditRows() == old)
        #expect(try await log.currentAuditAnchor() == AuditAnchor(
            last: old[1].mark, pruned: AuditAnchor.Mark(seq: 1, hash: old[0].prev)
        ))
        try await log.appendAudit([record(4)])
        let rows = try await log.auditRows()
        #expect(rows.map(\.version) == [1, 1, 2] && rows[2].seq == 4 && rows[2].prev == old[1].hash)
        #expect(try await self.broken(path) == nil)
        // The old rows are still checked as they were.
        try edit(path, "UPDATE audit SET body = replace(body, 'pushed 3', 'pushed three') WHERE id = 3")
        #expect(try await self.broken(path)?.seq == 3)
    }

    @Test func anOldRowWhoseTimeChangedShows() async throws {
        let path = try database()
        _ = try oldDatabase(path, pruned: false)
        try edit(path, "UPDATE audit SET at = at - 400 * 86400 WHERE id = 1")
        let log = try EventLog(path: path)
        #expect(await log.pruneAudit(now: now.addingTimeInterval(86400)) == 0)
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 1 && broken.reason.contains("time changed"))
    }

    @Test func aRowsFormCannotBeSwappedForTheOther() async throws {
        let path = try database()
        _ = try oldDatabase(path, pruned: false)
        try await EventLog(path: path).appendAudit([record(4)])
        try edit(path, "UPDATE audit SET v = 1 WHERE id = 4")
        #expect(try await broken(path)?.seq == 4)
        try edit(path, "UPDATE audit SET v = 2 WHERE id = 4")
        try edit(path, "UPDATE audit SET v = 2 WHERE id = 2")
        #expect(try await broken(path)?.seq == 2)
    }

    @Test func aMissingAnchorIsSaidOnceTheRecordHadOne() async throws {
        let path = try database()
        try await EventLog(path: path).appendAudit([record(1), record(2)])
        let anchor = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("audit.json")
        #expect(FileManager.default.fileExists(atPath: anchor.path))
        try FileManager.default.removeItem(at: anchor)
        let broken = try #require(try await broken(path))
        #expect(broken.seq == 2 && broken.reason.contains("went missing"))
        // Said until pruning takes the row it was made again at.
        let log = try EventLog(path: path)
        #expect(await log.pruneAudit(now: now.addingTimeInterval(AuditChain.retention + 10)) == 2)
        #expect(try await self.broken(path) == nil)
    }

    @Test func theAnchorMayLagBehindTheRowsButNotAheadOfThem() {
        let rows = AuditChain.link(
            (1 ... 3).map { (kind: "action", body: "{\"n\":\($0)}", at: Double($0)) },
            after: AuditAnchor.Mark(seq: 0, hash: AuditChain.genesis)
        )
        #expect(AuditChain.verify(rows, anchor: AuditAnchor(last: rows[1].mark)) == nil)
        #expect(AuditChain.verify(rows, anchor: AuditAnchor(last: rows[2].mark)) == nil)
        let other = AuditAnchor.Mark(seq: 2, hash: AuditChain.genesis)
        #expect(AuditChain.verify(rows, anchor: AuditAnchor(last: other))?
            .reason == "it is not the row the record ended with")
        #expect(AuditChain.verify(Array(rows.prefix(2)), anchor: AuditAnchor(last: rows[2].mark))?.reason
            == "it is missing from the end")
        #expect(AuditChain.verify([], anchor: AuditAnchor(last: rows[2].mark))?.seq == 1)
    }

    @Test func theExportIsOneRowPerLineAndVerifiesAgain() async throws {
        let log = try EventLog(path: database())
        let action = AuditAction(
            id: "u", at: now.addingTimeInterval(0.123_456), actor: .heed, tag: .merge, what: "merged o/r#1",
            command: "gh pr merge https://github.com/o/r/pull/1 -- /Users/me/code/r", repo: "o/r",
            url: "https://github.com/o/r/pull/1"
        )
        try await log.appendAudit([record(1), .action(action)])
        let rows = try await log.auditRows()
        #expect(rows[1].body.contains(#"https:\/\/github.com"#))
        let text = AuditChain.exportLines(rows)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let second = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(second["hash"] as? String == rows[1].hash && second["kind"] as? String == "action")
        #expect(second["body"] as? String == rows[1].body)
        let exported = try #require(AuditChain.rows(fromExport: text))
        #expect(exported == rows)
        // Each row hashes again from what the export says, and the chain holds.
        #expect(exported.allSatisfy { AuditChain.expectedHash($0) == $0.hash })
        #expect(AuditChain.verify(exported, anchor: AuditAnchor(last: rows[1].mark)) == nil)
    }
}

struct AuditWriterTests {
    private actor Collected {
        var batches: [[String]] = []
        var statuses: [AuditWriter.Status] = []
        var failNext = 0

        func add(_ batch: [AuditRecord]) throws {
            if failNext > 0 {
                failNext -= 1
                throw AuditRevokeFailure("disk full")
            }
            batches.append(batch.map(AuditWriterTests.id))
        }

        func add(_ status: AuditWriter.Status) { statuses.append(status) }
        func failing(_ count: Int) { failNext = count }
    }

    private static func id(_ record: AuditRecord) -> String {
        if case let .cause(cause) = record { return cause.id }
        return ""
    }

    private func record(_ index: Int) -> AuditRecord {
        .cause(Cause(
            id: "c\(index)",
            at: Date(timeIntervalSince1970: Double(index)),
            trigger: .key,
            detail: "\(index)"
        ))
    }

    @Test func appendsAreWrittenInTheOrderTheyWereMade() async {
        let collected = Collected()
        let writer = AuditWriter(write: { batch in
            // Some writes are slower: the next one still waits its turn.
            if batch.count % 2 == 0 { try await Task.sleep(for: .milliseconds(2)) }
            try await collected.add(batch)
        }, status: { await collected.add($0) })
        let batches = (0 ..< 40).map { index in (0 ... index % 3).map { record(index * 10 + $0) } }
        for batch in batches {
            writer.append(batch)
        }
        await writer.flush()
        #expect(await collected.batches == batches.map { $0.map(Self.id) })
        #expect(await collected.statuses.isEmpty)
    }

    @Test func aFailedWriteIsSaidAndWrittenWithTheNextOne() async {
        let collected = Collected()
        await collected.failing(1)
        let writer = AuditWriter(write: { try await collected.add($0) }, status: { await collected.add($0) })
        writer.append([record(1), record(2)])
        await writer.flush()
        let failed = await collected.statuses
        #expect(failed.count == 1 && failed.first?.unsaved == 2 && failed.first?.problem?.contains("disk full") == true)
        #expect(await collected.batches.isEmpty)
        writer.append([record(3)])
        await writer.flush()
        #expect(await collected.batches == [["c1", "c2", "c3"]])
        #expect(await collected.statuses.last == .saved)
    }

    @Test func aWriteTheLogRefusesIsSaid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heed-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        try SQLiteDatabase(path: path).run("DROP TABLE audit")
        let collected = Collected()
        let writer = AuditWriter(log: log) { await collected.add($0) }
        writer.append([record(1)])
        await writer.flush()
        let status = try #require(await collected.statuses.last)
        #expect(status.unsaved == 1 && status.problem?.contains("no such table") == true)
    }
}
