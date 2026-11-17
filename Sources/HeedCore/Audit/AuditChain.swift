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

/// Audit's rows are chained: each keeps the hash of the row before it, and its own hash is SHA-256 of that, its place,
/// its time and its content. A row that changed or went missing in the middle shows as a break; one gone from the start
/// or the end shows against the anchor (`AuditAnchor`), which keeps where the record starts and ends outside the table.
/// There is no key: Audit notices rows that changed or went missing, it cannot tell who did it.
public enum AuditChain {
    /// A row as stored.
    public struct Row: Hashable, Sendable {
        public var seq: Int64
        /// How its hash is made: 1 covers `prev`, `kind` and `body`; 2 also covers `seq` and `at`.
        public var version: Int
        /// When it happened (seconds since 1970), as the `at` column keeps it; pruning goes by it.
        public var at: Double
        public var kind: String
        public var body: String
        public var prev: String
        public var hash: String

        public init(
            seq: Int64, version: Int = AuditChain.version, at: Double, kind: String, body: String, prev: String,
            hash: String
        ) {
            self.seq = seq
            self.version = version
            self.at = at
            self.kind = kind
            self.body = body
            self.prev = prev
            self.hash = hash
        }

        /// Where the chain stands after this row.
        public var mark: AuditAnchor.Mark { AuditAnchor.Mark(seq: seq, hash: hash) }
    }

    /// Where the chain stops holding.
    public struct Break: Hashable, Sendable {
        /// The first row that does not hold, or the first one missing.
        public var seq: Int64
        public var reason: String

        public init(seq: Int64, reason: String) {
            self.seq = seq
            self.reason = reason
        }
    }

    /// The hash before the first row ever written.
    public static let genesis = String(repeating: "0", count: 64)

    /// The version new rows are written in.
    public static let version = 2

    /// Version 1: SHA-256 (hex) of the previous row's hash, the row's kind and its content. Rows written before
    /// version 2 keep verifying under it.
    public static func hash(prev: String, kind: String, body: String) -> String {
        hex(SHA256.hash(data: Data((prev + "\n" + kind + "\n" + body).utf8)))
    }

