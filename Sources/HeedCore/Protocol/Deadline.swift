import Foundation

/// When a blocking wait gives up, read off any clock: what a thread that polls a socket (a permission hook, the control
/// client) holds instead of a `ContinuousClock.Instant`, so the time that runs out can be a test's manual clock.
///
/// `Clock` here is Swift's protocol, spelled `_Concurrency.Clock` because heed's own `Clock` (display time) shadows it.
public struct Deadline: Sendable {
    private let left: @Sendable () -> Duration
    private let soonest: @Sendable (Duration) -> Deadline
    /// The longest one poll may block before it reads the clock again. A poll's own timeout runs on real time, so on
    /// the continuous clock it is simply the time left (nil); on any other clock (a test's manual clock) a poll cannot
    /// see that clock's time pass, so it wakes in short slices to look.
    public let slice: Duration?

    public init<C: _Concurrency.Clock>(_ instant: C.Instant, on clock: C) where C.Duration == Duration {
        left = { clock.now.duration(to: instant) }
        soonest = { Deadline(min(instant, clock.now.advanced(by: $0)), on: clock) }
        slice = clock is ContinuousClock ? nil : .milliseconds(5)
    }

    /// `duration` from now on `clock`.
    public static func after(_ duration: Duration, on clock: some _Concurrency.Clock<Duration>) -> Deadline {
        Deadline(clock.now.advanced(by: duration), on: clock)
    }

    /// How long until it passes; zero or less once it has.
    public var remaining: Duration { left() }

    public var hasPassed: Bool { remaining <= .zero }

    /// This deadline, or `duration` from now on the same clock, whichever comes first.
    public func capped(at duration: Duration) -> Deadline { soonest(duration) }
}
