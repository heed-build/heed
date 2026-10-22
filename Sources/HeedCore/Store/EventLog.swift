import Foundation

/// What kind of thing happened. A string underneath, so a file written by a newer build (with kinds this one does not
/// know) still reads.
public struct EventKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let sessionStarted = EventKind(rawValue: "session.started")
    /// A closed session came back from history (`R` reopen).
    public static let sessionReopened = EventKind(rawValue: "session.reopened")
    public static let sessionClosed = EventKind(rawValue: "session.closed")
    public static let sessionParked = EventKind(rawValue: "session.parked")
    public static let sessionUnparked = EventKind(rawValue: "session.unparked")
    /// The agent's state changed: reported by its hooks, or guessed from its screen (`guessed`).
    public static let state = EventKind(rawValue: "state")
    /// The agent went to asking (questions for you), and left it.
    public static let questionAsked = EventKind(rawValue: "question.asked")
    public static let questionAnswered = EventKind(rawValue: "question.answered")
    public static let worktreeCreated = EventKind(rawValue: "worktree.created")
    public static let worktreeRemoved = EventKind(rawValue: "worktree.removed")
    /// A session started tracking a PR (opened by its agent, found on its branch, or added by hand: the note says).
    public static let pullTracked = EventKind(rawValue: "pr.tracked")
    public static let pullMerged = EventKind(rawValue: "pr.merged")
    /// What became of something needing you, as a notification: posted, or not and why (`Notices.Decision`).
    public static let notification = EventKind(rawValue: "notification")
    /// A line of a session's timeline (`Session.record`).
    public static let note = EventKind(rawValue: "note")
}

/// One row of the event log: append-only, queried by time and session.
public struct LoggedEvent: Hashable, Sendable {
    public var at: Date
    public var kind: EventKind
    public var session: String?
    /// `org/name`.
    public var repo: String?
    /// The host a session runs on; nil for this Mac.
    public var host: String?
    public var worktree: String?
    /// What it is about, besides the session: a PR (`org/name#12`), a worktree path.
    public var subject: String?
    /// A few words, for reading.
    public var text: String
    /// A state read from the screen rather than reported.
    public var guessed: Bool
    /// Anything else, as JSON object fields.
    public var payload: [String: String]

    public init(
        at: Date, kind: EventKind, session: String? = nil, repo: String? = nil, host: String? = nil,
        worktree: String? = nil, subject: String? = nil, text: String = "", guessed: Bool = false,
        payload: [String: String] = [:]
    ) {
        self.at = at
        self.kind = kind
        self.session = session
        self.repo = repo
        self.host = host
        self.worktree = worktree
        self.subject = subject
        self.text = text
        self.guessed = guessed
        self.payload = payload
    }

    /// An event about a session, with its repo, host and worktree filled in.
    public init(
        at: Date, kind: EventKind, about session: Session, subject: String? = nil, text: String = "",
        guessed: Bool = false, payload: [String: String] = [:]
    ) {
        self.init(
            at: at, kind: kind, session: session.id, repo: session.repos.first?.slug, host: session.host,
            worktree: session.worktreePaths.first, subject: subject, text: text, guessed: guessed, payload: payload
        )
    }
}

/// A write to `heed.sqlite`, in the order the domain changed.
public enum EventLogWrite: Hashable, Sendable {
    case events([LoggedEvent])
    /// A session closed (or its outcome was refined): its history entry, replacing one with the same id.
    case closed(HistoryEntry)
    /// A history entry came back as a session.
    case reopened(String)
}

