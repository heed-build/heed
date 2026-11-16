import Foundation

/// Work that several changes ask for, done once for all of them. Outside a batch a request runs the work at once, as
/// a plain call would; inside one it only marks the work as wanted, and the outermost batch's end runs it once. A
/// commit that writes sessions, GitHub, PR details and the pilot's log rebuilds the sidebar once, not four times.
public final class Coalesced {
    private let work: () -> Void
    private var depth = 0
    private var requested = false
    /// How many times the work ran.
    public private(set) var runs = 0

    public init(_ work: @escaping () -> Void) {
        self.work = work
    }

    /// Whether a batch is open.
    public var batching: Bool { depth > 0 }

    /// The work, now, or at the end of the open batch.
    public func request() {
        if depth > 0 { requested = true } else { run() }
    }

    /// Runs `body` with requests held, then the work once if any came.
    public func batch<T>(_ body: () throws -> T) rethrows -> T {
        depth += 1
        defer {
            depth -= 1
            if depth == 0, requested {
                requested = false
                run()
            }
        }
        return try body()
    }

    private func run() {
        runs += 1
        work()
    }
}
