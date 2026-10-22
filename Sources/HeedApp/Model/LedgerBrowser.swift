import Foundation
import HeedCore
import Observation

/// History's ledger (`history.ledger`): every entry heed wrote, from `heed.sqlite`, newest first, narrowed by `/`, and
/// the cursor. Fixtures (and shots) read `Fixtures.ledger`, with no IO.
@MainActor
@Observable
final class LedgerBrowser {
    private(set) var entries: [String: LedgerEntry] = [:]
    /// `entries` that `/` leaves, newest first.
    private(set) var rows: [LedgerEntry] = []
    private(set) var cursor = 0
    /// Sessions whose entry is being written now.
    private(set) var writing: Set<String> = []
    @ObservationIgnored private var search = ""
    @ObservationIgnored private(set) var log: EventLog?

    init(fixture: Bool) {
        if fixture { replace(Fixtures.ledger) }
    }

    var selected: LedgerEntry? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    /// Reads what the event log keeps.
    func attach(log: EventLog?) {
        self.log = log
        guard let log else { return }
        Task { [weak self] in
            guard let entries = try? await log.ledger() else { return }
            self?.replace(entries)
        }
    }

    private func replace(_ list: [LedgerEntry]) {
        entries = Dictionary(list.map { ($0.id, $0) }) { first, _ in first }
        refilter()
    }

    /// A written (or rewritten) entry: kept here and in the log.
    func upsert(_ entry: LedgerEntry, persist: Bool = true) {
        entries[entry.id] = entry
        refilter()
        if persist, let log { Task { await log.write([.ledger(entry)]) } }
    }

    func setWriting(_ id: String, _ on: Bool) {
        if on { writing.insert(id) } else { writing.remove(id) }
    }

    func setCursor(_ index: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(index, 0), rows.count - 1)
    }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        cursor = 0
        refilter()
    }

    /// Only what changed is written; the cursor stays on its entry.
    private func refilter() {
        let current = selected?.id
        let fresh = entries.values.filter { entry in
            FilterQuery.matches(
                search,
                [entry.title, entry.place, entry.branch, entry.outcome, entry.agent, entry.summary ?? ""]
                    + entry.decisions + entry.followUps + entry.repos
            )
        }
        .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        if fresh != rows { rows = fresh }
        if let current, let index = rows.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
        }
    }
}
