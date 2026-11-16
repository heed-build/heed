import os

/// Signpost intervals on heed's hot paths (subsystem `build.heed.app`, category `perf`), for Instruments: see
/// AGENTS.md, "Measuring the app". They measure only; nothing reads them back. While nothing records them, a
/// signpost is one `isEnabled` check.
///
///     let perf = Perf.begin("commit")
///     defer { perf.end() }
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "build.heed.app", category: "perf")

    /// One interval, from `begin` to `end`.
    public struct Interval: Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState?

        public func end() {
            guard let state else { return }
            Perf.signposter.endInterval(name, state)
        }
    }

    /// Starts an interval called `name`; nothing when no one records.
    public static func begin(_ name: StaticString) -> Interval {
        guard signposter.isEnabled else { return Interval(name: name, state: nil) }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    /// `body` as one interval called `name`.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try body()
    }

    /// `body`, awaited, as one interval called `name`: it spans the suspensions too.
    public static func measure<T>(
        _ name: StaticString, isolation _: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try await body()
    }
}
