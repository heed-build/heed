import Darwin

/// A write to a pipe or socket whose reader has gone raises SIGPIPE, and SIGPIPE ends the process: an agent that exits
/// while heed writes to its stdin would take the app (or a test run) down with it. Every process heed builds ignores
/// it once at startup, so such a write fails with EPIPE instead, and each writer turns that into an error of its own.
/// Sockets also set `SO_NOSIGPIPE`; pipes cannot.
public enum BrokenPipe {
    /// Process-wide and idempotent: call it first thing in `main`.
    public static func ignore() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Whether SIGPIPE is ignored in this process now.
    public static var isIgnored: Bool {
        var action = sigaction()
        guard sigaction(SIGPIPE, nil, &action) == 0 else { return false }
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}
