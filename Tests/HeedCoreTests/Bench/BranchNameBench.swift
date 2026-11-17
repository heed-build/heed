import Foundation
@testable import HeedCore
import Testing

@Suite(.enabled(if: Bench.enabled), .serialized)
struct BranchNameBench {
    /// A 200,000-character word with a reference in it: a branch name reads it once, not once per character.
    static let longWord = String(repeating: "x", count: 200_000) + "#a fix"

    @Test func aVeryLongWordIsReadOnce() {
        let none = BranchPrefixes(prefixes: ["fix": ["fix"]], defaultPrefix: "")
        let (median, slowest) = Bench.time(runs: 5) {
            _ = StartWork.branchName(for: Self.longWord, prefixes: none)
        }
        print("branch name, 200k word: median \(Int(median * 1000)) ms, slowest \(Int(slowest * 1000)) ms")
        #expect(slowest < 1, "slowest \(Int(slowest * 1000)) ms")
    }
}
