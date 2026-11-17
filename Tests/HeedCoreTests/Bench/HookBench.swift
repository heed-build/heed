import Foundation
@testable import HeedCore
import Testing

/// Timings that matter but would make the suite flaky: `mise run bench` runs them, in an optimized build and one at a
/// time. `mise run test` and CI skip them.
enum Bench {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HEED_BENCH"] == "1" }

    /// The median and slowest of `runs` calls of `body`, in seconds.
    static func time(runs: Int = 20, _ body: () throws -> Void) rethrows -> (median: Double, slowest: Double) {
        var times: [Double] = []
        for _ in 0 ..< runs {
            let start = ContinuousClock.now
            try body()
            let took = ContinuousClock.now - start
            times.append(Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
        }
        times.sort()
        return (times[times.count / 2], times.last ?? 0)
    }
}

@Suite(.enabled(if: Bench.enabled), .serialized)
struct HookBench {
    /// The origin note is built in the agent's hook on every Bash call in auto mode, with the book at its limit.
    @Test func theOriginNoteStaysInsideAHooksBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = OriginBook.path(forSocket: folder.appendingPathComponent("heed.sock").path)
        try OriginNoteTests.fullBook.write(to: path)
        let (median, slowest) = Bench.time {
            _ = OriginNote.report(input: OriginNoteTests.fullBookCall) { OriginBook.read(path) }
        }
        print("origin note: median \(Int(median * 1000)) ms, slowest \(Int(slowest * 1000)) ms")
        #expect(median < 0.05, "median \(Int(median * 1000)) ms")
        #expect(slowest < 0.25, "slowest \(Int(slowest * 1000)) ms")
    }
}
