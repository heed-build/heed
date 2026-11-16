import Foundation
@testable import HeedCore
import Testing

/// The sessions' reported costs kept as running totals (`TelemetryCosts`, in `TelemetryStore`) say what a full read
/// of the store (`TelemetryResolve.costs`) says, and the store is read for them once.
struct TelemetryCostsTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A deterministic mix of what agents export: model spans and the events about the same request, spans sent
    /// again, requests with no cost, tool spans, cost deltas and cumulative totals, for sessions heed names, sessions
    /// known only by the agent's own id, and some nobody knows.
    struct World {
        private var seed: UInt64
        private var next = 0

        init(seed: UInt64) { self.seed = seed }

        mutating func number(_ below: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(below))
        }

        mutating func batch(at minute: Int) -> TelemetryRecords {
            var records = TelemetryRecords()
            for _ in 0 ..< 1 + number(6) {
                next += 1
                let (heed, agent) = owner()
                let end = TelemetryCostsTests.start.addingTimeInterval(Double(minute * 60 + number(50)))
                let cost: Double? = number(4) == 0 ? nil : Double(1 + number(500)) / 1000
                let kind: SpanKind = number(5) == 0 ? .tool : .model
                let key = number(4) == 0 ? nil : "req-\(next)"
                records.spans.append(AgentSpan(
                    id: "span-\(next)", agent: "claude", agentSession: agent, heedSession: heed, kind: kind,
                    name: "model", start: end.addingTimeInterval(-2), end: end, cost: cost, key: key
                ))
                // The event about the same request, often with the cost the span did not carry.
                if let key, number(2) == 0 {
                    records.spans.append(AgentSpan(
                        id: "event:\(key)", agent: "claude", agentSession: agent, heedSession: heed, kind: kind,
                        name: "model", start: end.addingTimeInterval(-2), end: end.addingTimeInterval(1),
                        cost: cost ?? 0.007, key: key, fromEvent: true
                    ))
                }
                // A span sent again, with what it says now.
                if next > 3, number(6) == 0 {
                    records.spans.append(AgentSpan(
                        id: "span-\(next - 3)", agent: "claude", agentSession: agent, heedSession: heed, kind: .model,
                        name: "model", start: end.addingTimeInterval(-1), end: end, cost: 0.011, key: "req-\(next - 3)"
                    ))
                }
            }
            for _ in 0 ..< number(3) {
                let (heed, agent) = owner()
                records.usage.append(AgentUsageSample(
                    agent: "codex", agentSession: agent, heedSession: heed,
                    at: TelemetryCostsTests.start.addingTimeInterval(Double(minute * 60 + number(50))),
                    model: number(2) == 0 ? "m1" : "m2", cost: Double(number(90)) / 100, cumulative: number(2) == 0
                ))
            }
            return records
        }

        /// One of the sessions: by heed's id, by the agent's own id, or by an agent session nobody knows.
        private mutating func owner() -> (heed: String?, agent: String?) {
            let session = number(4)
            switch number(3) {
            case 0: return ("s\(session)", nil)
            case 1: return (nil, "agent-\(session)")
            default: return (nil, number(4) == 0 ? "stranger" : "agent-\(session)")
            }
        }
    }

    /// Sessions s0…s3; s0–s2 known by their agent's own id too, s3 only once `learned`.
    static func context(learned: Bool) -> TelemetryContext {
        var context = TelemetryContext()
        for index in 0 ..< 4 {
            context.byAgentSession["s\(index)"] = "s\(index)"
            if index < 3 || learned { context.byAgentSession["agent-\(index)"] = "s\(index)" }
        }
        return context
    }

    static let sessions: Set<String> = ["s0", "s1", "s2", "s3"]

    static func fullRead(_ store: TelemetryStore, since: Date, context: TelemetryContext) async throws
        -> [String: Double]
    {
        try await TelemetryResolve.costs(store.records(since: since, limit: 200_000), context: context)
            .filter { sessions.contains($0.key) }
    }

    static func expectSame(_ running: [String: Double], _ full: [String: Double]) {
        #expect(Set(running.keys) == Set(full.keys))
        for (id, cost) in full {
            #expect(abs((running[id] ?? -1) - cost) < 1e-9, "\(id): \(running[id] ?? -1) against \(cost)")
        }
    }

    @Test(arguments: [1, 2, 3] as [UInt64]) func runningTotalsSayWhatAFullReadSays(seed: UInt64) async throws {
        let store = try TelemetryStore()
        var world = World(seed: seed)
        for minute in 0 ..< 60 {
            await store.insert(world.batch(at: minute))
            let context = Self.context(learned: minute >= 30)
            for since in [Self.start, Self.start.addingTimeInterval(Double(minute * 30))] {
                let running = try await store.costs(of: Self.sessions, since: since, context: context)
                let full = try await Self.fullRead(store, since: since, context: context)
                Self.expectSame(running, full)
            }
        }
        // Read from the store once, for the first batch; every batch after was added to the totals.
        #expect(await store.costReads == 1)
    }

    @Test func onlyTheSessionsAskedForAreSummed() async throws {
        let store = try TelemetryStore()
        var world = World(seed: 7)
        for minute in 0 ..< 20 {
            await store.insert(world.batch(at: minute))
        }
        let context = Self.context(learned: true)
        let one = try await store.costs(of: ["s1"], since: Self.start, context: context)
        let all = try await store.costs(of: Self.sessions, since: Self.start, context: context)
        #expect(Set(one.keys).isSubset(of: ["s1"]))
        // Summed in another order: equal up to rounding.
        let total = try #require(all["s1"])
        #expect(abs((one["s1"] ?? -1) - total) < 1e-9)
    }

    @Test func theAgentsOwnExportsSumAsAFullReadDoes() async throws {
        let store = try TelemetryStore()
        let context = TelemetryContext.from(sessions: [TelemetryTests.session, TelemetryTests.codex])
        for name in ["claude-traces", "claude-logs", "claude-metrics", "codex-logs"] {
            try await store.insert(TelemetryTests.records(name))
            let running = try await store.costs(of: ["s1", "s3"], since: .distantPast, context: context)
            let full = try await TelemetryResolve.costs(store.records(since: .distantPast), context: context)
                .filter { ["s1", "s3"].contains($0.key) }
            Self.expectSame(running, full)
        }
    }

    @Test func aPruneThatTookRecordsAwayIsReadAgain() async throws {
        let store = try TelemetryStore()
        var world = World(seed: 4)
        for minute in 0 ..< 10 {
            await store.insert(world.batch(at: minute))
        }
        let context = Self.context(learned: true)
        _ = try await store.costs(of: Self.sessions, since: Self.start, context: context)
        var settings = TelemetrySettings()
        settings.days = 1
        // Nothing older than a day: nothing goes, and the totals stand.
        await store.prune(now: Self.start.addingTimeInterval(3600), settings: settings)
        _ = try await store.costs(of: Self.sessions, since: Self.start, context: context)
        #expect(await store.costReads == 1)
        // Everything is older than a day now.
        let removed = await store.prune(now: Self.start.addingTimeInterval(3 * 86400), settings: settings)
        #expect(removed > 0)
        let after = try await store.costs(of: Self.sessions, since: Self.start, context: context)
        #expect(await store.costReads == 2)
        #expect(after.isEmpty)
    }
}
