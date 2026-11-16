import Foundation
@testable import HeedCore
import Testing

/// What heed does in the background while you work: reading the agents' screens every second, and summing the
/// sessions' reported costs as telemetry arrives. Each bench times the way it was done before against the way it
/// is done now.
@Suite(.enabled(if: Bench.enabled), .serialized)
struct BackgroundBench {
    /// A full agent screen: 50 rows of output under a prompt.
    static let screen = (0 ..< 50).map { "line \($0): compiling module \($0) of 50, nothing to see" }
        .joined(separator: "\n") + "\n✻ Thinking… (esc to interrupt)\n> "

    @Test func guessingAPane() {
        let agent = AgentProfile(name: "codex", command: "codex")
        let runs = 2000
        let (plain, _) = Bench.time {
            for _ in 0 ..< runs {
                _ = ScreenGuess.guess(Self.screen, patterns: ScreenGuess.patterns(for: agent))
            }
        }
        var guesser = ScreenGuesser()
        let (compiled, _) = Bench.time {
            for _ in 0 ..< runs {
                _ = ScreenGuess.guess(Self.screen, compiled: guesser.compiled(for: agent))
            }
        }
        guesser.remember(pane: "p", text: Self.screen, agent: agent, guess: .working)
        let (unchanged, _) = Bench.time {
            for _ in 0 ..< runs {
                _ = guesser.remembered(pane: "p", text: Self.screen, agent: agent)
            }
        }
        let each = { (seconds: Double) in String(format: "%.1f µs", seconds / Double(runs) * 1e6) }
        print("guess a pane: compiling each time \(each(plain)), compiled once \(each(compiled)), unchanged screen "
            + each(unchanged))
        #expect(compiled < plain)
    }

    @Test func summingCostsAsTelemetryArrives() async throws {
        let store = try TelemetryStore()
        var world = TelemetryCostsTests.World(seed: 11)
        // About a busy week's worth: ~20k spans.
        for minute in 0 ..< 6000 {
            await store.insert(world.batch(at: minute))
        }
        let spans = try await store.count()
        let context = TelemetryCostsTests.context(learned: true)
        let since = TelemetryCostsTests.start
        let touched: Set<String> = ["s1"]
        // Before: every batch with a cost read everything since the touched sessions began, and summed it all.
        let (full, _) = try await Self.time(runs: 5) {
            let all = try await store.records(since: since, limit: TelemetryStore.costLimit)
            _ = TelemetryResolve.costs(all, context: context).filter { touched.contains($0.key) }
        }
        // Now: the store is read once; after that a batch sums only the touched sessions' own records.
        _ = try await store.costs(of: touched, since: since, context: context)
        let (running, _) = try await Self.time(runs: 20) {
            await store.insert(world.batch(at: 6001))
            _ = try await store.costs(of: touched, since: since, context: context)
        }
        print(String(
            format: "costs per telemetry batch over %d spans: full read %.1f ms, running totals %.2f ms",
            spans, full * 1000, running * 1000
        ))
        #expect(running < full)
    }

    /// `Bench.time` for async work.
    static func time(runs: Int, _ body: () async throws -> Void) async rethrows -> (median: Double, slowest: Double) {
        var times: [Double] = []
        for _ in 0 ..< runs {
            let start = ContinuousClock.now
            try await body()
            let took = ContinuousClock.now - start
            times.append(Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
        }
        times.sort()
        return (times[times.count / 2], times.last ?? 0)
    }
}
