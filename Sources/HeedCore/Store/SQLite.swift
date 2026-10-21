import Foundation
import SQLite3

/// A thin wrapper over the system SQLite (`import SQLite3`, nothing bundled): open, prepare, bind, step, transactions
/// and migrations by `PRAGMA user_version`. Heed's queries are simple; this stays small on purpose.
///
/// A connection is not thread-safe on its own (the system build is `THREADSAFE=2`): each one is owned by exactly one
/// actor, which is the only thing that ever touches it. Nothing here runs on the main actor.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    /// Opens (creating it if needed) the database at `path`; `":memory:"` opens a private in-memory one. A file
    /// database is put in WAL mode, so a reader never waits on the writer and a crash mid-write loses only the
    /// transaction that was open.
    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message, sql: "open \(path)")
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            // NORMAL is durable across a crash of the app in WAL mode; only a power loss can drop the last commits.
            try execute("PRAGMA synchronous = NORMAL")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    /// An in-memory database, for tests and fixtures.
    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { close() }

    public func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    private var db: OpaquePointer {
        get throws {
            guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: "") }
            return handle
        }
    }

    /// Runs one or more statements with no parameters and no results (schema, pragmas).
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = try sqlite3_exec(db, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "error \(code)"
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = try sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw try failure(code, sql) }
        return SQLiteStatement(statement, database: self, sql: sql)
    }

    /// Runs one statement that returns no rows (insert, update, delete).
    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        try statement.run()
    }

    /// Runs a query and maps each row.
    public func query<T>(_ sql: String, _ values: [SQLiteValue] = [], row map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while let row = try statement.step() {
            try rows.append(map(row))
        }
        return rows
    }

    /// The first column of the first row, or nil when there is none.
    public func scalar(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteValue? {
        try query(sql, values) { $0[0] }.first
    }

    /// Runs `body` in one transaction: committed when it returns, rolled back when it throws. `IMMEDIATE` takes the
    /// write lock up front, so two connections never deadlock upgrading a read to a write.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The rowid of the last insert on this connection.
    public var lastInsertRowID: Int64 { (try? sqlite3_last_insert_rowid(db)) ?? 0 }

    /// Rows changed by the last insert, update or delete.
    public var changes: Int { Int((try? sqlite3_changes(db)) ?? 0) }

    /// `PRAGMA user_version`: how many migrations this file has had.
    public var userVersion: Int {
        get throws { try scalar("PRAGMA user_version")?.int ?? 0 }
    }

    /// Brings the schema up to date. Migration `n` (0-based) runs when `user_version` is `n`, each in its own
    /// transaction together with the version bump, so a crash between two leaves the file at a version it is
    /// really at. A file from a newer build (a version past the last migration) is refused rather than written to.
    public func migrate(_ migrations: [SQLiteMigration]) throws {
        let current = try userVersion
        guard current <= migrations.count else {
            throw SQLiteError(
                code: SQLITE_ERROR,
                message: "schema version \(current) is newer than this build's \(migrations.count)", sql: ""
            )
        }
        for (index, migration) in migrations.enumerated().dropFirst(current) {
            try transaction {
                try migration.apply(self)
                // A pragma takes no parameters; the index is an Int, so this is not an injection.
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    /// `PRAGMA compile_options` of the SQLite this process loaded.
    public func compileOptions() throws -> [String] {
        try query("PRAGMA compile_options") { $0[0].text ?? "" }
    }

    /// Whether full-text search (FTS5) is available in this SQLite.
    public func hasFTS5() throws -> Bool { try compileOptions().contains("ENABLE_FTS5") }

    fileprivate func failure(_ code: Int32, _ sql: String) throws -> SQLiteError {
        try SQLiteError(code: code, message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }
}

/// The one owner of a connection: every use of the database goes through `perform`, serialized on this actor and so
/// off the main actor. Views read through it too; a WAL file lets a second connection read while this one writes.
public actor SQLiteConnection {
    private let database: SQLiteDatabase

    /// Opens `path` and migrates it.
    public init(path: String, migrations: [SQLiteMigration]) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(migrations)
    }

    public func perform<T: Sendable>(_ body: @Sendable (SQLiteDatabase) throws -> T) throws -> T {
        try body(database)
    }
}

/// One step of a schema: SQL to run, or code for what SQL cannot say (copying data in from elsewhere).
public struct SQLiteMigration: Sendable {
    let apply: @Sendable (SQLiteDatabase) throws -> Void

    public init(_ apply: @escaping @Sendable (SQLiteDatabase) throws -> Void) { self.apply = apply }

    public init(sql: String) { apply = { try $0.execute(sql) } }
}

public struct SQLiteError: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public let sql: String

    public var description: String { "sqlite \(code): \(message)\(sql.isEmpty ? "" : " (\(sql))")" }
}

/// A value going into or coming out of a column.
public enum SQLiteValue: Sendable, Equatable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int: Int? {
        if case let .integer(value) = self { return Int(value) }
        return nil
    }

    public var int64: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case let .real(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    public var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    public var data: Data? {
        switch self {
        case let .blob(value): value
        case let .text(value): Data(value.utf8)
        default: nil
        }
    }

    public var bool: Bool? { int.map { $0 != 0 } }

    /// Dates are stored as seconds since 1970, as a real, so ranges compare and sort as numbers.
    public var date: Date? { double.map { Date(timeIntervalSince1970: $0) } }

    public var isNull: Bool { self == .null }
}

extension SQLiteValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByNilLiteral, ExpressibleByBooleanLiteral
{
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(nilLiteral _: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }
}

public extension SQLiteValue {
    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    init(_ value: Bool?) { self = value.map { .integer($0 ? 1 : 0) } ?? .null }
    init(_ value: Data?) { self = value.map { .blob($0) } ?? .null }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// A prepared statement. Reusable: `bind` resets it, so a batch insert prepares once and steps many times.
public final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: SQLiteDatabase
    public let sql: String

    fileprivate init(_ handle: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    /// Binds `values` to `?1`, `?2`, … after resetting the statement.
    public func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard values.count == expected else {
            throw SQLiteError(
                code: SQLITE_RANGE,
                message: "\(values.count) values for \(expected) parameters",
                sql: sql
            )
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code = switch value {
            case .null: sqlite3_bind_null(handle, index)
            case let .integer(number): sqlite3_bind_int64(handle, index, number)
            case let .real(number): sqlite3_bind_double(handle, index, number)
            case let .text(string):
                // With its length, so text holding a NUL is stored whole.
                string.utf8CString.withUnsafeBufferPointer { chars in
                    sqlite3_bind_text(handle, index, chars.baseAddress, Int32(chars.count - 1), sqliteTransient)
                }
            case let .blob(data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard code == SQLITE_OK else { throw try database.failure(code, sql) }
        }
    }

    /// Steps once: the next row, or nil when done.
    public func step() throws -> SQLiteRow? {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return SQLiteRow(handle)
        case SQLITE_DONE: return nil
        default: throw try database.failure(code, sql)
        }
    }

    /// Steps to the end, ignoring rows.
    public func run() throws {
        while try step() != nil {}
    }
}

/// The current row of a statement; valid until the statement steps again.
public struct SQLiteRow {
    private let handle: OpaquePointer

    fileprivate init(_ handle: OpaquePointer) { self.handle = handle }

    public var count: Int { Int(sqlite3_column_count(handle)) }

    public subscript(index: Int) -> SQLiteValue {
        let column = Int32(index)
        switch sqlite3_column_type(handle, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(handle, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(handle, column))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(handle, column))
            guard count > 0, let text = sqlite3_column_text(handle, column) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(handle, column))
            guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    public func name(_ index: Int) -> String { String(cString: sqlite3_column_name(handle, Int32(index))) }
}

/// SQLite copies the bytes before the bind call returns (the C API's `SQLITE_TRANSIENT`).
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
