import Foundation

/// `goals.sqlite`, beside `attention.sqlite`: the goals, their `GOAL.md` versions and what belongs to each. Its own
/// file, so its schema moves on its own. Goals are never deleted, only archived.
///
/// Owned by `GoalOps`, the actor every change goes through: one connection, touched only there, and an operation's
/// reads and writes run without another operation in between (no actor hop inside one).
///
/// Migration 1 also lays down the tables later parts of Goals fill (items, evidence, edits, reviews, evaluations,
/// attach decisions): a key, the goal, a time, the columns their queries need and a JSON body, so those parts add
/// readers and writers, and a migration only when they need a column. Issue refs for the GitHub mirror have their
/// columns already: `goals.tracker_repo`/`tracker_issue` (the meta issue) and `goal_items.issue_number` (sub-issues);
/// migration 2 adds `goal_mirrors`, the mirror's own state per goal; migration 3 swarm runs, their plan versions and
/// their steering log; migration 4 `goal_sources`, each goal's item sources.
public final class GoalStore {
    let database: SQLiteDatabase

    /// `~/Library/Application Support/Heed/goals.sqlite`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/goals.sqlite")
    }

    /// `":memory:"` keeps nothing (fixtures, shots).
    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE goals (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL,
            score REAL,
            tracker_repo TEXT,
            tracker_issue INTEGER
        );
        CREATE TABLE goal_versions (
            goal TEXT NOT NULL REFERENCES goals (id),
            number INTEGER NOT NULL,
            at REAL NOT NULL,
            text TEXT NOT NULL,
            note TEXT NOT NULL,
            author TEXT NOT NULL,
            PRIMARY KEY (goal, number)
        );
        CREATE TABLE goal_links (
            kind TEXT NOT NULL,
            target TEXT NOT NULL,
            goal TEXT NOT NULL REFERENCES goals (id),
            item TEXT,
            origin TEXT NOT NULL,
            confidence REAL,
            reason TEXT,
            at REAL NOT NULL,
            PRIMARY KEY (kind, target)
        );
        CREATE INDEX goal_links_goal ON goal_links (goal);
        CREATE TABLE goal_items (
            id TEXT PRIMARY KEY,
            goal TEXT NOT NULL REFERENCES goals (id),
            created_at REAL NOT NULL,
            issue_number INTEGER,
            data TEXT NOT NULL
        );
        CREATE TABLE goal_evidence (
            id INTEGER PRIMARY KEY,
            goal TEXT NOT NULL,
            item TEXT,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            data TEXT NOT NULL
        );
        CREATE TABLE goal_edits (
            id INTEGER PRIMARY KEY,
            goal TEXT NOT NULL,
            at REAL NOT NULL,
            state TEXT NOT NULL,
            data TEXT NOT NULL
        );
        CREATE TABLE goal_reviews (
            id INTEGER PRIMARY KEY,
            goal TEXT NOT NULL,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            data TEXT NOT NULL
        );
        CREATE TABLE goal_evaluations (
            id INTEGER PRIMARY KEY,
            goal TEXT NOT NULL,
            at REAL NOT NULL,
            lens TEXT NOT NULL,
            data TEXT NOT NULL
        );
        CREATE TABLE goal_attach_decisions (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            target TEXT NOT NULL,
            goal TEXT,
            at REAL NOT NULL,
            data TEXT NOT NULL
        );
        """),
        // The GitHub mirror's state per goal (`GoalMirrorState`): what heed last wrote, what it read back, its asks.
        SQLiteMigration(sql: """
        CREATE TABLE goal_mirrors (
            goal TEXT PRIMARY KEY REFERENCES goals (id),
            data TEXT NOT NULL
        );
        """),
        // Swarm runs on a goal (`GoalSwarm`), their plan versions (`SwarmPlanVersion`, the tasks as JSON in `items`)
        // and their steering log (`SwarmSteer`). Plan versions and steering rows are only ever added: an overrule, an
        // answer or a restore is a new row, and the triggers refuse anything else.
        SQLiteMigration(sql: """
        CREATE TABLE goal_swarms (
            id TEXT PRIMARY KEY,
            goal TEXT NOT NULL REFERENCES goals (id),
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            data TEXT NOT NULL
        );
        CREATE INDEX goal_swarms_goal ON goal_swarms (goal);
        CREATE TABLE goal_plans (
            swarm TEXT NOT NULL REFERENCES goal_swarms (id),
            goal TEXT NOT NULL,
            version INTEGER NOT NULL,
            at REAL NOT NULL,
            author TEXT NOT NULL,
            note TEXT NOT NULL,
            items TEXT NOT NULL,
            PRIMARY KEY (swarm, version)
        );
        CREATE TABLE goal_steering (
            id INTEGER PRIMARY KEY,
            swarm TEXT NOT NULL REFERENCES goal_swarms (id),
            goal TEXT NOT NULL,
            at REAL NOT NULL,
            actor TEXT NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            data TEXT NOT NULL
        );
        CREATE INDEX goal_steering_swarm ON goal_steering (swarm, id);
        CREATE TRIGGER goal_plans_kept BEFORE UPDATE ON goal_plans
        BEGIN SELECT RAISE(ABORT, 'plan versions are only added'); END;
        CREATE TRIGGER goal_plans_never_deleted BEFORE DELETE ON goal_plans
        BEGIN SELECT RAISE(ABORT, 'plan versions are only added'); END;
        CREATE TRIGGER goal_steering_kept BEFORE UPDATE ON goal_steering
        BEGIN SELECT RAISE(ABORT, 'steering rows are only added'); END;
        CREATE TRIGGER goal_steering_never_deleted BEFORE DELETE ON goal_steering
        BEGIN SELECT RAISE(ABORT, 'steering rows are only added'); END;
        """),
        // A goal's item sources (`GoalSourceState`): the GitHub queries its items come from, heed's proposal, the last
        // sync.
        SQLiteMigration(sql: """
        CREATE TABLE goal_sources (
            goal TEXT PRIMARY KEY REFERENCES goals (id),
            data TEXT NOT NULL
        );
        """),
    ]

    /// How many migrations the file has had (tests).
    var schemaVersion: Int { get throws { try database.userVersion } }

    // MARK: Goals

    public func goals() throws -> [HeedGoal] {
        try database.query("""
        SELECT id, title, status, created_at, updated_at, version, score, tracker_repo, tracker_issue
        FROM goals ORDER BY created_at, id
        """) { row in
            HeedGoal(
                id: row[0].text ?? "", title: row[1].text ?? "",
                status: HeedGoal.Status(rawValue: row[2].text ?? "") ?? .active,
                createdAt: row[3].date ?? .distantPast, updatedAt: row[4].date ?? .distantPast,
                version: row[5].int ?? 1, score: row[6].double,
                tracker: row[7].text.map { GoalTracker(repo: $0, metaIssue: row[8].int) }
            )
        }
    }

    public func goal(_ id: String) throws -> HeedGoal? { try goals().first { $0.id == id } }

    /// A new goal and its first version, together.
    public func insert(_ goal: HeedGoal, first version: GoalVersion) throws {
        try database.transaction {
            try write(goal, insert: true)
            try insert(version)
        }
    }

    /// The goal's row as it is now (title, status, score, tracker).
    public func update(_ goal: HeedGoal) throws {
        try write(goal, insert: false)
    }

    private func write(_ goal: HeedGoal, insert: Bool) throws {
        let values: [SQLiteValue] = [
            .text(goal.id), .text(goal.title), .text(goal.status.rawValue), SQLiteValue(goal.createdAt),
            SQLiteValue(goal.updatedAt), SQLiteValue(goal.version), SQLiteValue(goal.score),
            SQLiteValue(goal.tracker?.repo), SQLiteValue(goal.tracker?.metaIssue),
        ]
        if insert {
            try database.run("""
            INSERT INTO goals (id, title, status, created_at, updated_at, version, score, tracker_repo, tracker_issue)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values)
        } else {
            try database.run("""
            UPDATE goals SET title = ?2, status = ?3, created_at = ?4, updated_at = ?5, version = ?6, score = ?7,
            tracker_repo = ?8, tracker_issue = ?9 WHERE id = ?1
            """, values)
        }
    }

    // MARK: Versions

    /// Saves `text` as the goal's next version and makes it current; the version as saved.
    public func addVersion(
        goal id: String, text: String, note: String, author: GoalVersion.Author, title: String, at: Date
    ) throws -> GoalVersion {
        try database.transaction {
            let last = try database.scalar("SELECT MAX(number) FROM goal_versions WHERE goal = ?", [.text(id)])?.int
            let version = GoalVersion(goal: id, number: (last ?? 0) + 1, at: at, text: text, note: note, author: author)
            try insert(version)
            try database.run(
                "UPDATE goals SET version = ?, updated_at = ?, title = ? WHERE id = ?",
                [SQLiteValue(version.number), SQLiteValue(at), .text(title), .text(id)]
            )
            return version
        }
    }

    private func insert(_ version: GoalVersion) throws {
        try database.run(
            "INSERT INTO goal_versions (goal, number, at, text, note, author) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(version.goal), SQLiteValue(version.number), SQLiteValue(version.at), .text(version.text),
                .text(version.note), .text(version.author.rawValue),
            ]
        )
    }

    /// A goal's versions, newest first.
    public func versions(of goal: String) throws -> [GoalVersion] {
        try database.query(
            "SELECT goal, number, at, text, note, author FROM goal_versions WHERE goal = ? ORDER BY number DESC",
            [.text(goal)]
        ) { Self.version($0) }
    }

    public func version(of goal: String, number: Int) throws -> GoalVersion? {
        try database.query(
            "SELECT goal, number, at, text, note, author FROM goal_versions WHERE goal = ? AND number = ?",
            [.text(goal), SQLiteValue(number)]
        ) { Self.version($0) }.first
    }

    /// Each goal's current text, by goal id.
    public func currentTexts() throws -> [String: String] {
        let rows = try database.query("""
        SELECT v.goal, v.text FROM goal_versions v JOIN goals g ON g.id = v.goal AND g.version = v.number
        """) { ($0[0].text ?? "", $0[1].text ?? "") }
        return Dictionary(rows) { _, last in last }
    }

    private static func version(_ row: SQLiteRow) -> GoalVersion {
        GoalVersion(
            goal: row[0].text ?? "", number: row[1].int ?? 0, at: row[2].date ?? .distantPast,
            text: row[3].text ?? "", note: row[4].text ?? "",
            author: GoalVersion.Author(rawValue: row[5].text ?? "") ?? .you
        )
    }

    /// The goals, their links and current docs, their items, evidence and edits, in one hop.
    public func snapshot() throws -> GoalSnapshot {
        try GoalSnapshot(
            goals: goals(), links: links(), docs: currentTexts().mapValues { GoalDoc.parse($0) }, items: items(),
            evidence: evidence(), edits: edits(), swarms: swarms(), sources: sources()
        )
    }

    // MARK: Sources

    /// Each goal's item sources, by goal id; goals with none are left out.
    public func sources() throws -> [String: GoalSourceState] {
        let rows = try database.query("SELECT goal, data FROM goal_sources") { row in
            (row[0].text ?? "", Self.decode(GoalSourceState.self, row[1]))
        }
        return Dictionary(rows.compactMap { goal, state in state.map { (goal, $0) } }) { _, last in last }
    }

    public func save(sources state: GoalSourceState, goal: String) throws {
        try database.run(
            "INSERT OR REPLACE INTO goal_sources (goal, data) VALUES (?, ?)", [.text(goal), Self.json(state)]
        )
    }

    // MARK: Links

    public func links() throws -> [GoalLink] {
        try database.query(
            "SELECT goal, kind, target, origin, item, confidence, reason, at FROM goal_links ORDER BY at, kind, target"
        ) { row in
            GoalLink(
                goal: row[0].text ?? "", kind: GoalLink.Kind(rawValue: row[1].text ?? "") ?? .session,
                target: row[2].text ?? "", origin: GoalLink.Origin(rawValue: row[3].text ?? "") ?? .manual,
                item: row[4].text, confidence: row[5].double, reason: row[6].text, at: row[7].date ?? .distantPast
            )
        }
    }

    /// Links a thing to a goal; a thing already on another goal moves.
    public func link(_ link: GoalLink) throws {
        try database.run("""
        INSERT OR REPLACE INTO goal_links (kind, target, goal, item, origin, confidence, reason, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(link.kind.rawValue), .text(link.target), .text(link.goal), SQLiteValue(link.item),
            .text(link.origin.rawValue), SQLiteValue(link.confidence), SQLiteValue(link.reason), SQLiteValue(link.at),
        ])
    }

    /// The link that was removed, if there was one.
    @discardableResult
    public func unlink(kind: GoalLink.Kind, target: String) throws -> GoalLink? {
        let existing = try links().first { $0.kind == kind && $0.target == target }
        try database.run("DELETE FROM goal_links WHERE kind = ? AND target = ?", [.text(kind.rawValue), .text(target)])
        return existing
    }

    // MARK: Items

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func json(_ value: some Encodable) throws -> SQLiteValue {
        try .text(String(decoding: encoder.encode(value), as: UTF8.self))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: SQLiteValue) -> T? {
        value.text.flatMap { try? decoder.decode(type, from: Data($0.utf8)) }
    }

    /// Every goal's items, oldest first.
    public func items() throws -> [GoalItem] {
        try database.query("SELECT data, issue_number FROM goal_items ORDER BY created_at, id") { row in
            guard var item = Self.decode(GoalItem.self, row[0]) else { return nil }
            item.issueNumber = row[1].int ?? item.issueNumber
            return item
        }.compactMap(\.self)
    }

    public func item(_ id: String) throws -> GoalItem? {
        try database.query("SELECT data, issue_number FROM goal_items WHERE id = ?", [.text(id)]) { row in
            Self.decode(GoalItem.self, row[0]).map { item in
                var item = item
                item.issueNumber = row[1].int ?? item.issueNumber
                return item
            }
        }.first ?? nil
    }

    /// Adds or replaces an item.
    public func save(_ item: GoalItem) throws {
        try database.run("""
        INSERT OR REPLACE INTO goal_items (id, goal, created_at, issue_number, data) VALUES (?, ?, ?, ?, ?)
        """, [
            .text(item.id), .text(item.goal), SQLiteValue(item.createdAt), SQLiteValue(item.issueNumber),
            Self.json(item),
        ])
    }

    // MARK: Evidence

    /// Every goal's evidence, oldest first.
    public func evidence() throws -> [GoalEvidence] {
        try database.query("SELECT id, data FROM goal_evidence ORDER BY at, id") { row in
            Self.decode(GoalEvidence.self, row[1]).map { entry in
                var entry = entry
                entry.id = row[0].int64
                return entry
            }
        }.compactMap(\.self)
    }

    /// Stores the evidence; the row's id.
    public func add(_ evidence: GoalEvidence) throws -> Int64 {
        var entry = evidence
        entry.id = nil
        try database.run(
            "INSERT INTO goal_evidence (goal, item, at, kind, data) VALUES (?, ?, ?, ?, ?)",
            [
                .text(entry.goal), SQLiteValue(entry.item), SQLiteValue(entry.at), .text(entry.kind.rawValue),
                Self.json(entry),
            ]
        )
        return database.lastInsertRowID
    }

    // MARK: Edits

    /// Every goal's edits, oldest first.
    public func edits() throws -> [GoalEdit] {
        try database.query("SELECT id, data FROM goal_edits ORDER BY at, id") { row in
            Self.decode(GoalEdit.self, row[1]).map { edit in
                var edit = edit
                edit.id = row[0].int64
                return edit
            }
        }.compactMap(\.self)
    }

    public func edit(_ id: Int64) throws -> GoalEdit? {
        try edits().first { $0.id == id }
    }

    /// Stores a new edit (no id) or updates one; its id.
    @discardableResult
    public func save(_ edit: GoalEdit) throws -> Int64 {
        var stored = edit
        stored.id = nil
        if let id = edit.id {
            try database.run(
                "UPDATE goal_edits SET state = ?, data = ? WHERE id = ?",
                [.text(edit.state.rawValue), Self.json(stored), SQLiteValue(id)]
            )
            return id
        }
        try database.run(
            "INSERT INTO goal_edits (goal, at, state, data) VALUES (?, ?, ?, ?)",
            [.text(edit.goal), SQLiteValue(edit.at), .text(edit.state.rawValue), Self.json(stored)]
        )
        return database.lastInsertRowID
    }
}