/// `heed.sqlite`: the append-only record of what happened (events) and closed sessions (history). It lives beside
/// `domain.json` but does not depend on its format version, so a domain that does not read no longer hides history.
///
/// The domain keeps `history` and each session's `timeline` in memory, for the views; this is where they are kept on
/// disk. `adopt` fills them in at launch, and `DomainStore` writes here as the domain changes.
public actor EventLog {
    private let database: SQLiteDatabase

    /// `~/Library/Application Support/Heed/heed.sqlite`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/heed.sqlite")
    }

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    /// Opens the log off the main actor; nil (logged) when it cannot be opened, and the app keeps history in the
    /// domain file as before.
    public static func open(at file: URL) async -> EventLog? {
        await Task.detached(priority: .userInitiated) {
            do {
                return try EventLog(path: file.path)
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); history stays in domain.json")
                return nil
            }
        }.value
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            session TEXT,
            repo TEXT,
            host TEXT,
            worktree TEXT,
            subject TEXT,
            text TEXT NOT NULL DEFAULT '',
            guessed INTEGER NOT NULL DEFAULT 0,
            payload TEXT
        );
        CREATE INDEX events_at ON events (at);
        CREATE INDEX events_session ON events (session, at);
        -- A timeline line is recorded once: the same line comes again with a reopened session and from an old cache.
        CREATE UNIQUE INDEX events_note ON events (session, at, text) WHERE kind = 'note';
        -- A PR merges once, whether a sync or its detail saw it first.
        CREATE UNIQUE INDEX events_merged ON events (subject) WHERE kind = 'pr.merged';
        CREATE TABLE history (
            id TEXT PRIMARY KEY,
            closed_at REAL NOT NULL,
            outcome TEXT NOT NULL,
            repo TEXT,
            entry TEXT NOT NULL
        );
        CREATE INDEX history_closed ON history (closed_at);
        """),
    ]

    // MARK: Writing

    public func write(_ writes: [EventLogWrite]) {
        guard !writes.isEmpty else { return }
        do {
            try database.transaction {
                let insert = try insertEvent()
                for write in writes {
                    switch write {
                    case let .events(events):
                        for event in events {
                            try insert.bind(Self.values(event))
                            try insert.run()
                        }
                    case let .closed(entry):
                        try store(entry, replacing: true)
                    case let .reopened(id):
                        try database.run("DELETE FROM history WHERE id = ?", [.text(id)])
                    }
                }
            }
        } catch {
            NSLog("heed: could not write the event log: \(error)")
        }
    }

    public func append(_ events: [LoggedEvent]) { write([.events(events)]) }

    /// Events are only added; one already there (a timeline line, a merge) is left as it is.
    private func insertEvent() throws -> SQLiteStatement {
        try database.prepare("""
        INSERT OR IGNORE INTO events (at, kind, session, repo, host, worktree, subject, text, guessed, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
    }

    private static func values(_ event: LoggedEvent) -> [SQLiteValue] {
        let payload = event.payload.isEmpty ? nil
            : (try? JSONEncoder.heed.encode(event.payload)).map { String(decoding: $0, as: UTF8.self) }
        return [
            SQLiteValue(event.at), .text(event.kind.rawValue), SQLiteValue(event.session), SQLiteValue(event.repo),
            SQLiteValue(event.host), SQLiteValue(event.worktree), SQLiteValue(event.subject), .text(event.text),
            SQLiteValue(event.guessed), SQLiteValue(payload),
        ]
    }

    private func store(_ entry: HistoryEntry, replacing: Bool) throws {
        let json = try String(decoding: JSONEncoder.heed.encode(entry), as: UTF8.self)
        try database.run(
            "INSERT OR \(replacing ? "REPLACE" : "IGNORE") INTO history (id, closed_at, outcome, repo, entry) "
                + "VALUES (?, ?, ?, ?, ?)",
            [
                .text(entry.id), SQLiteValue(entry.closedAt), .text(entry.outcome.rawValue),
                SQLiteValue(entry.session.repos.first?.slug), .text(json),
            ]
        )
    }

    // MARK: The domain

    /// At launch: takes in what the cached domain still holds (history and timelines from before this store, or
    /// written by an older build since), then returns the domain with its history and timelines as kept here. Taking
    /// in is idempotent: an entry already here wins (it may have been refined since), a timeline line already here
    /// is not added again.
    public func adopt(_ domain: Domain) -> Domain {
        do {
            try database.transaction {
                for entry in domain.history {
                    try store(entry, replacing: false)
                }
                let sessions = domain.sessions + domain.history.map(\.session)
                let notes = sessions.flatMap { session in
                    session.timeline.map { LoggedEvent(at: $0.at, kind: .note, about: session, text: $0.text) }
                }
                let insert = try insertEvent()
                for note in notes {
                    try insert.bind(Self.values(note))
                    try insert.run()
                }
            }
            var adopted = domain
            adopted.history = try history()
            let timelines = try timelines(of: domain.sessions.map(\.id))
            for index in adopted.sessions.indices {
                adopted.sessions[index].timeline = timelines[adopted.sessions[index].id] ?? []
            }
            return adopted
        } catch {
            NSLog("heed: could not read the event log: \(error)")
            return domain
        }
    }

    // MARK: Reading

    /// Closed sessions, newest first; since a time when given.
    public func history(since: Date? = nil) throws -> [HistoryEntry] {
        try database.query(
            "SELECT entry FROM history WHERE closed_at >= ? ORDER BY closed_at DESC",
            [SQLiteValue(since ?? .distantPast)]
        ) { row in
            try JSONDecoder.heed.decode(HistoryEntry.self, from: row[0].data ?? Data())
        }
    }

    /// The last `Session.timelineLimit` timeline lines of each session, oldest first.
    public func timelines(of sessions: [String]) throws -> [String: [TimelineEvent]] {
        let statement = try database.prepare("""
        SELECT at, text FROM (
            SELECT at, text FROM events WHERE kind = 'note' AND session = ? ORDER BY at DESC, id DESC LIMIT ?
        ) ORDER BY at
        """)
        var result: [String: [TimelineEvent]] = [:]
        for session in sessions {
            try statement.bind([.text(session), .integer(Int64(Session.timelineLimit))])
            var lines: [TimelineEvent] = []
            while let row = try statement.step() {
                lines.append(TimelineEvent(at: row[0].date ?? .distantPast, text: row[1].text ?? ""))
            }
            if !lines.isEmpty { result[session] = lines }
        }
        return result
    }

    /// Events in a time range (newest first), of one session or kinds when given.
    public func events(
        from: Date = .distantPast, to: Date = .distantFuture, session: String? = nil, kinds: [EventKind] = [],
        limit: Int = 1000
    ) throws -> [LoggedEvent] {
        var sql = "SELECT at, kind, session, repo, host, worktree, subject, text, guessed, payload FROM events "
            + "WHERE at >= ? AND at <= ?"
        var values: [SQLiteValue] = [SQLiteValue(from), SQLiteValue(to)]
        if let session {
            sql += " AND session = ?"
            values.append(.text(session))
        }
        if !kinds.isEmpty {
            sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))"
            values += kinds.map { .text($0.rawValue) }
        }
        sql += " ORDER BY at DESC, id DESC LIMIT ?"
        values.append(.integer(Int64(limit)))
        return try database.query(sql, values) { row in
            let payload = row[9].data.flatMap { try? JSONDecoder.heed.decode([String: String].self, from: $0) }
            return LoggedEvent(
                at: row[0].date ?? .distantPast, kind: EventKind(rawValue: row[1].text ?? ""), session: row[2].text,
                repo: row[3].text, host: row[4].text, worktree: row[5].text, subject: row[6].text,
                text: row[7].text ?? "", guessed: row[8].bool ?? false, payload: payload ?? [:]
            )
        }
    }
}
