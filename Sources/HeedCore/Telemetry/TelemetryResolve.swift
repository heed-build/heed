import Foundation

/// What heed knows about its sessions, for telemetry to be read against: each session's title and repo, which heed
/// session an agent's own session id is, and the waits for your OK going on now (the agents only export a span once
/// it ended).
public struct TelemetryContext: Hashable, Sendable {
    public struct SessionInfo: Hashable, Sendable {
        public var title: String
        public var repo: String
        public var agent: String

        public init(title: String, repo: String, agent: String) {
            self.title = title
            self.repo = repo
            self.agent = agent
        }
    }

    /// A wait heed sees from the agent's hooks that no span has reported yet.
    public struct Waiting: Hashable, Sendable {
        public var session: String
        public var agent: String
        public var since: Date
        public var detail: String

        public init(session: String, agent: String, since: Date, detail: String) {
            self.session = session
            self.agent = agent
            self.since = since
            self.detail = detail
        }
    }

    public var sessions: [String: SessionInfo]
    /// The agent's own session id → heed's.
    public var byAgentSession: [String: String]
    public var waiting: [Waiting]

    public init(
        sessions: [String: SessionInfo] = [:], byAgentSession: [String: String] = [:], waiting: [Waiting] = []
    ) {
        self.sessions = sessions
        self.byAgentSession = byAgentSession
        self.waiting = waiting
    }

    /// From heed's sessions, open and ended: a session is its own id too (Claude Code takes heed's id as its own). A
    /// session its hooks say waits on a permission prompt is a wait going on now.
    public static func from(sessions: [Session]) -> TelemetryContext {
        var context = TelemetryContext()
        for session in sessions {
            if session.state.state == .blocked {
                context.waiting.append(Waiting(
                    session: session.id, agent: session.agent, since: session.lastActivity,
                    detail: waitingDetail(session.state.reason)
                ))
            }
            context.sessions[session.id] = SessionInfo(
                title: session.title, repo: session.repos.first?.name ?? "", agent: session.agent
            )
            context.byAgentSession[session.id] = session.id
            if let own = session.agentSessionID { context.byAgentSession[own] = session.id }
        }
        return context
    }

    /// `Bash(dotnet publish)` as `dotnet publish`; a reason without a tool's argument as it is.
    static func waitingDetail(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "permission" }
        if let open = reason.firstIndex(of: "("), reason.hasSuffix(")") {
            let inside = reason[reason.index(after: open) ..< reason.index(before: reason.endIndex)]
            return inside.isEmpty ? String(reason[..<open]) : String(inside)
        }
        return reason
    }

    public func session(of span: AgentSpan) -> String? {
        span.heedSession ?? span.agentSession.flatMap { byAgentSession[$0] }
    }
}

