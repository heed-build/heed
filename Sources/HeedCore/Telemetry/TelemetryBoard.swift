import Foundation

/// What the OpenTelemetry view narrows to: a range back from now, an agent, a repo, a model, the kinds of span, and
/// a span query (`tool:bash status:error repo:markgraph`, and any words, matched against what the span was).
public struct TelemetryFilter: Hashable, Sendable {
    public var range: TimeInterval = 3600
    public var agent: String?
    public var repo: String?
    public var model: String?
    public var kinds: Set<SpanKind> = Set(SpanKind.shown)
    public var query = ""

    public init(
        range: TimeInterval = 3600, agent: String? = nil, repo: String? = nil, model: String? = nil,
        kinds: Set<SpanKind> = Set(SpanKind.shown), query: String = ""
    ) {
        self.range = range
        self.agent = agent
        self.repo = repo
        self.model = model
        self.kinds = kinds
        self.query = query
    }

    /// The ranges `r` steps through.
    public static let ranges: [TimeInterval] = [900, 3600, 6 * 3600, 86400, 7 * 86400]

    /// `15 m`, `1 h`, `24 h`, `7 d`.
    public static func label(_ range: TimeInterval) -> String {
        if range < 3600 { return "\(Int(range / 60)) m" }
        if range < 86400 * 2 { return "\(Int(range / 3600)) h" }
        return "\(Int(range / 86400)) d"
    }

    /// The kind filter's steps (`K`): what a person reads by, everything, then one kind at a time.
    public static let kindSteps: [Set<SpanKind>] = [Set(SpanKind.shown), Set(SpanKind.allCases)]
        + SpanKind.allCases.map { [$0] }

    /// `turns, tools, permissions, mcp` as the filter bar says it.
    public var kindsLabel: String {
        if kinds == Set(SpanKind.allCases) { return "all" }
        return SpanKind.allCases.filter(kinds.contains).map { $0.label + "s" }.joined(separator: ", ")
    }

    /// The span query's terms: `key:value` pairs and plain words.
    public struct Query: Hashable, Sendable {
        public var terms: [String: String] = [:]
        public var words: [String] = []

        public init(_ text: String) {
            for part in text.split(whereSeparator: \.isWhitespace) {
                let token = part.lowercased()
                if let colon = token.firstIndex(of: ":"), colon != token.startIndex,
                   colon != token.index(before: token.endIndex)
                {
                    terms[String(token[..<colon])] = String(token[token.index(after: colon)...])
                } else {
                    words.append(token)
                }
            }
        }
    }
}

/// One line of the span table: the span, and the session it belongs to as heed knows it.
public struct TelemetryRow: Hashable, Sendable, Identifiable {
    public var span: AgentSpan
    public var session: String?
    public var title: String
    public var repo: String
    /// `helper · claude` for a helper's pane, else the agent.
    public var agentLabel: String
    /// How long you waited for it, start to end, for a span with a wait inside it; else its duration.
    public var wall: TimeInterval
    public var id: String { span.id }

    /// `tool · bash dotnet test`, as the span column reads.
    public var label: String {
        let what = span.kind == .tool ? [span.name, span.detail].filter { !$0.isEmpty }.joined(separator: " ")
            : span.detail.isEmpty ? span.name : span.detail
        return "\(span.kind.label) · \(what)"
    }
}

/// The OpenTelemetry view (Insights › OpenTelemetry): the agents' own spans, events and metrics for a range, summed.
/// Built off the main actor from what the receiver kept and what heed knows of its sessions.
public struct TelemetryBoard: Equatable, Sendable {
    public struct Tile: Equatable, Sendable, Identifiable {
        public enum Tone: Equatable, Sendable { case plain, warn, bad, good }
        public var id: String
        public var label: String
        public var value: String
        public var series: [Double]
        public var tone: Tone
    }

    public struct Latency: Equatable, Sendable, Identifiable {
        public var tool: String
        public var p50: TimeInterval
        public var p95: TimeInterval
        public var count: Int
        public var errors: Int
        public var total: TimeInterval
        public var id: String { tool }
    }

