import Foundation
@testable import HeedCore
import Testing

struct SQLiteTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func everyKindOfValueRoundTrips() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (v)")
        let values: [SQLiteValue] = [
            .null, .integer(-42), .integer(Int64.max), .real(1.5), .text(""), .text("naïve ✓"),
            .text("before\0after"), .blob(Data()), .blob(Data([0, 1, 2, 255])),
        ]
        let insert = try db.prepare("INSERT INTO t (v) VALUES (?)")
        for value in values {
            try insert.bind([value])
            try insert.run()
        }
        let read = try db.query("SELECT v FROM t ORDER BY rowid") { $0[0] }
        #expect(read == values)
    }

    @Test func optionalsAndDatesBindAsExpected() throws {
        let db = try SQLiteDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 1_760_000_000.25)
        let row = try db.query(
            "SELECT ?, ?, ?, ?",
            [SQLiteValue(date), SQLiteValue(String?.none), SQLiteValue(true), SQLiteValue(7 as Int?)]
        ) { [$0[0], $0[1], $0[2], $0[3]] }[0]
        #expect(row[0].date == date)
        #expect(row[1].isNull)
        #expect(row[2].bool == true)
        #expect(row[3].int == 7)
    }

    @Test func theWrongNumberOfValuesIsAnError() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(throws: SQLiteError.self) { try db.run("SELECT ?, ?", [1]) }
    }

    @Test func badSQLSaysWhatFailed() throws {
        let db = try SQLiteDatabase.inMemory()
        let error = #expect(throws: SQLiteError.self) { try db.prepare("SELEC 1") }
        #expect(error?.message.contains("syntax error") == true)
        #expect(error?.sql == "SELEC 1")
    }

    @Test func aStatementIsReusedAcrossBinds() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (n INTEGER)")
        let insert = try db.prepare("INSERT INTO t (n) VALUES (?)")
        for number in 1 ... 100 {
            try insert.bind([.integer(Int64(number))])
            try insert.run()
        }
        #expect(try db.scalar("SELECT sum(n) FROM t")?.int == 5050)
        #expect(db.lastInsertRowID == 100)
    }

    @Test func aTransactionCommitsWhenItReturns() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (n INTEGER)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            try db.run("INSERT INTO t VALUES (2)")
        }
        #expect(try db.scalar("SELECT count(*) FROM t")?.int == 2)
    }

    @Test func aTransactionRollsBackWhenItThrows() throws {
        struct Stop: Error {}
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (n INTEGER)")
        #expect(throws: Stop.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                throw Stop()
            }
        }
        #expect(try db.scalar("SELECT count(*) FROM t")?.int == 0)
        // And the connection is usable again: no transaction was left open.
        try db.transaction { try db.run("INSERT INTO t VALUES (3)") }
        #expect(try db.scalar("SELECT count(*) FROM t")?.int == 1)
    }

    private let schema = [
        SQLiteMigration(sql: "CREATE TABLE a (n INTEGER)"),
        SQLiteMigration(sql: "ALTER TABLE a ADD COLUMN m TEXT"),
    ]

    @Test func migrationsRunOnceInOrder() throws {
        let file = try folder().appendingPathComponent("m.sqlite").path
        do {
            let db = try SQLiteDatabase(path: file)
            try db.migrate(Array(schema.prefix(1)))
            #expect(try db.userVersion == 1)
            try db.run("INSERT INTO a (n) VALUES (1)")
        }
        let db = try SQLiteDatabase(path: file)
        // The first migration is not run again (it would fail: the table exists); only the second one runs.
        try db.migrate(schema)
        #expect(try db.userVersion == 2)
        try db.migrate(schema)
        #expect(try db.userVersion == 2)
        #expect(try db.query("SELECT n, m FROM a") { [$0[0], $0[1]] } == [[.integer(1), .null]])
    }

    @Test func aFailedMigrationLeavesTheVersionItReallyHas() throws {
        let db = try SQLiteDatabase.inMemory()
        let broken = schema + [
            SQLiteMigration { db in
                try db.execute("CREATE TABLE b (n INTEGER)")
                try db.execute("NOT SQL")
            },
        ]
        #expect(throws: SQLiteError.self) { try db.migrate(broken) }
        #expect(try db.userVersion == 2)
        // The half-done third migration was rolled back with its version bump.
        #expect(try db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'b'")?.int == 0)
    }

    @Test func aFileFromANewerBuildIsNotWrittenTo() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.migrate(schema)
        let error = #expect(throws: SQLiteError.self) { try db.migrate(Array(schema.prefix(1))) }
        #expect(error?.message.contains("newer") == true)
        #expect(try db.userVersion == 2)
    }

    @Test func aFileDatabaseIsInWALMode() throws {
        let file = try folder().appendingPathComponent("sub/dir/w.sqlite").path
        let db = try SQLiteDatabase(path: file)
        #expect(try db.scalar("PRAGMA journal_mode")?.text == "wal")
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// A process killed mid-write leaves the files as they are on disk at that moment (the OS keeps what was written).
    /// A copy of the database and its WAL taken while a transaction is open is exactly that state: opening the copy
    /// must find every committed row, none of the open transaction's, and a database that passes its integrity check.
    @Test func aKillMidWriteKeepsWhatWasCommitted() throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("k.sqlite")
        let db = try SQLiteDatabase(path: file.path)
        try db.execute("CREATE TABLE t (n INTEGER, payload TEXT)")
        // Enough rows that the open transaction spills pages into the WAL before it commits.
        let payload = String(repeating: "x", count: 1000)
        try db.transaction {
            for number in 0 ..< 500 {
                try db.run("INSERT INTO t VALUES (?, ?)", [.integer(Int64(number)), .text(payload)])
            }
        }
        let committedWAL = try size(of: file.path + "-wal")
        // A small cache that spills early (Apple's build spills only past 20000 pages), so uncommitted pages are in the
        // WAL when the copy is taken, as they are in a large write.
        try db.execute("PRAGMA cache_size = 10; PRAGMA cache_spill = 10")
        try db.execute("BEGIN IMMEDIATE")
        for number in 500 ..< 3000 {
            try db.run("INSERT INTO t VALUES (?, ?)", [.integer(Int64(number)), .text(payload)])
        }
        let crashed = dir.appendingPathComponent("crashed")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: file.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: crashed.appendingPathComponent("k.sqlite" + suffix))
        }
        let walSize = try size(of: crashed.appendingPathComponent("k.sqlite-wal").path)
        #expect(walSize > committedWAL + 1_000_000, "the open transaction should have written into the WAL")

        let reopened = try SQLiteDatabase(path: crashed.appendingPathComponent("k.sqlite").path)
        #expect(try reopened.scalar("PRAGMA integrity_check")?.text == "ok")
        #expect(try reopened.scalar("SELECT count(*) FROM t")?.int == 500)
        try db.execute("ROLLBACK")
    }

    private func size(of path: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
    }

    @Test func aConnectionSerializesUseOffTheMainActor() async throws {
        let file = try folder().appendingPathComponent("c.sqlite").path
        let connection = try SQLiteConnection(path: file, migrations: [SQLiteMigration(sql: "CREATE TABLE t (n)")])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0 ..< 50 {
                group.addTask {
                    try await connection.perform { try $0.run("INSERT INTO t VALUES (?)", [.integer(Int64(number))]) }
                }
            }
        }
        let count = try await connection.perform { try $0.scalar("SELECT count(*) FROM t")?.int }
        #expect(count == 50)
    }

    /// Recorded for plan 5 (ledger search): the system SQLite has FTS5, so search does not need `LIKE`.
    @Test func theSystemSQLiteHasFTS5() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(try db.hasFTS5())
        try db.execute("CREATE VIRTUAL TABLE f USING fts5(body)")
        try db.run("INSERT INTO f (body) VALUES (?)", ["merged the docs-toolkit fix"])
        #expect(try db.scalar("SELECT count(*) FROM f WHERE f MATCH 'docs*'")?.int == 1)
    }
}