/// Telemetry made whole: each span tied to its heed session, a span and an event about the same request counted
/// once, Claude Code's tool wrappers replaced by what they wrap (the wait for your OK, then the run), and every span
/// in a turn, with turns made from prompts where the agent sent no trace.
public enum TelemetryResolve {
    public static func spans(_ records: TelemetryRecords, context: TelemetryContext) -> [AgentSpan] {
        var spans = records.spans.map { span in
            var span = span
            span.heedSession = context.session(of: span)
            return span
        }
        spans = deduplicated(spans)
        spans = unwrapped(spans)
        spans = inTurns(spans, prompts: records.prompts, context: context)
        return spans.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    /// One span per request or tool call: the trace span, with the cost and tokens its event carried.
    static func deduplicated(_ spans: [AgentSpan]) -> [AgentSpan] {
        var byKey: [String: Int] = [:]
        var out: [AgentSpan] = []
        for span in spans {
            guard let key = span.key else {
                out.append(span)
                continue
            }
            guard let index = byKey[key] else {
                byKey[key] = out.count
                out.append(span)
                continue
            }
            var kept = out[index]
            var other = span
            if kept.fromEvent, !other.fromEvent { swap(&kept, &other) }
            kept.cost = kept.cost ?? other.cost
            kept.tokens = kept.tokens ?? other.tokens
            kept.model = kept.model ?? other.model
            kept.traceID = kept.traceID ?? other.traceID
            if kept.detail.isEmpty || kept.detail == kept.name { kept.detail = other.detail }
            if other.status == .error { kept.status = .error }
            kept.error = kept.error ?? other.error
            out[index] = kept
        }
        return out
    }

    /// A tool span with a tool span inside it (Claude Code's `claude_code.tool` around its `.execution`) gives way to
    /// its children, which take its name and detail and its parent.
    static func unwrapped(_ spans: [AgentSpan]) -> [AgentSpan] {
        let byID = Dictionary(spans.map { ($0.id, $0) }) { first, _ in first }
        let wrappers = Set(spans.compactMap { span -> String? in
            guard span.kind == .tool, let parent = span.parentID, byID[parent]?.kind == .tool else { return nil }
            return parent
        })
        guard !wrappers.isEmpty else { return spans }
        return spans.compactMap { span in
            if wrappers.contains(span.id) { return nil }
            guard let parentID = span.parentID, wrappers.contains(parentID), let wrapper = byID[parentID] else {
                return span
            }
            var child = span
            child.parentID = wrapper.parentID
            child.traceID = child.traceID ?? wrapper.traceID
            if child.kind == .tool {
                if child.name == "tool" || child.name.hasPrefix("claude_code") { child.name = wrapper.name }
                if child.detail.isEmpty || child.detail.hasPrefix("claude_code") { child.detail = wrapper.detail }
                child.key = wrapper.key
            } else if child.kind == .permission {
                // What it waited to run; how you answered stays in `error` for a rejection.
                if child.detail.contains("reject") { child.error = "you said no" }
                child.detail = wrapper.detail.isEmpty ? wrapper.name : wrapper.detail
                child.key = wrapper.key.map { $0 + ":wait" }
            }
            return child
        }
    }

    /// Spans with no trace go in the turn of the prompt before them in their session; a trace with no turn span
    /// gets one, from its first span to its last, named by its prompt.
    static func inTurns(_ spans: [AgentSpan], prompts: [AgentPrompt], context: TelemetryContext) -> [AgentSpan] {
        var promptsBySession: [String: [AgentPrompt]] = [:]
        var promptText: [String: String] = [:]
        for prompt in prompts {
            let session = prompt.heedSession ?? prompt.agentSession.flatMap { context.byAgentSession[$0] }
                ?? prompt.agentSession ?? prompt.agent
            promptsBySession[session, default: []].append(prompt)
            if let id = prompt.id, let text = prompt.text { promptText[id] = text }
        }
        for key in promptsBySession.keys {
            promptsBySession[key]?.sort { $0.at < $1.at }
        }
        var out = spans.map { span -> AgentSpan in
            guard span.traceID == nil else { return span }
            var span = span
            let session = span.heedSession ?? span.agentSession ?? span.agent
            if let prompt = promptsBySession[session]?.last(where: { $0.at <= span.start.addingTimeInterval(1) }) {
                span.traceID = prompt.id ?? "turn:\(session):\(Int(prompt.at.timeIntervalSince1970 * 1000))"
                if let text = prompt.text { promptText[span.traceID ?? ""] = text }
            } else {
                span.traceID = "turn:\(session):\(Int(span.start.timeIntervalSince1970 / 3600))"
            }
            return span
        }
        let withTurn = Set(out.filter { $0.kind == .turn }.compactMap(\.traceID))
        let groups = Dictionary(grouping: out.filter { $0.traceID != nil && !withTurn.contains($0.traceID ?? "") }) {
            $0.traceID ?? ""
        }
        for (trace, members) in groups {
            guard let first = members.min(by: { $0.start < $1.start }) else { continue }
            let end = members.map(\.end).max() ?? first.end
            out.append(AgentSpan(
                id: "turn:" + trace, traceID: trace, agent: first.agent, agentSession: first.agentSession,
                heedSession: first.heedSession, kind: .turn, name: "turn", detail: promptText[trace] ?? "turn",
                start: first.start, end: end,
                status: members.contains { $0.status == .error && $0.kind == .model } ? .error : .ok, fromEvent: true
            ))
        }
        // Turns of a trace hang their spans under them.
        let turnByTrace = Dictionary(out.filter { $0.kind == .turn }.compactMap { span in
            span.traceID.map { ($0, span.id) }
        }) { first, _ in first }
        let ids = Set(out.map(\.id))
        return out.map { span in
            guard span.kind != .turn, span.parentID.map(ids.contains) != true,
                  let trace = span.traceID, let turn = turnByTrace[trace] else { return span }
            var span = span
            span.parentID = turn
            return span
        }
    }
}

public extension TelemetryResolve {
    /// What each heed session cost by its agent's own report: its requests' costs, or, for a session whose requests
    /// carried none, its cost metric. A request's span and event count once.
    static func costs(_ records: TelemetryRecords, context: TelemetryContext) -> [String: Double] {
        var requests: [String: Double] = [:]
        for span in deduplicated(records.spans.map { span in
            var span = span
            span.heedSession = context.session(of: span)
            return span
        }) where span.kind == .model {
            guard let session = span.heedSession, let cost = span.cost else { continue }
            requests[session, default: 0] += cost
        }
        var metrics: [String: Double] = [:]
        for sample in AgentUsageSample.summable(records.usage) {
            guard let cost = sample.cost,
                  let session = sample.heedSession ?? sample.agentSession.flatMap({ context.byAgentSession[$0] })
            else { continue }
            metrics[session, default: 0] += cost
        }
        return requests.merging(metrics) { request, _ in request }
    }
}