    public enum State: String, Equatable, Sendable { case working, blocked, error, idle }

    public struct AgentStates: Equatable, Sendable, Identifiable {
        public var agent: String
        public var states: [State]
        public var id: String { agent }
    }

    public struct ModelCost: Equatable, Sendable, Identifiable {
        public var model: String
        public var cost: Double
        public var tokens: Int
        public var id: String { model }
    }

    /// One bar of the selected trace's waterfall.
    public struct TraceBar: Equatable, Sendable, Identifiable {
        public var span: AgentSpan
        public var depth: Int
        /// From the trace's start, in seconds.
        public var offset: TimeInterval
        public var id: String { span.id }
    }

    public var start: Date
    public var end: Date
    public var tiles: [Tile] = []
    public var latency: [Latency] = []
    public var states: [AgentStates] = []
    public var models: [ModelCost] = []
    /// Cost by bucket across the range.
    public var costSeries: [Double] = []
    /// Of every input token, the share read from the prompt cache; nil with no tokens.
    public var cacheShare: Double?
    /// Newest first.
    public var rows: [TelemetryRow] = []
    /// Agents that sent anything in the range.
    public var agents: [String] = []
    /// Repos and models seen, for the filters.
    public var repos: [String] = []
    public var modelNames: [String] = []
    /// Sentences about what stood out.
    public var noticed: [String] = []
    /// Everything resolved in the range, before the query: the selected span's trace is drawn whole.
    public var spans: [AgentSpan] = []

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var isEmpty: Bool { spans.isEmpty }

    /// How many buckets a series and a state line have.
    public static let buckets = 30
    public static let stateBuckets = 60

