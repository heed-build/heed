import Foundation

/// `goal_attach_decisions`: one row per look heed took for a thing's goal, the decision as JSON in `data`.
public extension GoalStore {
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

    /// Stores a decision; it comes back with its row id.
    func insert(_ decision: AttachDecision) throws -> AttachDecision {
        var decision = decision
        try database.run(
            "INSERT INTO goal_attach_decisions (kind, target, goal, at, data) VALUES (?, ?, ?, ?, ?)",
            [
                .text(decision.subject.kind.rawValue), .text(decision.subject.id), SQLiteValue(decision.goal),
                SQLiteValue(decision.at), .text(Self.json(decision)),
            ]
        )
        decision.id = database.lastInsertRowID
        return decision
    }

    func update(_ decision: AttachDecision) throws {
        try database.run(
            "UPDATE goal_attach_decisions SET goal = ?, data = ? WHERE id = ?",
            [SQLiteValue(decision.goal), .text(Self.json(decision)), SQLiteValue(decision.id)]
        )
    }

    /// Decisions newest first: since `since`, and at most `limit`.
    func decisions(since: Date? = nil, limit: Int = 500) throws -> [AttachDecision] {
        try database.query(
            "SELECT id, data FROM goal_attach_decisions WHERE at >= ? ORDER BY at DESC, id DESC LIMIT ?",
            [SQLiteValue((since ?? .distantPast).timeIntervalSince1970), SQLiteValue(limit)]
        ) { row in
            guard let text = row[1].text, var decision = try? Self.decoder.decode(
                AttachDecision.self, from: Data(text.utf8)
            ) else { return nil }
            decision.id = Int64(row[0].int ?? 0)
            return decision
        }.compactMap(\.self)
    }

    func decision(_ id: Int64) throws -> AttachDecision? {
        try database.query("SELECT id, data FROM goal_attach_decisions WHERE id = ?", [SQLiteValue(id)]) { row in
            guard let text = row[1].text,
                  var decision = try? Self.decoder.decode(AttachDecision.self, from: Data(text.utf8))
            else { return nil }
            decision.id = Int64(row[0].int ?? 0)
            return decision
        }.compactMap(\.self).first
    }

    /// The newest decision about one thing.
    func latestDecision(kind: GoalLink.Kind, target: String) throws -> AttachDecision? {
        let id = try database.scalar(
            "SELECT id FROM goal_attach_decisions WHERE kind = ? AND target = ? ORDER BY at DESC, id DESC LIMIT 1",
            [.text(kind.rawValue), .text(target)]
        )?.int
        return try id.flatMap { try decision(Int64($0)) }
    }

    private static func json(_ decision: AttachDecision) -> String {
        var stored = decision
        stored.id = 0
        return (try? encoder.encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
