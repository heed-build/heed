import Foundation
@testable import HeedCore
import Testing

struct AuditStoreTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ index: Int) -> AuditRecord {
        .action(AuditAction(
            id: "a\(index)", at: now.addingTimeInterval(Double(index)), actor: .heed, tag: .push,
            what: "pushed \(index)", command: "git push"
        ))
    }

    @Test func rowsChainAndReadBack() async throws {
        let path = try folder().appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        await log.appendAudit([record(1), record(2)])
        await log.appendAudit([record(3)])
        let (records, broken) = try await log.audit()
        #expect(broken == nil)
        #expect(records == [record(1), record(2), record(3)])
        let rows = try await log.auditRows()
        #expect(rows[0].prev == AuditChain.genesis)
        #expect(rows[1].prev == rows[0].hash && rows[2].prev == rows[1].hash)
        #expect(rows[2].hash == AuditChain.hash(prev: rows[1].hash, kind: "action", body: rows[2].body))
    }

    @Test func anEditedRowBreaksTheChainThere() async throws {
        let path = try folder().appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        await log.appendAudit([record(1), record(2), record(3)])
        let other = try SQLiteDatabase(path: path)
        try other.run("UPDATE audit SET body = replace(body, 'pushed 2', 'pushed two') WHERE id = 2")
        let broken = try #require(try await log.audit().broken)
        #expect(broken.seq == 2 && broken.reason.contains("changed"))
    }

    @Test func aRemovedRowBreaksTheChainAfterIt() async throws {
        let path = try folder().appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        await log.appendAudit([record(1), record(2), record(3)])
        try SQLiteDatabase(path: path).run("DELETE FROM audit WHERE id = 2")
        let broken = try #require(try await log.audit().broken)
        #expect(broken.seq == 3 && broken.reason.contains("follow"))
    }

    @Test func pruningKeepsWhatIsLeftWhole() async throws {
        let path = try folder().appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        await log.appendAudit([record(1), record(2), record(3)])
        let later = now.addingTimeInterval(AuditChain.retention + 2.5)
        #expect(await log.pruneAudit(now: later) == 2)
        let (records, broken) = try await log.audit()
        #expect(records == [record(3)] && broken == nil)
        await log.appendAudit([record(4)])
        #expect(try await log.audit().broken == nil)
    }

    @Test func theExportIsOneRowPerLineWithItsHash() async throws {
        let path = try folder().appendingPathComponent("heed.sqlite").path
        let log = try EventLog(path: path)
        await log.appendAudit([record(1), record(2)])
        let rows = try await log.auditRows()
        let lines = AuditChain.exportLines(rows).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        #expect(first["hash"] as? String == rows[1].hash && first["kind"] as? String == "action")
        #expect((first["record"] as? [String: Any])?["what"] as? String == "pushed 2")
    }
}