    public static func build(
        records: TelemetryRecords, context: TelemetryContext, filter: TelemetryFilter, now: Date
    ) -> TelemetryBoard {
        let start = now.addingTimeInterval(-filter.range)
        var board = TelemetryBoard(start: start, end: now)
        let resolved = TelemetryResolve.spans(records, context: context)
            .filter { $0.end >= start && $0.start <= now }
        board.agents = Array(Set(resolved.map(\.agent))).sorted()
        board.repos = Array(Set(resolved.compactMap { context.session(of: $0).flatMap { context.sessions[$0]?.repo } }))
            .filter { !$0.isEmpty }.sorted()
        board.modelNames = Array(Set(resolved.compactMap(\.model))).sorted()
        let query = TelemetryFilter.Query(filter.query)
        let narrowed = resolved.filter { matches($0, filter: filter, query: query, context: context, kinds: false) }
        // A trace is drawn whole, whatever the query left of it.
        board.spans = resolved
        let tools = narrowed.filter { $0.kind == .tool }
        let models = narrowed.filter { $0.kind == .model }
        let turns = narrowed.filter { $0.kind == .turn }
        let waits = narrowed.filter { $0.kind == .permission }
        let liveWaits = context.waiting.filter { wait in
            filter.agent.map { $0 == wait.agent } ?? true
                && (filter.repo.map { $0 == context.sessions[wait.session]?.repo } ?? true)
        }
        let minutes = max(filter.range / 60, 1)

        // Tiles.
        let durations = tools.map(\.duration)
        let errorShare = tools.isEmpty ? 0 : Double(tools.count { $0.status == .error }) / Double(tools.count)
        let waited = waits.reduce(0) { $0 + overlap($1, start, now) }
            + liveWaits.reduce(0) { $0 + now.timeIntervalSince(max($1.since, start)) }
        let usage = usageSamples(records, context: context, filter: filter, start: start, now: now, models: models)
        let tokens = models.reduce(0) { $0 + ($1.tokens.map { $0.allInput + $0.output } ?? 0) }
            + usage.reduce(0) { $0 + $1.tokens.allInput + $1.tokens.output }
        let cost = models.reduce(0) { $0 + ($1.cost ?? 0) } + usage.reduce(0) { $0 + ($1.cost ?? 0) }
        board.tiles = [
            Tile(
                id: "turns", label: "turns / min", value: number(Double(turns.count) / minutes),
                series: series(turns.map { ($0.start, 1) }, start: start, end: now), tone: .plain
            ),
            Tile(
                id: "p95", label: "tool p95", value: tools.isEmpty ? "–" : TelemetryWords.duration(percentile(
                    durations,
                    95
                )),
                series: series(tools.map { ($0.end, $0.duration) }, start: start, end: now, mean: true), tone: .plain
            ),
            Tile(
                id: "errors", label: "tool errors", value: tools.isEmpty ? "–" : percent(errorShare),
                series: series(tools.filter { $0.status == .error }.map { ($0.end, 1) }, start: start, end: now),
                tone: errorShare >= 0.02 ? .bad : .plain
            ),
            Tile(
                id: "blocked", label: "blocked on you", value: TelemetryWords.duration(waited),
                series: series(waits.map { ($0.end, $0.duration) }, start: start, end: now),
                tone: waited > 0 ? .warn : .plain
            ),
            Tile(
                id: "tokens", label: "tokens / min", value: TelemetryWords.count(Double(tokens) / minutes),
                series: series(
                    models.map { ($0.end, Double($0.tokens.map { $0.allInput + $0.output } ?? 0)) }
                        + usage.map { ($0.at, Double($0.tokens.allInput + $0.tokens.output)) },
                    start: start,
                    end: now
                ),
                tone: .plain
            ),
            Tile(
                id: "cost", label: "cost, last \(TelemetryFilter.label(filter.range))",
                value: AgentUsage.dollars(cost),
                series: series(
                    models.map { ($0.end, $0.cost ?? 0) } + usage.map { ($0.at, $0.cost ?? 0) },
                    start: start,
                    end: now
                ),
                tone: .good
            ),
        ]

        // Latency by tool, the most time first, with the model's requests last.
        let byTool = Dictionary(grouping: tools, by: \.name)
        let ranked: [Latency] = byTool.map { latency($0.key, $0.value) }
            .sorted { $0.total == $1.total ? $0.tool < $1.tool : $0.total > $1.total }
        board.latency = Array(ranked.prefix(6))
        if !models.isEmpty { board.latency.append(latency("model", models)) }

        // Agent state across the range.
        board.states = Array(Set(narrowed.map(\.agent) + liveWaits.map(\.agent))).sorted().map { agent in
            AgentStates(
                agent: agent,
                states: states(
                    narrowed.filter { $0.agent == agent }, waits: liveWaits.filter { $0.agent == agent },
                    start: start, end: now
                )
            )
        }

        // Cost and tokens by model.
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
        var cacheRead = 0
        var allInput = 0
        for span in models {
            let name = span.model.map { AgentUsage.shortModel($0) } ?? span.agent
            byModel[name, default: (0, 0)].cost += span.cost ?? 0
            byModel[name, default: (0, 0)].tokens += span.tokens.map { $0.allInput + $0.output } ?? 0
            cacheRead += span.tokens?.cacheRead ?? 0
            allInput += span.tokens?.allInput ?? 0
        }
        for sample in usage {
            let name = sample.model.map { AgentUsage.shortModel($0) } ?? sample.agent
            byModel[name, default: (0, 0)].cost += sample.cost ?? 0
            byModel[name, default: (0, 0)].tokens += sample.tokens.allInput + sample.tokens.output
            cacheRead += sample.tokens.cacheRead
            allInput += sample.tokens.allInput
        }
        board.models = byModel.map { ModelCost(model: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.cost == $1.cost ? $0.tokens > $1.tokens : $0.cost > $1.cost }
        board.costSeries = series(
            models.map { ($0.end, $0.cost ?? 0) } + usage.map { ($0.at, $0.cost ?? 0) }, start: start, end: now
        )
        board.cacheShare = allInput > 0 ? Double(cacheRead) / Double(allInput) : nil

        // The table: what the kinds and the query leave, newest first, with the waits going on now on top.
        let shown = narrowed.filter { filter.kinds.contains($0.kind) }
        let children = Dictionary(grouping: narrowed.filter { $0.parentID != nil }) { $0.parentID ?? "" }
        var rows = shown.map { span in
            row(
                span,
                context: context,
                wall: span.kind == .tool
                    ? waitBefore(span, in: children[span.parentID ?? ""] ?? []) + span.duration : span.duration
            )
        }
        if filter.kinds.contains(.permission), query.terms["status"].map({ $0 == "waiting" }) ?? true {
            rows += liveWaits.map { wait in
                let span = AgentSpan(
                    id: "waiting:\(wait.session)", agent: wait.agent, heedSession: wait.session, kind: .permission,
                    name: "permission", detail: wait.detail, start: wait.since, end: now, status: .waiting
                )
                return row(span, context: context, wall: now.timeIntervalSince(wait.since))
            }
        }
        board.rows = rows.sorted { $0.span.start == $1.span.start ? $0.id > $1.id : $0.span.start > $1.span.start }
            .prefix(400).map(\.self)

        board.noticed = noticed(waits: waits, tools: tools, context: context)
        return board
    }

    /// The spans of `span`'s trace, as a waterfall: depth by parent, offset from the trace's first span.
    public func trace(of span: AgentSpan) -> [TraceBar] {
        TelemetryBoard.trace(span.traceID, in: spans)
    }

    public static func trace(_ traceID: String?, in spans: [AgentSpan]) -> [TraceBar] {
        guard let traceID else { return [] }
        let members = spans.filter { $0.traceID == traceID }.sorted { $0.start < $1.start }
        guard let first = members.first else { return [] }
        let byID = Dictionary(members.map { ($0.id, $0) }) { first, _ in first }
        func depth(_ span: AgentSpan) -> Int {
            var depth = 0
            var parent = span.parentID
            while let id = parent, let next = byID[id], depth < 8 {
                depth += 1
                parent = next.parentID
            }
            return depth
        }
        // The turn first, then what it set off, in order.
        let ordered = members.filter { $0.kind == .turn } + members.filter { $0.kind != .turn }
        return ordered.map { TraceBar(span: $0, depth: depth($0), offset: $0.start.timeIntervalSince(first.start)) }
    }

    // MARK: Parts

    static func latency(_ tool: String, _ spans: [AgentSpan]) -> Latency {
        let durations = spans.map(\.duration)
        let total: TimeInterval = durations.reduce(0, +)
        let errors = spans.count { $0.status == .error }
        return Latency(
            tool: tool, p50: percentile(durations, 50), p95: percentile(durations, 95), count: spans.count,
            errors: errors, total: total
        )
    }

    static func row(_ span: AgentSpan, context: TelemetryContext, wall: TimeInterval) -> TelemetryRow {
        let session = context.session(of: span) ?? span.heedSession
        let info = session.flatMap { context.sessions[$0] }
        return TelemetryRow(
            span: span, session: session, title: info?.title ?? span.agentSession.map { String($0.prefix(8)) } ?? "–",
            repo: info?.repo ?? "", agentLabel: span.agent, wall: max(wall, span.duration)
        )
    }

    /// The wait for your OK just before `span` among its siblings: the run's wall time starts there.
    static func waitBefore(_ span: AgentSpan, in siblings: [AgentSpan]) -> TimeInterval {
        siblings.filter { $0.kind == .permission && $0.end <= span.start.addingTimeInterval(0.5)
            && span.start.timeIntervalSince($0.end) < 2 && $0.key.map { $0.hasPrefix(span.key ?? "-") } ?? true
        }.map(\.duration).max() ?? 0
    }

    static func matches(
        _ span: AgentSpan, filter: TelemetryFilter, query: TelemetryFilter.Query, context: TelemetryContext,
        kinds: Bool
    ) -> Bool {
        if kinds, !filter.kinds.contains(span.kind) { return false }
        if let agent = filter.agent, span.agent != agent { return false }
        let info = context.session(of: span).flatMap { context.sessions[$0] }
        if let repo = filter.repo, info?.repo != repo { return false }
        if let model = filter.model, span.kind == .model, span.model.map({ AgentUsage.shortModel($0) }) != model,
           span.model != model { return false }
        for (key, value) in query.terms {
            switch key {
            case "tool": if !(span.kind == .tool && span.name.lowercased().contains(value)) { return false }
            case "status": if span.status.rawValue != value { return false }
            case "repo": if !(info?.repo.lowercased().contains(value) ?? false) { return false }
            case "agent": if !span.agent.lowercased().contains(value) { return false }
            case "model": if !(span.model?.lowercased().contains(value) ?? false) { return false }
            case "kind": if !span.kind.rawValue.hasPrefix(value) { return false }
            case "session": if !(info?.title.lowercased().contains(value) ?? false) { return false }
            case "slow", "over":
                if let seconds = TelemetryWords.seconds(value), span.duration < seconds { return false }
            default:
                if !"\(span.name) \(span.detail)".lowercased().contains(value) { return false }
            }
        }
        let text = [span.name, span.detail, span.model ?? "", info?.title ?? "", info?.repo ?? "", span.agent]
            .joined(separator: " ").lowercased()
        return query.words.allSatisfy { text.contains($0) }
    }

    /// Usage samples from metrics, only for agent sessions whose model requests heed has no tokens or cost for.
    static func usageSamples(
        _ records: TelemetryRecords, context: TelemetryContext, filter: TelemetryFilter, start: Date, now: Date,
        models: [AgentSpan]
    ) -> [AgentUsageSample] {
        let covered = Set(models.filter { $0.cost != nil || $0.tokens != nil }.map { $0.agentSession ?? $0.agent })
        return AgentUsageSample.summable(records.usage).filter { sample in
            guard sample.at >= start, sample.at <= now, !covered.contains(sample.agentSession ?? sample.agent) else {
                return false
            }
            if let agent = filter.agent, sample.agent != agent { return false }
            if let repo = filter.repo {
                let session = sample.heedSession ?? sample.agentSession.flatMap { context.byAgentSession[$0] }
                if session.flatMap({ context.sessions[$0]?.repo }) != repo { return false }
            }
            if let model = filter.model, sample.model.map({ AgentUsage.shortModel($0) }) != model { return false }
            return true
        }
    }

    static func overlap(_ span: AgentSpan, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(span.end, end).timeIntervalSince(max(span.start, start)))
    }

