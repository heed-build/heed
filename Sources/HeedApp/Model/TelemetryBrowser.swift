import Foundation
import HeedCore
import Observation

/// Insights › OpenTelemetry and a session's trace: the receiver's state, the board for the filter, the span under the
/// cursor and its trace, and a session's trace with its cursor. Boards are built off the main actor from
/// `telemetry.sqlite`; fixtures (and shots) read `Fixtures.telemetry`, with no IO.
@MainActor
@Observable
final class TelemetryBrowser {
    enum Receiver: Equatable {
        /// `[telemetry] enabled = false`.
        case off
        case starting
        case listening(port: Int)
        /// The port was taken, or the store could not be opened.
        case failed(String)
    }

    private(set) var receiver: Receiver = .starting
    /// What heed adds to the agents it starts, and whom it leaves alone; nil until decided.
    private(set) var export: TelemetryExport?
    private(set) var board = TelemetryBoard(start: Clock.now, end: Clock.now)
    private(set) var filter = TelemetryFilter()
    /// New spans redraw the board as they arrive.
    private(set) var live = true
    private(set) var cursor = 0
    /// When the receiver last took an export, and from which agents in the last minutes.
    private(set) var lastReceived: Date?
    private(set) var recentAgents: Set<String> = []

    /// A session's trace (`session.trace`).
    private(set) var trace: SessionTrace?
    private(set) var traceTurn = 0
    private(set) var traceSegment = 0
    /// Where `session.trace` was asked from, to go back to.
    var traceReturn: String?

    @ObservationIgnored let fixture: Bool
    @ObservationIgnored var store: TelemetryStore?
    @ObservationIgnored var context: () -> TelemetryContext = { TelemetryContext() }
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false
    @ObservationIgnored private var agentSeen: [String: Date] = [:]

    init(fixture: Bool) {
        self.fixture = fixture
        if fixture {
            receiver = .listening(port: 4318)
            export = TelemetryExport(port: 4318)
            recentAgents = ["claude", "codex"]
            lastReceived = Clock.now
        }
    }

    /// What the forwarder did, per collector host.
    private(set) var forwarding: [String: TelemetryForwarder.Stats] = [:]
    /// The proxy banner was put away for this launch (`telemetry.banner.hide`).
    private(set) var bannerHidden = false

    func setReceiver(_ state: Receiver) { if state != receiver { receiver = state } }
    func setForwarding(_ stats: [String: TelemetryForwarder.Stats]) { if stats != forwarding { forwarding = stats } }
    func hideBanner() { bannerHidden = true }

    /// The fake world as it is when heed forwards claude's metrics and logs to a collector of yours (shots).
    func showProxyInShots() {
        let metrics = TelemetryUpstream(url: URL(string: "https://otel.example.com/v1/metrics")!, wire: .protobuf)
        let logs = TelemetryUpstream(url: URL(string: "https://otel.example.com/v1/logs")!, wire: .protobuf)
        export = TelemetryExport(port: 4318, modes: ["claude": .forward([.metrics: metrics, .logs: logs])])
        var stats = TelemetryForwarder.Stats()
        stats.forwarded = 1204
        forwarding = ["otel.example.com": stats]
    }

    /// The banner shows while heed forwards any agent's telemetry, unless put away for this launch.
    var showsBanner: Bool { (export?.proxying ?? false) && !bannerHidden }

    /// `otel.example.com · 1204 sent · 0 dropped`, per host heed forwards to.
    func forwardingLines() -> [String] {
        let hosts = Set((export?.routes.values.flatMap(\.values) ?? []).compactMap(\.host))
        return hosts.sorted().map { host in
            let stats = forwarding[host] ?? TelemetryForwarder.Stats()
            var parts = ["\(stats.forwarded) sent", "\(stats.dropped) dropped"]
            if stats.pending > 0 { parts.append("\(stats.pending) waiting") }
            if stats.refused > 0 { parts.append("\(stats.refused) refused") }
            if stats.pending > 0 || stats.refused > 0, let error = stats.lastError { parts.append(error) }
            return "forwarding to \(host) · " + parts.joined(separator: " · ")
        }
    }

    func setExport(_ value: TelemetryExport?) { if value != export { export = value } }

    var selected: TelemetryRow? { board.rows.indices.contains(cursor) ? board.rows[cursor] : nil }

    /// The selected span's trace, as a waterfall.
    var selectedTrace: [TelemetryBoard.TraceBar] { selected.map { board.trace(of: $0.span) } ?? [] }

    func setCursor(_ index: Int) {
        guard !board.rows.isEmpty else { return }
        cursor = min(max(index, 0), board.rows.count - 1)
    }

    // MARK: Filters

    func cycleRange(_ named: String?) {
        if let named, let seconds = Self.seconds(named) {
            filter.range = seconds
        } else {
            let index = TelemetryFilter.ranges.firstIndex(of: filter.range) ?? 0
            filter.range = TelemetryFilter.ranges[(index + 1) % TelemetryFilter.ranges.count]
        }
        reload()
    }

    /// `15m`, `1h`, `24h`, `7d`.
    static func seconds(_ text: String) -> TimeInterval? {
        guard let number = Double(text.filter(\.isNumber)), number > 0 else { return nil }
        if text.hasSuffix("d") { return number * 86400 }
        if text.hasSuffix("h") { return number * 3600 }
        return number * 60
    }

