import Foundation
@testable import HeedCore
import Testing

struct ShellLineTests {
    /// What heed builds for a pane: sh syntax with quotes inside quotes, braces and `$?`.
    private let command = #"sh -c 'if [ -f nothing-here ]; then printf '\''%s\n'\'' '\''setup'\''; { false; } || { c=$?; printf '\''failed: %s\n'\'' "$c"; }; else printf '\''%s\n'\'' '\''skipped (no file)'\''; fi' && echo "done $((1 + 1))""#

    @Test func aPlainLineIsTypedAsItIs() {
        #expect(ShellLine.typed("claude --resume abc-123") == "claude --resume abc-123")
    }

    @Test func theSameCommandRunsTheSameInEveryShell() async throws {
        let expected = try await ProcessRunner.run("/bin/sh", ["-c", command]).stdout
        #expect(!expected.isEmpty)
        let line = ShellLine.typed(command)
        for shell in [
            "/bin/sh",
            "/bin/bash",
            "/bin/zsh",
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
        ]
            where FileManager.default.isExecutableFile(atPath: shell)
        {
            let result = try await ProcessRunner.run(shell, ["-c", line])
            #expect(result.stdout == expected, "in \(shell): \(result.stderr)")
        }
    }
}