    /// Each bucket's state: waiting for you over an error over working over idle.
    static func states(
        _ spans: [AgentSpan], waits: [TelemetryContext.Waiting], start: Date, end: Date
    ) -> [State] {
        let width = end.timeIntervalSince(start) / Double(stateBuckets)
        guard width > 0 else { return [] }
        var out = [State](repeating: .idle, count: stateBuckets)
        func buckets(_ from: Date, _ to: Date) -> ClosedRange<Int>? {
            guard to >= start, from <= end else { return nil }
            let first = max(0, Int(from.timeIntervalSince(start) / width))
            let last = min(stateBuckets - 1, Int(to.timeIntervalSince(start) / width))
            return first <= last ? first ... last : nil
        }
        for span in spans where span.kind != .permission {
            guard let range = buckets(span.start, span.end) else { continue }
            for index in range where out[index] == .idle {
                out[index] = .working
            }
        }
        for span in spans where span.status == .error && span.kind != .turn {
            guard let range = buckets(span.end, span.end) else { continue }
            for index in range where out[index] != .blocked {
                out[index] = .error
            }
        }
        for span in spans where span.kind == .permission {
            guard let range = buckets(span.start, span.end) else { continue }
            for index in range {
                out[index] = .blocked
            }
        }
        for wait in waits {
            guard let range = buckets(wait.since, end) else { continue }
            for index in range {
                out[index] = .blocked
            }
        }
        return out
    }

