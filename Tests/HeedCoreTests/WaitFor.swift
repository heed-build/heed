import Foundation
import Testing

/// Waits for `condition` to hold and returns as soon as it does: the replacement for a fixed `Task.sleep` followed by
/// an
/// assertion, which is a guess at how long a loaded machine takes. The deadline is generous because it is only ever
/// reached when the behaviour is broken, and then it fails the test with `message`.
func waitFor(
    _ message: @autoclosure () -> String = "condition never held",
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () -> Bool
) async throws {
    let until = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < until else {
            Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
