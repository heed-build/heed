import Foundation
@testable import HeedCore
import Testing

struct ProcessRunnerTests {
    @Test func outputComesBackEvenWhenSomethingItStartedKeepsThePipeOpen() async throws {
        // The background sleep inherits stdout and keeps it open for 20s; the command itself is done at once.
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 20 & echo hi"], timeout: .seconds(10))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(clock.now - start < .seconds(5))
    }

    @Test func allOutputArrivesForAnOrdinaryCommand() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "seq 1 20000; echo done >&2"])
        #expect(result.stdout.split(separator: "\n").count == 20000)
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
    }

    @Test func aTimeoutStillEndsACommandThatHangs() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessError.self) {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30"], timeout: .seconds(1))
        }
        #expect(clock.now - start < .seconds(5))
    }
}
