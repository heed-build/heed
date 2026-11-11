import Foundation

/// One Mindmap's nodes, in a file of its own (`mindmap/org-acme.sqlite`, `mindmap/personal.sqlite`): an org's work and
/// your personal work never share a file, so no query can mix them, and dropping one org's Mindmap is deleting a file.
public actor MindmapStore {
    public nonisolated let instance: String
    private let database: SQLiteDatabase

    /// `~/Library/Application Support/Heed/mindmap/`.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/mindmap", isDirectory: true)
    }

    public init(instance: String, path: String) throws {
        self.instance = instance
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    /// Opens `instance`'s store in `directory` off the main actor; nil (logged) when it cannot be opened.
    public static func open(_ instance: String, in directory: URL) async -> MindmapStore? {
        let file = directory.appendingPathComponent(MindmapInstance.fileName(instance))
        return await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try MindmapStore(instance: instance, path: file.path)
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); this Mindmap keeps nothing")
                return nil
            }
        }.value
    }

    /// The instances that have a file in `directory`.
    public static func instances(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".sqlite") else { return nil }
            if name == "personal.sqlite" { return MindmapInstance.personal }
            guard name.hasPrefix("org-") else { return nil }
            return String(name.dropFirst("org-".count).dropLast(".sqlite".count))
        }.sorted()
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE nodes (
            id TEXT PRIMARY KEY,
            parent TEXT,
            kind TEXT NOT NULL,
            entry TEXT,
            updated_at REAL NOT NULL,
            node TEXT NOT NULL
        );
        CREATE INDEX nodes_parent ON nodes (parent);
        CREATE UNIQUE INDEX nodes_entry ON nodes (entry) WHERE entry IS NOT NULL;
        """),
        SQLiteMigration(sql: """
        CREATE TABLE reports (
            id TEXT PRIMARY KEY,
            at REAL NOT NULL,
            report TEXT NOT NULL
        );
        CREATE INDEX reports_at ON reports (at);
        """),
    ]

    /// This Mindmap's standup reports, newest first.
    public func reports(limit: Int = 200) throws -> [StandupReport] {
        try database.query("SELECT report FROM reports ORDER BY at DESC LIMIT ?", [.integer(Int64(limit))]) { row in
            try JSONDecoder.heed.decode(StandupReport.self, from: row[0].data ?? Data())
        }
    }

    public func save(_ report: StandupReport) throws {
        let json = try String(decoding: JSONEncoder.heed.encode(report), as: UTF8.self)
        try database.run(
            "INSERT OR REPLACE INTO reports (id, at, report) VALUES (?, ?, ?)",
            [.text(report.id), SQLiteValue(report.at), .text(json)]
        )
    }

    public func nodes() throws -> [MindNode] {
        try database.query("SELECT node FROM nodes ORDER BY updated_at DESC, id") { row in
            try JSONDecoder.heed.decode(MindNode.self, from: row[0].data ?? Data())
        }
    }

    public func upsert(_ nodes: [MindNode]) throws {
        guard !nodes.isEmpty else { return }
        try database.transaction {
            let upsert = try database.prepare("""
            INSERT OR REPLACE INTO nodes (id, parent, kind, entry, updated_at, node) VALUES (?, ?, ?, ?, ?, ?)
            """)
            for node in nodes {
                let json = try String(decoding: JSONEncoder.heed.encode(node), as: UTF8.self)
                try upsert.bind([
                    .text(node.id), SQLiteValue(node.parent), .text(node.kind.rawValue), SQLiteValue(node.entry),
                    SQLiteValue(node.updatedAt), .text(json),
                ])
                try upsert.run()
            }
        }
    }

    public func delete(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            for id in ids {
                try database.run("DELETE FROM nodes WHERE id = ?", [.text(id)])
            }
        }
    }
}
