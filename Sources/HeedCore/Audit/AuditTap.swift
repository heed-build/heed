import Foundation
import Synchronization

/// Where heed's own outward calls reach Audit: every call-log row passes here (`CallLog.record`), carrying the cause of
/// the work in progress, and the ones that leave this Mac (a GitHub write, a `git push`) go to the installed sink. The
/// app installs one; tests use their own with `$current`.
public enum AuditTap {
    public typealias Sink = @Sendable (AuditAction, Cause?) -> Void

    private static let installed = Mutex<Sink?>(nil)
    @TaskLocal public static var current: Sink?

    public static func install(_ sink: Sink?) { installed.withLock { $0 = sink } }

    static var active: Sink? { current ?? installed.withLock { $0 } }

    /// The row with the cause's id added (`detail["cause"]`), after it was handed to Audit when it is an action.
    static func observe(_ call: LoggedCall) -> LoggedCall {
        let cause = Cause.current
        var call = call
        if let cause, call.detail["cause"] == nil { call.detail["cause"] = cause.id }
        if let sink = active, let action = AuditClassifier.action(call, cause: cause) { sink(action, cause) }
        return call
    }
}
