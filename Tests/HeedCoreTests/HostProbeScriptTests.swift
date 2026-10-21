import Foundation
@testable import HeedCore
import Testing

struct HostProbeScriptTests {
    /// The check script runs to the end and is read as a host's answers on a machine with no /etc/os-release (a Mac),
    /// as it does on Linux.
    @Test func theCheckScriptFinishesOnAMac() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", HostProbe.script], timeout: .seconds(20))
        #expect(result.succeeded)
        let info = HostProbe.info(fromOutput: result.stdout, latency: .milliseconds(1))
        #expect(info?.platform.hasPrefix("Darwin") == true)
        #expect(result.stdout.contains("os="))
    }
}
