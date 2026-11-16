import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A clock whose time moves only when a test says so: a timeout is reached because the test advanced past it, never
/// because a loaded machine was slow. `sleep` suspends until `advance` reaches its instant (or the task is cancelled).
///
/// Not heed's `Clock` (display time): this is Swift's `Clock` protocol, which heed's timeouts take.
final class ManualClock: _Concurrency.Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let until: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var cancelled: Set<UUID> = []
        var reads = 0
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { state in
            state.reads += 1
            return state.now
        }
    }

    /// How many times `now` was read: code that polls the clock (a hook's socket wait) reads it after every slice, so
    /// a count that rose after `advance` means that code has seen the new time.
    var reads: Int { state.withLock { $0.reads } }
    var minimumResolution: Duration { .zero }

    /// How many sleeps are waiting for time to move.
    var sleeping: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = Sleeper(until: deadline, continuation: continuation)
                    return nil
                }
                if let resume { continuation.resume(with: resume) }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on by `duration`, waking every sleep it reaches.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.until <= now }
            for id in due.keys {
                state.sleepers.removeValue(forKey: id)
            }
            return Array(due.values)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Waits, in real time, until `condition` holds. Only a hang guard: ten seconds is far past anything these conditions
/// need, and running out is a failure rather than a hang.
func waitUntil(
    _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let guardUntil = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < guardUntil else {
            Issue.record("condition never held (hang guard)", sourceLocation: sourceLocation)
            throw HangGuard()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct HangGuard: Error {}

/// `task`'s value, or a recorded failure after ten real seconds. Only a hang guard, far past what the task needs: code
/// that ignores its own timeout fails here instead of hanging the suite.
func finished<T: Sendable>(
    _ task: Task<T, any Error>, sourceLocation: SourceLocation = #_sourceLocation
) async throws -> T {
    let once = Mutex<CheckedContinuation<T, any Error>?>(nil)
    return try await withCheckedThrowingContinuation { continuation in
        once.withLock { $0 = continuation }
        Task {
            let result = await task.result
            once.withLock { $0.take() }?.resume(with: result)
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard let continuation = once.withLock({ $0.take() }) else { return }
            Issue.record("never finished (hang guard)", sourceLocation: sourceLocation)
            continuation.resume(throwing: HangGuard())
        }
    }
}

struct ManualClockTests {
    @Test func aSleepWakesOnlyWhenTimeReachesIt() async throws {
        let clock = ManualClock()
        let woke = Mutex(false)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(5))
            woke.withLock { $0 = true }
        }
        try await waitUntil { clock.sleeping == 1 }
        clock.advance(by: .seconds(4))
        #expect(clock.sleeping == 1)
        #expect(!woke.withLock { $0 })
        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(woke.withLock { $0 })
        #expect(clock.now.offset == .seconds(5))
    }

    @Test func aCancelledSleepThrowsAndLeavesNoSleeper() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        try await waitUntil { clock.sleeping == 1 }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeping == 0)
    }
}
