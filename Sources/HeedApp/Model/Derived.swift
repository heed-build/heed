import Foundation
import Observation
import os

/// A value worked out from observed state, kept until something it read changes, or for a second at most (it may read
/// the clock). The title bar's Attention badge, its counts and its list all start from the same entries, on every
/// redraw: worked out once, they are read many times.
///
/// Whoever reads the value also observes `generation`, which the cache moves on as soon as an input changes, so a view
/// that got the kept value redraws as it would have had it worked the value out itself.
@MainActor
final class Derived<Value> {
    private var value: Value?
    private var at = Date.distantPast
    /// Set from the observation callback, which runs on whatever thread changed the input.
    private let stale = OSAllocatedUnfairLock(initialState: true)
    private let life: TimeInterval
    /// Moves an observed counter on: the readers of the kept value redraw.
    private let changed: @MainActor () -> Void
    /// How many times the value was worked out.
    private(set) var computed = 0

    init(life: TimeInterval = 1, changed: @escaping @MainActor () -> Void) {
        self.life = life
        self.changed = changed
    }

    func value(now: Date, _ compute: () -> Value) -> Value {
        let age = now.timeIntervalSince(at)
        if let value, !stale.withLock({ $0 }), age >= 0, age < life { return value }
        stale.withLock { $0 = false }
        let changed = changed
        let stale = stale
        let fresh = withObservationTracking(compute) {
            let first = stale.withLock { flag in
                defer { flag = true }
                return !flag
            }
            guard first else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { changed() }
            } else {
                Task { @MainActor in changed() }
            }
        }
        value = fresh
        at = now
        computed += 1
        return fresh
    }

    /// Forget the kept value: the next read works it out.
    func reset() {
        stale.withLock { $0 = true }
    }
}