    /// `values` summed (or averaged) into `buckets` buckets from `start` to `end`.
    static func series(
        _ values: [(Date, Double)], start: Date, end: Date, mean: Bool = false
    ) -> [Double] {
        let width = end.timeIntervalSince(start) / Double(buckets)
        guard width > 0 else { return [] }
        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for (at, value) in values where at >= start && at <= end {
            let index = min(buckets - 1, Int(at.timeIntervalSince(start) / width))
            sums[index] += value
            counts[index] += 1
        }
        return mean ? zip(sums, counts).map { $1 == 0 ? 0 : $0 / Double($1) } : sums
    }

    /// The nearest-rank percentile; 0 for none.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    static func number(_ value: Double) -> String {
        value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    static func percent(_ share: Double) -> String { String(format: "%.1f%%", share * 100) }

    /// What stood out: where the waits for you went, and which command took the most tool time.
    static func noticed(waits: [AgentSpan], tools: [AgentSpan], context: TelemetryContext) -> [String] {
        var out: [String] = []
        let waited = waits.reduce(0) { $0 + $1.duration }
        if waited >= 30 {
            let byWhat = Dictionary(grouping: waits) { span in
                let repo = context.session(of: span).flatMap { context.sessions[$0]?.repo } ?? ""
                return "\(span.detail)\t\(repo)"
            }
            if let top = byWhat
                .max(by: { $0.value.reduce(0) { $0 + $1.duration } < $1.value.reduce(0) { $0 + $1.duration } })
            {
                let parts = top.key.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let share = top.value.reduce(0) { $0 + $1.duration } / waited
                let place = parts.count > 1 && !parts[1].isEmpty ? " in \(parts[1])" : ""
                out.append(
                    "\(Int((share * 100).rounded()))% of the time waiting for you was \(parts[0])\(place) "
                        + "waiting for an OK (\(top.value.count)×)."
                )
            }
        }
        let toolTime = tools.reduce(0) { $0 + $1.duration }
        if toolTime > 0 {
            let byCommand = Dictionary(grouping: tools.filter { !$0.detail.isEmpty }) { "\($0.name) \($0.detail)" }
            if let top = byCommand
                .max(by: { $0.value.reduce(0) { $0 + $1.duration } < $1.value.reduce(0) { $0 + $1.duration } }),
                top.value.count >= 2
            {
                let median = percentile(top.value.map(\.duration), 50)
                let share = top.value.reduce(0) { $0 + $1.duration } / toolTime
                out.append(
                    "Slowest: \(top.key), \(TelemetryWords.duration(median)) median over \(top.value.count) runs, "
                        + "\(Int((share * 100).rounded()))% of all tool time."
                )
            }
        }
        return out
    }
}

/// Durations and counts as the OpenTelemetry views write them.
public enum TelemetryWords {
    /// `180 ms`, `4.2 s`, `38 s`, `2 m 01 s`, `1 h 10 m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "0 s" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 59.95 {
            let text = String(format: "%.1f", seconds)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " s"
        }
        let total = Int(seconds.rounded())
        if total < 3600 { return String(format: "%d m %02d s", total / 60, total % 60) }
        return "\(total / 3600) h \(total % 3600 / 60) m"
    }

    /// `840`, `18.4k`, `1.2M`.
    public static func count(_ value: Double) -> String {
        if value < 1000 { return String(Int(value.rounded())) }
        if value < 1_000_000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.1fM", value / 1_000_000)
    }

    /// `30s`, `2m`, `1h` as seconds.
    static func seconds(_ text: String) -> TimeInterval? {
        let number = Double(text.filter { $0.isNumber || $0 == "." })
        guard let number else { return nil }
        if text.hasSuffix("ms") { return number / 1000 }
        if text.hasSuffix("m") { return number * 60 }
        if text.hasSuffix("h") { return number * 3600 }
        return number
    }
}
