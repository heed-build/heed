import Foundation

/// An item as the store keeps it: what it was when last seen, and when it was first and last seen.
public struct StoredAttentionItem: Hashable, Sendable {
    public var item: AttentionItem
    public var firstSeen: Date
    public var lastSeen: Date

    public init(item: AttentionItem, firstSeen: Date, lastSeen: Date) {
        self.item = item
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// `attention.sqlite`: every Attention item heed has seen in the last 30 days (muted and ignored ones too, so the
/// Muted tab keeps them and a rule can be tried against what it would have changed), what you did to each (done,
/// snoozed, muted), the thread details fetched for them, their summaries, and when you last looked at each thread
/// and at Attention. Its own file beside `heed.sqlite`, so its schema moves on its own.
public actor AttentionStore {
    private let database: SQLiteDatabase

    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// `~/Library/Application Support/Heed/attention.sqlite`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/attention.sqlite")
    }

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    /// Opens the store off the main actor; nil (logged) when it cannot be opened, and Attention keeps nothing past
    /// what is live.
    public static func open(at file: URL) async -> AttentionStore? {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                return try AttentionStore(path: file.path)
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); Attention keeps no history")
                return nil
            }
        }.value
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE items (
            id TEXT PRIMARY KEY,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            updated_at REAL NOT NULL,
            item TEXT NOT NULL
        );
        CREATE INDEX items_seen ON items (last_seen);
        CREATE TABLE marks (
            id TEXT PRIMARY KEY,
            done_at REAL,
            snoozed_until REAL,
            muted_at REAL
        );
        CREATE TABLE details (
            url TEXT PRIMARY KEY,
            updated_at REAL NOT NULL,
            fetched_at REAL NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE TABLE summaries (
            id TEXT PRIMARY KEY,
            updated_at REAL NOT NULL,
            summary TEXT NOT NULL
        );
        """),
        // When you last looked: at each thread (opened in Attention's reader), and when you last left Attention.
        SQLiteMigration(sql: """
        CREATE TABLE seen (
            id TEXT PRIMARY KEY,
            seen_at REAL NOT NULL
        );
        CREATE TABLE moments (
            name TEXT PRIMARY KEY,
            at REAL NOT NULL
        );
        """),
        // Catch-up summaries (what is new since you last looked) replace the whole-thread ones, which go.
        SQLiteMigration(sql: """
        DROP TABLE summaries;
        CREATE TABLE summaries (
            id TEXT PRIMARY KEY,
            written_at REAL NOT NULL,
            summary TEXT NOT NULL
        );
        """),
    ]

    // MARK: Items

    /// Keeps `items` as seen at `now`: new ones are added, known ones replaced (their first sighting kept).
    public func record(_ items: [AttentionItem], now: Date) throws {
        guard !items.isEmpty else { return }
        try database.transaction {
            let upsert = try database.prepare("""
            INSERT INTO items (id, first_seen, last_seen, updated_at, item) VALUES (?1, ?2, ?2, ?3, ?4)
            ON CONFLICT (id) DO UPDATE SET last_seen = ?2, updated_at = ?3, item = ?4
            """)
            for item in items {
                try upsert.bind([.text(item.id), SQLiteValue(now), SQLiteValue(item.updatedAt), .text(Self.json(item))])
                try upsert.run()
            }
        }
    }

    /// Items seen since `since` (30 days by default), newest update first. A row that no longer decodes (one kept
    /// with a reason heed has since dropped, such as `watching`) is skipped, not an error for the rest.
    public func items(since: Date? = nil, now: Date = Date()) throws -> [StoredAttentionItem] {
        try database.query(
            "SELECT item, first_seen, last_seen FROM items WHERE last_seen >= ? ORDER BY updated_at DESC, id",
            [SQLiteValue(since ?? now.addingTimeInterval(-Self.retention))]
        ) { row -> StoredAttentionItem? in
            guard let item = try? JSONDecoder.heed.decode(AttentionItem.self, from: row[0].data ?? Data()) else {
                return nil
            }
            return StoredAttentionItem(
                item: item, firstSeen: row[1].date ?? .distantPast, lastSeen: row[2].date ?? .distantPast
            )
        }
        .compactMap { $0 }
    }

    // MARK: Marks

    public func marks() throws -> [String: AttentionMark] {
        let rows = try database.query("SELECT id, done_at, snoozed_until, muted_at FROM marks") { row in
            (row[0].text ?? "", AttentionMark(doneAt: row[1].date, snoozedUntil: row[2].date, mutedAt: row[3].date))
        }
        return Dictionary(rows) { _, last in last }
    }

    /// Sets (or, when empty, clears) what you did to an item.
    public func setMark(_ mark: AttentionMark, for id: String) throws {
        if mark == AttentionMark() {
            try database.run("DELETE FROM marks WHERE id = ?", [.text(id)])
        } else {
            try database.run(
                "INSERT OR REPLACE INTO marks (id, done_at, snoozed_until, muted_at) VALUES (?, ?, ?, ?)",
                [.text(id), SQLiteValue(mark.doneAt), SQLiteValue(mark.snoozedUntil), SQLiteValue(mark.mutedAt)]
            )
        }
    }

    // MARK: Details and summaries

    /// Thread details by URL, lowercased.
    public func details() throws -> [String: ThreadDetail] {
        let rows = try database.query("SELECT url, detail FROM details") { row in
            try (row[0].text ?? "", JSONDecoder.heed.decode(ThreadDetail.self, from: row[1].data ?? Data()))
        }
        return Dictionary(rows) { _, last in last }
    }

    public func saveDetails(_ details: [ThreadDetail], now: Date) throws {
        guard !details.isEmpty else { return }
        try database.transaction {
            let insert = try database.prepare(
                "INSERT OR REPLACE INTO details (url, updated_at, fetched_at, detail) VALUES (?, ?, ?, ?)"
            )
            for detail in details {
                try insert.bind([
                    .text(detail.url.lowercased()), SQLiteValue(detail.updatedAt), SQLiteValue(now),
                    .text(Self.json(detail)),
                ])
                try insert.run()
            }
        }
    }

    /// Every item's catch-up summary, by item id.
    public func catchUps() throws -> [String: CatchUpSummary] {
        let rows = try database.query("SELECT id, summary FROM summaries") { row in
            try (row[0].text ?? "", JSONDecoder.heed.decode(CatchUpSummary.self, from: row[1].data ?? Data()))
        }
        return Dictionary(rows) { _, last in last }
    }

    /// Keeps an item's catch-up summary, replacing the one before.
    public func saveCatchUp(_ summary: CatchUpSummary, for id: String) throws {
        try database.run(
            "INSERT OR REPLACE INTO summaries (id, written_at, summary) VALUES (?, ?, ?)",
            [.text(id), SQLiteValue(summary.writtenAt), .text(Self.json(summary))]
        )
    }

    // MARK: Seen

    /// When you last looked at each thread, and when you last left Attention.
    public func seen() throws -> AttentionSeen {
        let rows = try database.query("SELECT id, seen_at FROM seen") { row in
            (row[0].text ?? "", row[1].date ?? .distantPast)
        }
        let left = try database.scalar("SELECT at FROM moments WHERE name = 'left'", [])?.date
        return AttentionSeen(threads: Dictionary(rows) { _, last in last }, leftAt: left)
    }

    /// You looked at a thread at `at`; an earlier time never replaces a later one.
    public func setSeen(_ id: String, at: Date) throws {
        try database.run(
            """
            INSERT INTO seen (id, seen_at) VALUES (?1, ?2)
            ON CONFLICT (id) DO UPDATE SET seen_at = max(seen_at, ?2)
            """,
            [.text(id), SQLiteValue(at)]
        )
    }

    /// You left Attention at `at`.
    public func setLeft(at: Date) throws {
        try database.run(
            "INSERT OR REPLACE INTO moments (name, at) VALUES ('left', ?)", [SQLiteValue(at)]
        )
    }

    // MARK: Retention

    /// Drops items not seen for 30 days, with their marks and summaries, and details fetched that long ago.
    public func prune(now: Date) throws {
        let cutoff = SQLiteValue(now.addingTimeInterval(-Self.retention))
        try database.transaction {
            try database.run("DELETE FROM items WHERE last_seen < ?", [cutoff])
            try database.run("DELETE FROM marks WHERE id NOT IN (SELECT id FROM items)")
            try database.run("DELETE FROM summaries WHERE id NOT IN (SELECT id FROM items)")
            try database.run("DELETE FROM seen WHERE id NOT IN (SELECT id FROM items)")
            try database.run("DELETE FROM details WHERE fetched_at < ?", [cutoff])
        }
    }

    private static func json(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder.heed.encode(value), as: UTF8.self)
    }
}
