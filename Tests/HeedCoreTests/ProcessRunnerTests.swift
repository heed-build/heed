import Darwin
import Foundation
@testable import HeedCore
import Testing

/// What these prove is said without the clock: how long a run takes on a busy machine says more about the rest of the
/// suite than about the runner, so each property is one a wrong runner fails however fast or slow the machine is.
struct ProcessRunnerTests {
    @Test func outputComesBackEvenWhenSomethingItStartedKeepsThePipeOpen() async throws {
        // The background sleep inherits stdout and keeps it open; the command itself is done at once. That the sleep
        // is still running when the output is back means the runner did not wait for the pipe's end.
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "sleep 120 & echo $!; echo hi"], timeout: .seconds(60), caller: "test"
        )
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.last == "hi")
        let holder = try #require(lines.first.flatMap { pid_t($0) })
        defer { kill(holder, SIGKILL) }
        #expect(kill(holder, 0) == 0, "the pipe's holder had ended: the output waited for it")
    }

    @Test func aCommandThatHasExitedHasNotTimedOutWhileItsPipeIsStillHeld() async throws {
        // The command is done at once, but its output is collected for a moment (up to 2s) longer than the 1s
        // timeout, because something it started holds the pipe: that is not the command timing out.
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "sleep 120 & echo $!; echo hi"], timeout: .seconds(1), caller: "test"
        )
        let lines = result.stdout.split(separator: "\n").map(String.init)
        if let holder = lines.first.flatMap({ pid_t($0) }) { kill(holder, SIGKILL) }
        #expect(lines.last == "hi" && result.succeeded)
    }

    @Test func allOutputArrivesForAnOrdinaryCommand() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "seq 1 20000; echo done >&2"], caller: "test")
        #expect(result.stdout.split(separator: "\n").count == 20000)
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
    }

    @Test func aTimeoutStillEndsACommandThatHangs() async throws {
        // sh execs the sleep, so the command is the sleep: ended by the timeout, it dies of the runner's SIGTERM
        // rather than finishing its two minutes.
        let error = try #require(await #expect(throws: ProcessError.self) {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 120"], timeout: .seconds(1), caller: "test")
        })
        #expect(error.reason == "timed out after 1.0 seconds")
        #expect(error.result?.status == SIGTERM)
    }
}