    /// The next of `options` after `current` (nil, all, first), or the one named.
    private static func next(_ current: String?, in options: [String], named: String?) -> String? {
        if let named { return named == "all" ? nil : named }
        guard !options.isEmpty else { return nil }
        guard let current, let index = options.firstIndex(of: current) else { return options[0] }
        return index + 1 < options.count ? options[index + 1] : nil
    }

    func cycleAgent(_ named: String?) {
        filter.agent = Self.next(filter.agent, in: board.agents, named: named)
        reload()
    }

    func cycleRepo(_ named: String?) {
        filter.repo = Self.next(filter.repo, in: board.repos, named: named)
        reload()
    }

    func cycleModel(_ named: String?) {
        filter.model = Self.next(
            filter.model, in: board.models.map(\.model), named: named
        )
        reload()
    }

    func cycleKinds(_ named: String?) {
        if let named, let kind = SpanKind(rawValue: named) {
            filter.kinds = [kind]
        } else if named == "all" {
            filter.kinds = Set(SpanKind.allCases)
        } else {
            let steps = TelemetryFilter.kindSteps
            let index = steps.firstIndex(of: filter.kinds) ?? 0
            filter.kinds = steps[(index + 1) % steps.count]
        }
        reload()
    }

    func setQuery(_ text: String) {
        guard text != filter.query else { return }
        filter.query = text
        reload()
    }

    func toggleLive() {
        live.toggle()
        if live { reload() }
    }

    // MARK: Building

    /// What the board and the trace are built from: the fixture's hour, or what the store kept for the range.
    private func records(since: Date) async -> TelemetryRecords {
        if fixture { return Fixtures.telemetry(now: Clock.now) }
        guard let store else { return TelemetryRecords() }
        return await (try? store.records(since: since)) ?? TelemetryRecords()
    }

    func reload() {
        // The fake world builds in place, so a shot draws it at once.
        if fixture {
            let now = Clock.now
            var context = context()
            // The fake world's blocked session has waited two minutes, not since it was made.
            context.waiting = context.waiting.map { wait in
                var wait = wait
                wait.since = min(wait.since, now.addingTimeInterval(-121))
                return wait
            }
            apply(TelemetryBoard.build(
                records: Fixtures.telemetry(now: now), context: context, filter: filter, now: now
            ))
            return
        }
        guard !reloading else {
            reloadAgain = true
            return
        }
        reloading = true
        let filter = filter
        let context = context()
        let now = Clock.now
        Task { [weak self] in
            guard let self else { return }
            let records = await records(since: now.addingTimeInterval(-filter.range - 3600))
            let board = await Task.detached(priority: .utility) {
                TelemetryBoard.build(records: records, context: context, filter: filter, now: now)
            }.value
            apply(board)
            reloading = false
            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    private func apply(_ fresh: TelemetryBoard) {
        let selectedID = selected?.id
        if fresh != board { board = fresh }
        if let selectedID, let index = board.rows.firstIndex(where: { $0.id == selectedID }) {
            cursor = index
        } else {
            cursor = min(cursor, max(board.rows.count - 1, 0))
        }
    }

    /// An export arrived: who sent it, and the views redrawn when live.
    func received(_ records: TelemetryRecords, showing: Bool) {
        let now = Date()
        lastReceived = now
        for agent in Set(records.spans.map(\.agent) + records.prompts.map(\.agent) + records.usage.map(\.agent)) {
            agentSeen[agent] = now
        }
        let recent = Set(agentSeen.filter { now.timeIntervalSince($0.value) < 600 }.keys)
        if recent != recentAgents { recentAgents = recent }
        guard live, showing else { return }
        reload()
        if let session = trace?.session { openTrace(session: session, keepCursor: true) }
    }

    // MARK: A session's trace

    func openTrace(session: String, turn: String? = nil, keepCursor: Bool = false) {
        let context = context()
        if fixture {
            show(
                SessionTrace.build(session: session, records: Fixtures.telemetry(now: Clock.now), context: context),
                turn: turn,
                keepCursor: keepCursor
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let records = await records(since: Clock.now.addingTimeInterval(-7 * 86400))
            let trace = await Task.detached(priority: .utility) {
                SessionTrace.build(session: session, records: records, context: context)
            }.value
            show(trace, turn: turn, keepCursor: keepCursor)
        }
    }

    private func show(_ trace: SessionTrace, turn: String?, keepCursor: Bool) {
        if trace != self.trace { self.trace = trace }
        if let turn, let index = trace.turns.firstIndex(where: { $0.span.traceID == turn }) {
            traceTurn = index
            traceSegment = 0
        } else if !keepCursor {
            traceTurn = max(trace.turns.count - 1, 0)
            traceSegment = 0
        }
        clampTrace()
    }

    func moveTurn(_ delta: Int) {
        traceTurn += delta
        clampTrace()
    }

    func moveSegment(_ delta: Int) {
        traceSegment += delta
        clampTrace()
    }

    func setTraceCursor(turn: Int, segment: Int) {
        traceTurn = turn
        traceSegment = segment
        clampTrace()
    }

    private func clampTrace() {
        guard let trace, !trace.turns.isEmpty else {
            traceTurn = 0
            traceSegment = 0
            return
        }
        traceTurn = min(max(traceTurn, 0), trace.turns.count - 1)
        let count = trace.turns[traceTurn].segments.count
        traceSegment = min(max(traceSegment, 0), max(count - 1, 0))
    }
}
