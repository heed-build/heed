import Foundation

/// Where Browse was left: the scope and the query last used, so it opens where you were.
public struct BrowseLast: Hashable, Sendable, Codable {
    public var scope: BrowseScope?
    public var query: BrowseQuery

    public init(scope: BrowseScope?, query: BrowseQuery) {
        self.scope = scope
        self.query = query
    }
}

/// `browse.sqlite`: the issues and pull requests Browse has fetched (kept 30 days after they were last fetched), the
/// queries you saved, and the scope and query last used. Its own file beside the domain file, so its schema moves on
/// its own and pruning it never touches anything else.
public actor BrowseStore {
    private let database: SQLiteDatabase

    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// Reads stay longer than the items: a read cost a model call.
    public static let readRetention: TimeInterval = 90 * 24 * 60 * 60

    /// `~/Library/Application Support/Heed/browse.sqlite`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/browse.sqlite")
    }

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    /// Opens the store off the main actor; nil (logged) when it cannot be opened, and Browse keeps nothing past what
    /// it fetched this run.
    public static func open(at file: URL) async -> BrowseStore? {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                return try BrowseStore(path: file.path)
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); Browse keeps no cache")
                return nil
            }
        }.value
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE items (
            id TEXT PRIMARY KEY,
            fetched_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            item TEXT NOT NULL
        );
        CREATE INDEX items_fetched ON items (fetched_at);
        CREATE TABLE saved (
            id TEXT PRIMARY KEY,
            position INTEGER NOT NULL,
            query TEXT NOT NULL
        );
        CREATE TABLE scopes (
            id TEXT PRIMARY KEY,
            position INTEGER NOT NULL,
            scope TEXT NOT NULL
        );
        CREATE TABLE state (
            name TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """),
        // heed's reads of items: local to this Mac, one per item, the `updatedAt` it was read at inside.
        SQLiteMigration(sql: """
        CREATE TABLE reads (
            id TEXT PRIMARY KEY,
            read_at REAL NOT NULL,
            item_updated_at REAL NOT NULL,
            read TEXT NOT NULL
        );
        CREATE INDEX reads_read_at ON reads (read_at);
        """),
    ]

    // MARK: Items

    /// Keeps `items` as fetched at `now`, replacing known ones.
    public func record(_ items: [BrowseItem], now: Date) throws {
        guard !items.isEmpty else { return }
        try database.transaction {
            let upsert = try database.prepare("""
            INSERT INTO items (id, fetched_at, updated_at, item) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT (id) DO UPDATE SET fetched_at = ?2, updated_at = ?3, item = ?4
            """)
            for item in items {
                try upsert.bind([.text(item.id), SQLiteValue(now), SQLiteValue(item.updatedAt), .text(Self.json(item))])
                try upsert.run()
            }
        }
    }

    /// Drops cached items GitHub no longer lists for a view (closed, moved away).
    public func forget(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            let delete = try database.prepare("DELETE FROM items WHERE id = ?1")
            for id in ids {
                try delete.bind([.text(id)])
                try delete.run()
            }
        }
    }

    /// The cached items, newest update first. A row that no longer decodes is skipped, not an error for the rest.
    public func items(now: Date = Date()) throws -> [BrowseItem] {
        try database.query(
            "SELECT item FROM items WHERE fetched_at >= ? ORDER BY updated_at DESC, id",
            [SQLiteValue(now.addingTimeInterval(-Self.retention))]
        ) { row -> BrowseItem? in
            try? JSONDecoder.heed.decode(BrowseItem.self, from: row[0].data ?? Data())
        }
        .compactMap { $0 }
    }

    // MARK: heed's reads

    /// Keeps a read, replacing the item's earlier one.
    public func save(_ read: BrowseRead) throws {
        try database.run(
            """
            INSERT INTO reads (id, read_at, item_updated_at, read) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT (id) DO UPDATE SET read_at = ?2, item_updated_at = ?3, read = ?4
            """,
            [.text(read.itemID), SQLiteValue(read.readAt), SQLiteValue(read.itemUpdatedAt), .text(Self.json(read))]
        )
    }

    /// The reads kept, by item id. One that no longer decodes is skipped.
    public func reads(now: Date = Date()) throws -> BrowseReads {
        let rows = try database.query(
            "SELECT read FROM reads WHERE read_at >= ?",
            [SQLiteValue(now.addingTimeInterval(-Self.readRetention))]
        ) { row -> BrowseRead? in
            try? JSONDecoder.heed.decode(BrowseRead.self, from: row[0].data ?? Data())
        }
        return Dictionary(rows.compactMap { $0 }.map { ($0.itemID, $0) }) { _, last in last }
    }

    // MARK: Saved queries

    /// The saved queries in the order they were kept. One that no longer decodes is skipped.
    public func savedQueries() throws -> [SavedQuery] {
        try database.query("SELECT query FROM saved ORDER BY position, id") { row -> SavedQuery? in
            try? JSONDecoder.heed.decode(SavedQuery.self, from: row[0].data ?? Data())
        }
        .compactMap { $0 }
    }

    /// Adds a saved query at the end, or replaces the one with its id in place.
    public func save(_ query: SavedQuery) throws {
        try database.transaction {
            var position = try database.scalar("SELECT position FROM saved WHERE id = ?", [.text(query.id)])?.int
            if position == nil {
                position = try database.scalar("SELECT COALESCE(MAX(position), -1) + 1 FROM saved")?.int ?? 0
            }
            try database.run(
                "INSERT INTO saved (id, position, query) VALUES (?1, ?2, ?3) ON CONFLICT (id) DO UPDATE SET query = ?3",
                [.text(query.id), .integer(Int64(position ?? 0)), .text(Self.json(query))]
            )
        }
    }

    /// Puts the saved queries in the order of `ids`, which names each of them.
    public func reorderQueries(_ ids: [String]) throws {
        try database.transaction {
            for (position, id) in ids.enumerated() {
                try database.run("UPDATE saved SET position = ? WHERE id = ?", [.integer(Int64(position)), .text(id)])
            }
        }
    }

    public func removeQuery(id: String) throws {
        try database.run("DELETE FROM saved WHERE id = ?", [.text(id)])
    }

    // MARK: Scopes in the rail

    /// The scopes kept in the rail, in the order they were kept. One that no longer decodes is skipped.
    public func scopes() throws -> [BrowseScope] {
        try database.query("SELECT scope FROM scopes ORDER BY position, id") { row -> BrowseScope? in
            try? JSONDecoder.heed.decode(BrowseScope.self, from: row[0].data ?? Data())
        }
        .compactMap { $0 }
    }

    /// Keeps a scope in the rail, at the end; one already there stays where it is.
    public func pin(_ scope: BrowseScope) throws {
        try database.run(
            "INSERT OR IGNORE INTO scopes (id, position, scope) VALUES (?1, (SELECT COALESCE(MAX(position), -1) + 1 FROM scopes), ?2)",
            [.text(scope.id), .text(Self.json(scope))]
        )
    }

    public func unpin(_ scope: BrowseScope) throws {
        try database.run("DELETE FROM scopes WHERE id = ?", [.text(scope.id)])
    }

    // MARK: Where you were

    /// Whether something was done once (the starter queries seeded), so removing them does not bring them back.
    public func flag(_ name: String) throws -> Bool {
        try database.scalar("SELECT value FROM state WHERE name = ?", [.text("flag:" + name)]) != nil
    }

    public func setFlag(_ name: String) throws {
        try database.run("INSERT OR REPLACE INTO state (name, value) VALUES (?1, '1')", [.text("flag:" + name)])
    }

    public func last() throws -> BrowseLast? {
        try database.scalar("SELECT value FROM state WHERE name = 'last'")?.data
            .flatMap { try? JSONDecoder.heed.decode(BrowseLast.self, from: $0) }
    }

    public func setLast(_ last: BrowseLast) throws {
        try database.run(
            "INSERT INTO state (name, value) VALUES ('last', ?1) ON CONFLICT (name) DO UPDATE SET value = ?1",
            [.text(Self.json(last))]
        )
    }

    // MARK: Retention

    /// Drops items not fetched for 30 days, and reads older than 90.
    public func prune(now: Date) throws {
        try database.run(
            "DELETE FROM items WHERE fetched_at < ?", [SQLiteValue(now.addingTimeInterval(-Self.retention))]
        )
        try database.run(
            "DELETE FROM reads WHERE read_at < ?", [SQLiteValue(now.addingTimeInterval(-Self.readRetention))]
        )
    }

    /// The most rows one transaction deletes, so a big cache never holds the file for long.
    public static let pruneBatch = 500

    /// Drops what Browse cached outside what is checked out: items (and heed's reads of them) whose org is not in
    /// `orgs`, compared without case. Only `browse.sqlite`: saved queries and pinned scopes stay (a pinned scope for an
    /// org with no checkout shows the check-out-first state). With no orgs it does nothing: an empty list is more
    /// likely a repo list not loaded yet than a Mac with nothing checked out, and the list shows nothing for it anyway.
    /// Deletes in batches of `pruneBatch`, each its own transaction, yielding between them; safe to run twice, and a
    /// stop in the middle leaves the rows that were not reached, all consistent. Returns the items removed.
    @discardableResult
    public func prune(keepingOrgs orgs: [String]) async throws -> Int {
        let keep = Set(orgs.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard !keep.isEmpty else { return 0 }
        func outside(_ id: String) -> Bool {
            // `org/repo#12`: the id's org; one without a slash is not Browse's and is left alone.
            guard let slash = id.firstIndex(of: "/") else { return false }
            return !keep.contains(id[..<slash].lowercased())
        }
        let items = try database.query("SELECT id FROM items") { $0[0].text }.compactMap(\.self).filter(outside)
        let reads = try database.query("SELECT id FROM reads") { $0[0].text }.compactMap(\.self).filter(outside)
        var removed = 0
        for (table, ids) in [("items", items), ("reads", reads)] {
            for start in stride(from: 0, to: ids.count, by: Self.pruneBatch) {
                let batch = ids[start ..< min(start + Self.pruneBatch, ids.count)]
                try database.transaction {
                    let delete = try database.prepare("DELETE FROM \(table) WHERE id = ?1")
                    for id in batch {
                        try delete.bind([.text(id)])
                        try delete.run()
                    }
                }
                if table == "items" { removed += batch.count }
                await Task.yield()
            }
        }
        return removed
    }

    private static func json(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder.heed.encode(value), as: UTF8.self)
    }
}