    /// Version 2: SHA-256 (hex) of `2`, the previous row's hash, the row's place, its time in whole milliseconds, its
    /// kind and its content, a line each.
    public static func hash(prev: String, seq: Int64, at: Double, kind: String, body: String) -> String {
        let text = ["2", prev, String(seq), String(milliseconds(at)), kind, body].joined(separator: "\n")
        return hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// The hash `row`'s content says it should have; nil for a version this build does not know.
    public static func expectedHash(_ row: Row) -> String? {
        switch row.version {
        case 1: hash(prev: row.prev, kind: row.kind, body: row.body)
        case 2: hash(prev: row.prev, seq: row.seq, at: row.at, kind: row.kind, body: row.body)
        default: nil
        }
    }

    static func milliseconds(_ at: Double) -> Int64 { Int64((at * 1000).rounded()) }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The rows `records` become, written after `last` (the genesis at seq 0 for an empty record).
    public static func link(
        _ records: [(kind: String, body: String, at: Double)],
        after last: AuditAnchor.Mark
    ) -> [Row] {
        var previous = last
        return records.map { record in
            let seq = previous.seq + 1
            let hash = hash(prev: previous.hash, seq: seq, at: record.at, kind: record.kind, body: record.body)
            defer { previous = AuditAnchor.Mark(seq: seq, hash: hash) }
            return Row(seq: seq, at: record.at, kind: record.kind, body: record.body, prev: previous.hash, hash: hash)
        }
    }

    /// The first place, oldest first, where the record does not hold: its start is not the genesis or where pruning
    /// stopped, a row's hash is not what its content says, a row does not follow the one before it, or the rows do not
    /// reach where the anchor says the record ends. With no anchor, only the rows between the first and the last.
    public static func verify(_ rows: [Row], anchor: AuditAnchor? = nil) -> Break? {
        if let anchor, let broken = startBreak(rows, anchor) { return broken }
        if let broken = rowBreak(rows) { return broken }
        guard let anchor else { return nil }
        if let broken = endBreak(rows, anchor) { return broken }
        if let rebuilt = anchor.rebuilt {
            return Break(
                seq: rebuilt.seq,
                reason: "the note of where the record ends went missing and was made again here"
            )
        }
        return nil
    }

    /// The first row that does not hold on its own or against the row before it.
    static func rowBreak(_ rows: [Row]) -> Break? {
        var previous: Row?
        for row in rows {
            if let previous {
                if row.prev != previous.hash || (row.version >= 2 && row.seq != previous.seq + 1) {
                    return Break(seq: row.seq, reason: "it does not follow the row before it")
                }
            }
            guard let expected = expectedHash(row) else {
                return Break(seq: row.seq, reason: "it was written by a newer heed")
            }
            if expected != row.hash {
                return Break(seq: row.seq, reason: "its content changed after it was written")
            }
            // Version 1 does not hash `at`: it must still be the time its content says.
            if row.version == 1, let at = AuditRecord.decode(kind: row.kind, body: row.body)?.at,
               abs(at.timeIntervalSince1970 - row.at) > 0.001
            {
                return Break(seq: row.seq, reason: "its time changed after it was written")
            }
            previous = row
        }
        return nil
    }

    private static func startBreak(_ rows: [Row], _ anchor: AuditAnchor) -> Break? {
        guard let first = rows.first else { return nil }
        let start = anchor.pruned ?? AuditAnchor.Mark(seq: 0, hash: genesis)
        if first.seq <= start.seq {
            // Pruning noted where it stops but has not removed the rows yet: the row it stops at is still there.
            if anchor.pruned != nil, rows.contains(where: { $0.mark == start }) { return nil }
            return Break(seq: first.seq, reason: "the rows before it are missing")
        }
        guard first.prev == start.hash, first.version == 1 || first.seq == start.seq + 1 else {
            return Break(seq: first.seq, reason: "the rows before it are missing")
        }
        return nil
    }

    private static func endBreak(_ rows: [Row], _ anchor: AuditAnchor) -> Break? {
        guard let last = anchor.last, last != anchor.pruned else { return nil }
        // Rows after the anchor are fine: the anchor is written just after the rows, so it can lag behind them.
        guard let row = rows.first(where: { $0.seq == last.seq }) else {
            let from = (rows.last?.seq ?? anchor.pruned?.seq ?? 0) + 1
            return Break(
                seq: from,
                reason: from == last.seq ? "it is missing from the end" : "rows \(from) to \(last.seq) are missing from the end"
            )
        }
        if row.hash != last.hash {
            return Break(seq: row.seq, reason: "it is not the row the record ended with")
        }
        return nil
    }

    /// How long rows are kept.
    public static let retention: TimeInterval = 365 * 86400

    /// The oldest rows pruning may remove at `now`: from the start, each older than a year and holding (so a row whose
    /// time was changed is not pruned with the rest), stopping at the first that is not.
    public static func prunable(_ rows: [Row], now: Date) -> Row? {
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        let limit = rowBreak(rows)?.seq ?? .max
        return rows.prefix { $0.at < cutoff && $0.seq < limit }.last
    }

    /// The export: one JSON object per line, oldest first, with the row's place in the chain (`seq`, `v`, `prev`,
    /// `hash`), its time (`at`) and its content (`body`) exactly as stored and hashed.
    public static func exportLines(_ rows: [Row]) -> String {
        rows.map { row in
            let line: [String: Any] = [
                "seq": row.seq, "v": row.version, "at": row.at, "kind": row.kind, "body": row.body, "prev": row.prev,
                "hash": row.hash,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    /// An export back as rows, to verify it; nil when a line is not one.
    public static func rows(fromExport text: String) -> [Row]? {
        var rows: [Row] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let seq = (object["seq"] as? NSNumber)?.int64Value,
                  let version = (object["v"] as? NSNumber)?.intValue,
                  let at = (object["at"] as? NSNumber)?.doubleValue, let kind = object["kind"] as? String,
                  let body = object["body"] as? String, let prev = object["prev"] as? String,
                  let hash = object["hash"] as? String
            else { return nil }
            rows.append(Row(seq: seq, version: version, at: at, kind: kind, body: body, prev: prev, hash: hash))
        }
        return rows
    }
}

/// Where Audit's record starts and ends, kept outside its table (`heed.audit.json` beside `heed.sqlite`), so rows
/// missing from either end show: the first row must follow the genesis or `pruned`, and the rows must reach `last`.
/// A copy of `heed.sqlite` put back from before, or rows removed from it, no longer matches the anchor.
public struct AuditAnchor: Codable, Hashable, Sendable {
    /// A row's place and hash.
    public struct Mark: Codable, Hashable, Sendable {
        public var seq: Int64
        public var hash: String

        public init(seq: Int64, hash: String) {
            self.seq = seq
            self.hash = hash
        }
    }

    /// The last row written.
    public var last: Mark?
    /// The last row pruning removed: the first row left follows it.
    public var pruned: Mark?
    /// The anchor went missing while the record had rows written with it, and was made again from them at this row.
    public var rebuilt: Mark?

    public init(last: Mark? = nil, pruned: Mark? = nil, rebuilt: Mark? = nil) {
        self.last = last
        self.pruned = pruned
        self.rebuilt = rebuilt
    }

    /// The anchor for a record written before there was one: taken from its rows as they are.
    public static func adopting(_ rows: [AuditChain.Row]) -> AuditAnchor {
        let start = rows.first.flatMap { first in
            first.prev == AuditChain.genesis ? nil : Mark(seq: first.seq - 1, hash: first.prev)
        }
        return AuditAnchor(last: rows.last?.mark ?? start, pruned: start)
    }

    /// Where the next row follows: the last row in the table, or where the anchor says the record ended when the table
    /// stops short of it (so rows missing from the end stay visible after the next one is written).
    public func next(after tableLast: Mark?) -> Mark {
        let known = last ?? pruned ?? Mark(seq: 0, hash: AuditChain.genesis)
        guard let tableLast, tableLast.seq >= known.seq else { return known }
        return tableLast
    }
}
