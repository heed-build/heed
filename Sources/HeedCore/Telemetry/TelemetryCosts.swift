import Foundation

/// What each heed session cost by its agent's own report (`TelemetryResolve.costs`), kept up to date export by
/// export: what costs depend on (model spans and cost samples) is indexed by whose it is as it arrives, so a session's
/// cost is summed from its own records instead of from everything kept. Sessions are looked up when asked, with the
/// context of then: an agent session heed learns of later still counts for its heed session.
public struct TelemetryCosts: Sendable {
    /// A model span, as much of it as its cost needs.
    struct Request: Sendable {
        var id: String
        var end: Date
        var fromEvent: Bool
        var cost: Double?
        var heedSession: String?
        var agentSession: String?
        /// Arrival order, for spans that ended at the same moment.
        var order: Int
    }

    /// A sample of a cost metric.
    struct Sample: Sendable {
        var at: Date
        var cost: Double
        var heedSession: String?
        var agentSession: String?
    }

    /// Model spans about the same request (its `key`, else the span's own id), in the order the store returns them.
    private var requests: [String: [Request]] = [:]
    /// Which group each span is in, so one sent again replaces itself.
    private var groupOfSpan: [String: String] = [:]
    /// Groups by whose they say they are (`owner`).
    private var requestsByOwner: [String: Set<String>] = [:]
    /// Samples that add up, by whose they are.
    private var deltas: [String: [Sample]] = [:]
    /// Of each cumulative cost series, the latest total.
    private var latest: [String: Sample] = [:]
    /// Series by whose they are.
    private var seriesByOwner: [String: Set<String>] = [:]
    private var arrivals = 0

    public init() {}

    public init(_ records: TelemetryRecords) {
        add(records)
    }

    /// Who a record says it is about: heed's session when it names it, else the agent's own session.
    private static func owner(heedSession: String?, agentSession: String?) -> String? {
        if let heedSession { return "h:" + heedSession }
        return agentSession.map { "a:" + $0 }
    }

    /// One export, as the store keeps it.
    public mutating func add(_ records: TelemetryRecords) {
        for span in records.spans {
            // A span sent again (same id) replaces the one kept.
            if let group = groupOfSpan[span.id] {
                requests[group]?.removeAll { $0.id == span.id }
                groupOfSpan[span.id] = nil
            }
            guard span.kind == .model else { continue }
            let group = span.key ?? "id:" + span.id
            arrivals += 1
            let request = Request(
                id: span.id, end: span.end, fromEvent: span.fromEvent, cost: span.cost,
                heedSession: span.heedSession, agentSession: span.agentSession, order: arrivals
            )
            var members = requests[group] ?? []
            let index = members.firstIndex { ($0.end, $0.order) > (request.end, request.order) } ?? members.endIndex
            members.insert(request, at: index)
            requests[group] = members
            groupOfSpan[span.id] = group
            if let owner = Self.owner(heedSession: span.heedSession, agentSession: span.agentSession) {
                requestsByOwner[owner, default: []].insert(group)
            }
        }
        for sample in records.usage {
            guard let cost = sample.cost,
                  let owner = Self.owner(heedSession: sample.heedSession, agentSession: sample.agentSession)
            else {
                // A cumulative cost sample nobody can be found for still ends its series' latest.
                if sample.cumulative, let cost = sample.cost { keepLatest(sample, cost: cost, owner: nil) }
                continue
            }
            if sample.cumulative {
                keepLatest(sample, cost: cost, owner: owner)
            } else {
                deltas[owner, default: []].append(Sample(
                    at: sample.at, cost: cost, heedSession: sample.heedSession, agentSession: sample.agentSession
                ))
            }
        }
    }

    /// `AgentUsageSample.summable`'s series: the agent's session (else the agent), the model, and that it is a cost.
    private mutating func keepLatest(_ sample: AgentUsageSample, cost: Double, owner: String?) {
        let series = "\(sample.agentSession ?? sample.agent)|\(sample.model ?? "")|cost"
        guard latest[series].map({ $0.at <= sample.at }) ?? true else { return }
        latest[series] = Sample(
            at: sample.at, cost: cost, heedSession: sample.heedSession, agentSession: sample.agentSession
        )
        if let owner { seriesByOwner[owner, default: []].insert(series) }
    }

    /// What `TelemetryResolve.costs` says each of `sessions` cost, over what ended (or happened) since `since`.
    public func costs(of sessions: Set<String>, since: Date, context: TelemetryContext) -> [String: Double] {
        func session(_ heedSession: String?, _ agentSession: String?) -> String? {
            heedSession ?? agentSession.flatMap { context.byAgentSession[$0] }
        }
        // Whose records may be a session's: its own id, and every agent session the context maps to it.
        var owners: Set<String> = []
        for id in sessions {
            owners.insert("h:" + id)
        }
        for (agentSession, id) in context.byAgentSession where sessions.contains(id) {
            owners.insert("a:" + agentSession)
        }
        var requested: [String: Double] = [:]
        var groups: Set<String> = []
        for owner in owners {
            groups.formUnion(requestsByOwner[owner] ?? [])
        }
        for group in groups {
            // `TelemetryResolve.deduplicated`: the trace span over the event, with the first cost either carried.
            var kept: Request?
            for member in requests[group] ?? [] where member.end >= since {
                guard var current = kept else {
                    kept = member
                    continue
                }
                var other = member
                if current.fromEvent, !other.fromEvent { swap(&current, &other) }
                current.cost = current.cost ?? other.cost
                kept = current
            }
            guard let kept, let cost = kept.cost, let id = session(kept.heedSession, kept.agentSession),
                  sessions.contains(id)
            else { continue }
            requested[id, default: 0] += cost
        }
        var metrics: [String: Double] = [:]
        for owner in owners {
            for sample in deltas[owner] ?? [] where sample.at >= since {
                guard let id = session(sample.heedSession, sample.agentSession), sessions.contains(id) else { continue }
                metrics[id, default: 0] += sample.cost
            }
        }
        var series: Set<String> = []
        for owner in owners {
            series.formUnion(seriesByOwner[owner] ?? [])
        }
        for key in series {
            guard let sample = latest[key], sample.at >= since,
                  let id = session(sample.heedSession, sample.agentSession), sessions.contains(id)
            else { continue }
            metrics[id, default: 0] += sample.cost
        }
        return requested.merging(metrics) { request, _ in request }
    }
}
