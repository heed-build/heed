import Foundation

/// A session's trace (`:trace`, `t` on a session): its last turns from its own OpenTelemetry, each a line of what it
/// did in order (the model, reads, edits, bash, the waits for your OK), laid end to end so the time between turns,
/// when nothing ran, takes no room.
public struct SessionTrace: Equatable, Sendable {
    public struct Segment: Equatable, Sendable, Identifiable {
        public var span: AgentSpan
        /// From the trace's start (the first turn shown), with the gaps between turns taken out.
        public var offset: TimeInterval
        public var id: String { span.id }

        /// What the segment is drawn as: `model`, `read`, `edit`, `bash`, `waiting`, `mcp`, `other`.
        public var lane: String {
            switch span.kind {
            case .model: "model"
            case .permission: "waiting"
            case .tool:
                switch span.name {
                case "bash": "bash"
                case "edit": "edit"
                case "read/grep", "web": "read"
                case let name where name.hasPrefix("mcp"): "mcp"
                default: "other"
                }
            default: "other"
            }
        }
    }

    public struct Turn: Equatable, Sendable, Identifiable {
        public var span: AgentSpan
        /// 1 for the session's first turn the telemetry kept.
        public var number: Int
        public var offset: TimeInterval
        public var segments: [Segment]
        public var id: String { span.id }

        /// `turn 1 · 'fix the lint error'`, or `turn 2` when the prompt was not sent.
        public var title: String {
            let text = span.detail
            return text.isEmpty || text == "turn" || text.hasPrefix("turn ") ? "turn \(number)"
                : "turn \(number) · ‘\(text)’"
        }
    }

    public var session: String
    public var title: String
    public var agent: String
    public var turns: [Turn] = []
    /// The width of the time axis: every turn shown, end to end.
    public var total: TimeInterval = 0
    public var waited: TimeInterval = 0
    public var bash: TimeInterval = 0
    public var tokens = TokenCounts()
    public var cost: Double?
    /// What stood out, against the same commands in other sessions of the repo.
    public var noticed: [String] = []

    public var isEmpty: Bool { turns.isEmpty }

    /// The session's last `turns` turns.
    public static func build(
        session: String, records: TelemetryRecords, context: TelemetryContext, turns limit: Int = 3
    ) -> SessionTrace {
        let info = context.sessions[session]
        var trace = SessionTrace(session: session, title: info?.title ?? session, agent: info?.agent ?? "")
        let all = TelemetryResolve.spans(records, context: context)
        let mine = all.filter { $0.heedSession == session }
        let turnSpans = mine.filter { $0.kind == .turn }.sorted { $0.start < $1.start }
        let shown = turnSpans.suffix(limit)
        let firstNumber = turnSpans.count - shown.count + 1
        var offset: TimeInterval = 0
        for (index, turn) in shown.enumerated() {
            let inside = mine.filter { $0.kind != .turn && $0.traceID == turn.traceID }
                .sorted { $0.start < $1.start }
            let segments = inside.map { span in
                Segment(span: span, offset: offset + max(0, span.start.timeIntervalSince(turn.start)))
            }
            trace.turns.append(Turn(span: turn, number: firstNumber + index, offset: offset, segments: segments))
            offset += turn.duration
            for span in inside {
                if span.kind == .permission { trace.waited += span.duration }
                if span.kind == .tool, span.name == "bash" { trace.bash += span.duration }
                if span.kind == .model {
                    if let tokens = span.tokens { trace.tokens += tokens }
                    if let cost = span.cost { trace.cost = (trace.cost ?? 0) + cost }
                }
            }
        }
        trace.total = offset
        trace.noticed = noticed(trace, all: all, context: context)
        return trace
    }

    /// The segment at `turn`, `index`, clamped.
    public func segment(turn: Int, index: Int) -> Segment? {
        guard turns.indices.contains(turn) else { return nil }
        let segments = turns[turn].segments
        guard !segments.isEmpty else { return nil }
        return segments[min(max(index, 0), segments.count - 1)]
    }

    /// The selected segment, said in a line: `dotnet test tests/Redirects · 40.2 s · ok`, and for a run you approved,
    /// how long it waited for you first.
    public func describe(turn: Int, index: Int) -> (head: String, detail: String)? {
        guard let segment = segment(turn: turn, index: index) else { return nil }
        let span = segment.span
        var head = [span.detail.isEmpty ? span.name : span.detail, TelemetryWords.duration(span.duration)]
        head.append(span.status == .error ? "failed" + (span.error.map { ": \($0)" } ?? "") : "ok")
        if let tokens = span.tokens {
            head.append("\(AgentUsage.count(tokens.allInput)) in / \(AgentUsage.count(tokens.output)) out")
        }
        var detail = ""
        let segments = turns[turn].segments
        if let position = segments.firstIndex(where: { $0.id == segment.id }), position > 0 {
            let before = segments[position - 1].span
            if before.kind == .permission, span.kind == .tool {
                detail = "Waited \(TelemetryWords.duration(before.duration)) for your OK first."
            }
        }
        if span.kind == .permission {
            detail = span.error == nil ? "You allowed it after \(TelemetryWords.duration(span.duration))."
                : "You said no after \(TelemetryWords.duration(span.duration))."
        }
        return (head.joined(separator: " · "), detail)
    }

    /// The command that took most of this session's tool time, set against its runs in the repo's other sessions.
    static func noticed(_ trace: SessionTrace, all: [AgentSpan], context: TelemetryContext) -> [String] {
        let tools = trace.turns.flatMap(\.segments).map(\.span).filter { $0.kind == .tool }
        let toolTime = tools.reduce(0) { $0 + $1.duration }
        guard toolTime > 0 else { return [] }
        let byCommand = Dictionary(grouping: tools.filter { !$0.detail.isEmpty }, by: \.detail)
        guard let top = byCommand
            .max(by: { $0.value.reduce(0) { $0 + $1.duration } < $1.value.reduce(0) { $0 + $1.duration } })
        else { return [] }
        let share = top.value.reduce(0) { $0 + $1.duration } / toolTime
        var line = "\(top.key) is \(Int((share * 100).rounded()))% of this session's tool time."
        let repo = context.sessions[trace.session]?.repo ?? ""
        let elsewhere = all.filter { span in
            span.kind == .tool && span.detail == top.key && span.heedSession != trace.session
                && (repo.isEmpty || span.heedSession.flatMap { context.sessions[$0]?.repo } == repo)
        }
        if elsewhere.count >= 2 {
            let mean = elsewhere.reduce(0) { $0 + $1.duration } / Double(elsewhere.count)
            line += " Its last \(elsewhere.count) runs\(repo.isEmpty ? "" : " in \(repo)") took "
                + "\(TelemetryWords.duration(mean)) on average."
        }
        return [line]
    }
}
