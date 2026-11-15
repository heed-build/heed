import CryptoKit
import Foundation

/// One row of Audit's record: a cause, an action, a grant, or a grant taken back.
public enum AuditRecord: Hashable, Sendable {
    case cause(Cause)
    case action(AuditAction)
    case grant(AuditGrant)
    case revoke(AuditRevocation)

    public var kind: String {
        switch self {
        case .cause: "cause"
        case .action: "action"
        case .grant: "grant"
        case .revoke: "revoke"
        }
    }

    public var at: Date {
        switch self {
        case let .cause(cause): cause.at
        case let .action(action): action.at
        case let .grant(grant): grant.at
        case let .revoke(revocation): revocation.at
        }
    }

    /// The row's content, as stored and hashed.
    public func body() throws -> String {
        let data = switch self {
        case let .cause(cause): try JSONEncoder.heed.encode(cause)
        case let .action(action): try JSONEncoder.heed.encode(action)
        case let .grant(grant): try JSONEncoder.heed.encode(grant)
        case let .revoke(revocation): try JSONEncoder.heed.encode(revocation)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A stored row back; nil for a kind this build does not know, or a body it cannot read.
    public static func decode(kind: String, body: String) -> AuditRecord? {
        let data = Data(body.utf8)
        let decoder = JSONDecoder.heed
        switch kind {
        case "cause": return (try? decoder.decode(Cause.self, from: data)).map(AuditRecord.cause)
        case "action": return (try? decoder.decode(AuditAction.self, from: data)).map(AuditRecord.action)
        case "grant": return (try? decoder.decode(AuditGrant.self, from: data)).map(AuditRecord.grant)
        case "revoke": return (try? decoder.decode(AuditRevocation.self, from: data)).map(AuditRecord.revoke)
        default: return nil
        }
    }
}

/// Audit's rows are chained: each keeps the hash of the row before it, and its own hash is SHA-256 of that and its
/// content. Changing, removing or inserting a row anywhere but at the start shows as a break. Pruning removes the
/// oldest rows, so the first row left is taken as it is.
public enum AuditChain {
    /// A row as stored.
    public struct Row: Hashable, Sendable {
        public var seq: Int64
        public var kind: String
        public var body: String
        public var prev: String
        public var hash: String

        public init(seq: Int64, kind: String, body: String, prev: String, hash: String) {
            self.seq = seq
            self.kind = kind
            self.body = body
            self.prev = prev
            self.hash = hash
        }
    }

    /// Where the chain stops holding.
    public struct Break: Hashable, Sendable {
        /// The first row that does not hold.
        public var seq: Int64
        public var reason: String
    }

    /// The hash before the first row ever written.
    public static let genesis = String(repeating: "0", count: 64)

    /// SHA-256 (hex) of the previous row's hash, the row's kind and its content.
    public static func hash(prev: String, kind: String, body: String) -> String {
        let digest = SHA256.hash(data: Data((prev + "\n" + kind + "\n" + body).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The rows `records` become, written after a row whose hash is `last`.
    public static func link(_ records: [(kind: String, body: String)], after last: String) -> [(
        kind: String, body: String, prev: String, hash: String
    )] {
        var prev = last
        return records.map { record in
            let hash = hash(prev: prev, kind: record.kind, body: record.body)
            defer { prev = hash }
            return (record.kind, record.body, prev, hash)
        }
    }

    /// The first row, oldest first, whose hash is not what its content says, or whose `prev` is not the hash of the
    /// row before it. Nil when the chain holds.
    public static func verify(_ rows: [Row]) -> Break? {
        var previous: Row?
        for row in rows {
            if let previous, row.prev != previous.hash {
                return Break(seq: row.seq, reason: "it does not follow the row before it")
            }
            if hash(prev: row.prev, kind: row.kind, body: row.body) != row.hash {
                return Break(seq: row.seq, reason: "its content changed after it was written")
            }
            previous = row
        }
        return nil
    }

    /// How long rows are kept.
    public static let retention: TimeInterval = 365 * 86400

    /// The export: one JSON object per line, oldest first, with the row's place in the chain.
    public static func exportLines(_ rows: [Row]) -> String {
        rows.map { row in
            let record = (try? JSONSerialization.jsonObject(with: Data(row.body.utf8))) ?? row.body
            let line: [String: Any] = [
                "seq": row.seq, "kind": row.kind, "record": record, "prev": row.prev, "hash": row.hash,
            ]
            let data = (try? JSONSerialization.data(
                withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]
            )) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}

/// Audit's table in `heed.sqlite`.
public extension EventLog {
    /// Appends `records`, each chained to the one before.
    func appendAudit(_ records: [AuditRecord]) {
        guard !records.isEmpty else { return }
        do {
            let bodies = try records.map { try (kind: $0.kind, body: $0.body(), at: $0.at) }
            try database.transaction {
                let last = try database.scalar("SELECT hash FROM audit ORDER BY id DESC LIMIT 1")?.text
                let linked = AuditChain.link(bodies.map { ($0.kind, $0.body) }, after: last ?? AuditChain.genesis)
                let insert = try database.prepare(
                    "INSERT INTO audit (at, kind, body, prev, hash) VALUES (?, ?, ?, ?, ?)"
                )
                for (row, source) in zip(linked, bodies) {
                    try insert.bind([
                        SQLiteValue(source.at), .text(row.kind), .text(row.body), .text(row.prev), .text(row.hash),
                    ])
                    try insert.run()
                }
            }
        } catch {
            NSLog("heed: could not write to Audit: \(error)")
        }
    }

    /// Every row, oldest first.
    func auditRows() throws -> [AuditChain.Row] {
        try database.query("SELECT id, kind, body, prev, hash FROM audit ORDER BY id", []) { row in
            AuditChain.Row(
                seq: row[0].int64 ?? 0, kind: row[1].text ?? "", body: row[2].text ?? "", prev: row[3].text ?? "",
                hash: row[4].text ?? ""
            )
        }
    }

    /// What Audit keeps, and where its chain breaks, if it does.
    func audit() throws -> (records: [AuditRecord], broken: AuditChain.Break?) {
        let rows = try auditRows()
        return (rows.compactMap { AuditRecord.decode(kind: $0.kind, body: $0.body) }, AuditChain.verify(rows))
    }

    /// Drops rows older than a year. Returns how many went.
    @discardableResult
    func pruneAudit(now: Date) -> Int {
        do {
            // Always a prefix of the chain, so what is left still holds from its first row.
            try database.run(
                "DELETE FROM audit WHERE id <= (SELECT max(id) FROM audit WHERE at < ?)",
                [SQLiteValue(now.addingTimeInterval(-AuditChain.retention))]
            )
            return database.changes
        } catch {
            NSLog("heed: could not prune Audit: \(error)")
            return 0
        }
    }
}
