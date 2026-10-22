import AppKit
import HeedCore
import Observation

/// What the `:log` view shows: the newest calls that pass its filters, the cursor, and the usage strip. Reads run on
/// the call log's own actor; while the view is open it reads again every two seconds, so the list is live. Fixtures
/// (and shots) read `Fixtures.calls` through the same filter, with no IO.
@MainActor
@Observable
final class CallLogBrowser {
    private(set) var rows: [LoggedCall] = []
    private(set) var cursor = 0
    private(set) var query = CallLogQuery()
    private(set) var usage = CallUsage(llm: [], rateRemaining: nil, rateAt: nil)
    /// Calls not logged: the log could not be opened.
    private(set) var unavailable = false
    @ObservationIgnored private var search = ""
    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private let fixture: [LoggedCall]?

    init(fixture: Bool) {
        self.fixture = fixture ? Fixtures.calls : nil
        if fixture { reload() }
    }

    var selected: LoggedCall? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    /// The view opened: read now, then every two seconds until it closes.
    func opened() {
        reload()
        guard fixture == nil, live == nil else { return }
        live = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.reload()
            }
        }
    }

    func closed() {
        live?.cancel()
        live = nil
    }

    func setCursor(_ index: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(index, 0), rows.count - 1)
    }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        cursor = 0
        reload()
    }

    /// Changes the filters (a `log.*` command) and reads again from the top.
    func change(_ edit: (inout CallLogQuery) -> Void) {
        var next = query
        edit(&next)
        guard next != query else { return }
        query = next
        cursor = 0
        reload()
    }

    private func reload() {
        let filter = query.filter(search: search)
        let today = Calendar.current.startOfDay(for: Clock.now)
        if let fixture {
            apply(fixture.filter(filter.matches), usage: CallUsage(rows: fixture, since: today))
            return
        }
        guard let store = CallLog.active?.store else {
            unavailable = true
            return
        }
        Task { [weak self] in
            guard let rows = try? await store.calls(filter), let usage = try? await store.usage(since: today) else {
                return
            }
            self?.apply(rows, usage: usage)
        }
    }

    /// Only what changed is written, so a read that found nothing new redraws nothing; the cursor stays on its call.
    private func apply(_ fresh: [LoggedCall], usage fresher: CallUsage) {
        let current = selected?.id
        if fresh != rows { rows = fresh }
        if fresher != usage { usage = fresher }
        if let current, let index = rows.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
        }
    }

    /// `log.copy`: the command, as it can be typed again.
    func copy(_ call: LoggedCall) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(call.command, forType: .string)
    }
}
