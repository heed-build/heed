import Foundation

/// Audit's table in `heed.sqlite`, and its anchor beside it (`AuditAnchor`).
///
/// The anchor is a small file of its own rather than a table in the same database or a field of `domain.json`: a copy
/// of `heed.sqlite` put back from before, or rows removed from it with any SQLite tool, leave the file as it was and no
/// longer match it; and `domain.json` is written by the app on its own schedule and is set aside when its format does
/// not read, which would lose the anchor with it. The file is written just after the rows it describes, so it can only
/// lag behind them, which `AuditChain.verify` allows.
public extension EventLog {
    /// Appends `records`, each chained to the one before, then moves the anchor to the last of them. Throws when they
    /// could not be written; then none are.
    func appendAudit(_ records: [AuditRecord]) throws {
        guard !records.isEmpty else { return }
        let bodies = try records.map { try (kind: $0.kind, body: $0.body(), at: $0.at.timeIntervalSince1970) }
        var anchor = try loadAuditAnchor()
        let rows = try database.transaction {
            let last = try database.query("SELECT id, hash FROM audit ORDER BY id DESC LIMIT 1") { row in
                AuditAnchor.Mark(seq: row[0].int64 ?? 0, hash: row[1].text ?? "")
            }.first
            let rows = AuditChain.link(bodies, after: anchor.next(after: last))
            let insert = try database.prepare(
                "INSERT INTO audit (id, v, at, kind, body, prev, hash) VALUES (?, ?, ?, ?, ?, ?, ?)"
            )
            for row in rows {
                try insert.bind([
                    .integer(row.seq), .integer(Int64(row.version)), .real(row.at), .text(row.kind), .text(row.body),
                    .text(row.prev), .text(row.hash),
                ])
                try insert.run()
            }
            return rows
        }
        anchor.last = rows.last?.mark
        do {
            try saveAuditAnchor(anchor)
        } catch {
            // The rows are written; the anchor lags behind them until the next write, which verify allows.
            NSLog("heed: could not write \(auditAnchorFile.path): \(error)")
        }
    }

    /// Every row, oldest first.
    func auditRows() throws -> [AuditChain.Row] {
        try database.query("SELECT id, v, at, kind, body, prev, hash FROM audit ORDER BY id", []) { row in
            AuditChain.Row(
                seq: row[0].int64 ?? 0, version: row[1].int ?? 1, at: row[2].double ?? 0, kind: row[3].text ?? "",
                body: row[4].text ?? "", prev: row[5].text ?? "", hash: row[6].text ?? ""
            )
        }
    }

    /// What Audit keeps, and where it stops holding, if it does.
    func audit() throws -> (records: [AuditRecord], broken: AuditChain.Break?) {
        let rows = try auditRows()
        let anchor = try loadAuditAnchor(rows: rows)
        return (
            rows.compactMap { AuditRecord.decode(kind: $0.kind, body: $0.body) },
            AuditChain.verify(rows, anchor: anchor)
        )
    }

    /// The anchor as kept.
    func currentAuditAnchor() throws -> AuditAnchor { try loadAuditAnchor() }

    /// Drops the rows older than a year, from the start, up to the first that does not hold. The anchor notes where
    /// pruning stopped before the rows go, so the first row left still has something to follow. Returns how many went.
    @discardableResult
    func pruneAudit(now: Date) -> Int {
        do {
            let rows = try auditRows()
            var anchor = try loadAuditAnchor(rows: rows)
            guard let through = AuditChain.prunable(rows, now: now) else { return 0 }
            anchor.pruned = through.mark
            if (anchor.last?.seq ?? 0) < through.seq { anchor.last = through.mark }
            if let rebuilt = anchor.rebuilt, rebuilt.seq <= through.seq { anchor.rebuilt = nil }
            try saveAuditAnchor(anchor)
            try database.run("DELETE FROM audit WHERE id <= ?", [.integer(through.seq)])
            return database.changes
        } catch {
            NSLog("heed: could not prune Audit: \(error)")
            return 0
        }
    }

    /// The anchor: as kept in its file, or, when there is none, made from the rows. A record whose rows all predate the
    /// anchor adopts its rows as they are; one with rows written alongside an anchor that is now gone says so
    /// (`AuditAnchor.rebuilt`).
    private func loadAuditAnchor(rows known: [AuditChain.Row]? = nil) throws -> AuditAnchor {
        if let auditAnchor { return auditAnchor }
        if FileManager.default.fileExists(atPath: auditAnchorFile.path) {
            let anchor = try JSONDecoder.heed.decode(AuditAnchor.self, from: Data(contentsOf: auditAnchorFile))
            auditAnchor = anchor
            return anchor
        }
        let rows = try known ?? auditRows()
        var anchor = AuditAnchor.adopting(rows)
        if rows.contains(where: { $0.version >= 2 }) { anchor.rebuilt = rows.last?.mark }
        try saveAuditAnchor(anchor)
        return anchor
    }

    private func saveAuditAnchor(_ anchor: AuditAnchor) throws {
        auditAnchor = anchor
        try JSONEncoder.heed.encode(anchor).write(to: auditAnchorFile, options: .atomic)
    }
}
