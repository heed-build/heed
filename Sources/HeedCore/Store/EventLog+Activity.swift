import Foundation

/// Agents' activity in the event log: tool calls and file changes (`EventKind.activity`). There are many more of
/// them than of anything else, so they are kept apart from the rest of the log's rules: read by what they are about
/// (a swarm task, `task:<id>`), dropped after `keepDays`, and capped at `maxBytes` of text, the oldest going first.
/// The measured volume is in `docs/goals/swarms/watching.md`.
public extension EventLog {
    /// Days activity is kept.
    static let activityKeepDays = 14
    /// Text and payload kept, at most: about 43,000 rows at the measured 97 bytes a row, some 110 busy worker-hours
    /// (about 15 MB of database).
    static let activityMaxBytes = 4 * 1024 * 1024

    /// The activity about `subjects`, newest first, at most `limit` rows each.
    func activity(about subjects: [String], since: Date = .distantPast, limit: Int = 200) throws
        -> [String: [LoggedEvent]]
    {
        var result: [String: [LoggedEvent]] = [:]
        for subject in subjects {
            let rows = try database.query(
                """
                SELECT at, kind, session, repo, host, worktree, subject, text, guessed, payload FROM events
                WHERE subject = ? AND kind IN ('tool.call', 'file.change') AND at >= ? ORDER BY at DESC, id DESC LIMIT ?
                """,
                [.text(subject), SQLiteValue(since), .integer(Int64(limit))]
            ) { row in
                let payload = row[9].data.flatMap { try? JSONDecoder.heed.decode([String: String].self, from: $0) }
                return LoggedEvent(
                    at: row[0].date ?? .distantPast, kind: EventKind(rawValue: row[1].text ?? ""),
                    session: row[2].text, repo: row[3].text, host: row[4].text, worktree: row[5].text,
                    subject: row[6].text, text: row[7].text ?? "", guessed: row[8].bool ?? false,
                    payload: payload ?? [:]
                )
            }
            if !rows.isEmpty { result[subject] = rows }
        }
        return result
    }

    /// Drops activity older than `keepDays`, then the oldest past `maxBytes` of text and payload. Returns how many
    /// rows went.
    @discardableResult
    func pruneActivity(
        now: Date, keepDays: Int = EventLog.activityKeepDays, maxBytes: Int = EventLog.activityMaxBytes
    ) -> Int {
        do {
            return try database.transaction {
                try database.run(
                    "DELETE FROM events WHERE kind IN ('tool.call', 'file.change') AND at < ?",
                    [SQLiteValue(now.addingTimeInterval(-Double(keepDays) * 86400))]
                )
                var removed = database.changes
                try database.run(
                    """
                    DELETE FROM events WHERE id IN (
                        SELECT id FROM (
                            SELECT id, SUM(LENGTH(text) + COALESCE(LENGTH(payload), 0))
                                OVER (ORDER BY at DESC, id DESC) AS kept
                            FROM events WHERE kind IN ('tool.call', 'file.change')
                        ) WHERE kept > ?
                    )
                    """,
                    [.integer(Int64(maxBytes))]
                )
                removed += database.changes
                return removed
            }
        } catch {
            NSLog("heed: could not prune activity: \(error)")
            return 0
        }
    }

    /// Activity rows and the bytes of text and payload they hold.
    func activitySize() throws -> (rows: Int, bytes: Int) {
        let rows = try database.query(
            """
            SELECT COUNT(*), COALESCE(SUM(LENGTH(text) + COALESCE(LENGTH(payload), 0)), 0) FROM events
            WHERE kind IN ('tool.call', 'file.change')
            """,
            []
        ) { row in (row[0].int ?? 0, row[1].int ?? 0) }
        return rows.first ?? (0, 0)
    }
}
