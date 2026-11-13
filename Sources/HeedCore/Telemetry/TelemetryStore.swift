import Foundation

/// `[telemetry]`: heed's receiver for the agents' own OpenTelemetry, and what it keeps.
public struct TelemetrySettings: Equatable, Sendable {
    /// Whether heed listens for, and points the agents it starts at, their telemetry.
    public var enabled = true
    /// The port on 127.0.0.1. 4318 is OTLP/HTTP's own.
    public var port = 4318
    /// Days kept.
    public var days = 7
    /// Spans kept at most, newest first, whatever their age (prompts and usage samples as many each).
    public var maxRows = 200_000
    /// Ask Claude Code for its tool details (the bash command, the file): they stay on this Mac.
    public var toolDetails = true
    /// Ask the agents to include your prompts' text, so a turn reads by what you asked.
    public var prompts = false
    /// An agent you send telemetry from yourself is pointed at heed too, and heed forwards each export unchanged to
    /// where it went; false: heed leaves that agent alone.
    public var proxy = true

    public init() {}
}

/// `telemetry.sqlite`: the agents' spans, prompts and usage samples, apart from the call log and the domain, so
/// pruning it never touches either. One actor owns the connection; nothing here runs on the main actor.
public actor TelemetryStore {
    private let database: SQLiteDatabase

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    /// In memory, for tests.
    public init() throws {
        database = try SQLiteDatabase.inMemory()
        try database.migrate(Self.schema)
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE spans (
            id TEXT PRIMARY KEY,
            start REAL NOT NULL,
            end REAL NOT NULL,
            agent TEXT NOT NULL,
            kind TEXT NOT NULL,
            body TEXT NOT NULL
        );
        CREATE INDEX spans_end ON spans (end);
        CREATE TABLE prompts (id INTEGER PRIMARY KEY, at REAL NOT NULL, body TEXT NOT NULL);
        CREATE INDEX prompts_at ON prompts (at);
        CREATE TABLE usage (id INTEGER PRIMARY KEY, at REAL NOT NULL, body TEXT NOT NULL);
        CREATE INDEX usage_at ON usage (at);
        """),
    ]

    private static func json(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder.heed.encode(value), as: UTF8.self)
    }

    /// Writes one export's records. A span sent again (same id) replaces the one kept.
    public func insert(_ records: TelemetryRecords) {
        guard !records.isEmpty else { return }
        do {
            try database.transaction {
                let span = try database.prepare(
                    "INSERT OR REPLACE INTO spans (id, start, end, agent, kind, body) VALUES (?, ?, ?, ?, ?, ?)"
                )
                for item in records.spans {
                    try span.bind([
                        .text(item.id), SQLiteValue(item.start), SQLiteValue(item.end), .text(item.agent),
                        .text(item.kind.rawValue), .text(Self.json(item)),
                    ])
                    try span.run()
                }
                let prompt = try database.prepare("INSERT INTO prompts (at, body) VALUES (?, ?)")
                for item in records.prompts {
                    try prompt.bind([SQLiteValue(item.at), .text(Self.json(item))])
                    try prompt.run()
                }
                let usage = try database.prepare("INSERT INTO usage (at, body) VALUES (?, ?)")
                for item in records.usage {
                    try usage.bind([SQLiteValue(item.at), .text(Self.json(item))])
                    try usage.run()
                }
            }
        } catch {
            NSLog("heed: could not keep telemetry: \(error)")
        }
    }

    /// Everything that ended (or happened) since `since`, oldest first: the spans at most `limit`, the newest kept.
    public func records(since: Date, limit: Int = 50000) throws -> TelemetryRecords {
        let decoder = JSONDecoder.heed
        let spans = try database.query(
            "SELECT body FROM (SELECT body, end FROM spans WHERE end >= ? ORDER BY end DESC LIMIT ?) ORDER BY end",
            [SQLiteValue(since), .integer(Int64(limit))]
        ) { $0[0].data.flatMap { try? decoder.decode(AgentSpan.self, from: $0) } }.compactMap(\.self)
        let prompts = try database.query(
            "SELECT body FROM prompts WHERE at >= ? ORDER BY at", [SQLiteValue(since)]
        ) { $0[0].data.flatMap { try? decoder.decode(AgentPrompt.self, from: $0) } }.compactMap(\.self)
        let usage = try database.query(
            "SELECT body FROM usage WHERE at >= ? ORDER BY at", [SQLiteValue(since)]
        ) { $0[0].data.flatMap { try? decoder.decode(AgentUsageSample.self, from: $0) } }.compactMap(\.self)
        return TelemetryRecords(spans: spans, prompts: prompts, usage: usage)
    }

    /// Drops what is older than `days`, then the oldest past `maxRows` in each table. Returns how many went.
    @discardableResult
    public func prune(now: Date, settings: TelemetrySettings) -> Int {
        let cutoff = SQLiteValue(now.addingTimeInterval(-Double(settings.days) * 86400))
        let cap = SQLiteValue.integer(Int64(settings.maxRows))
        var removed = 0
        do {
            try database.transaction {
                for (table, column) in [("spans", "end"), ("prompts", "at"), ("usage", "at")] {
                    try database.run("DELETE FROM \(table) WHERE \(column) < ?", [cutoff])
                    removed += database.changes
                    try database.run(
                        """
                        DELETE FROM \(table) WHERE rowid NOT IN (
                            SELECT rowid FROM \(table) ORDER BY \(column) DESC LIMIT ?
                        )
                        """,
                        [cap]
                    )
                    removed += database.changes
                }
            }
        } catch {
            NSLog("heed: could not prune telemetry: \(error)")
        }
        return removed
    }

    /// Spans kept, for Settings.
    public func count() throws -> Int { try database.scalar("SELECT count(*) FROM spans")?.int ?? 0 }
}
