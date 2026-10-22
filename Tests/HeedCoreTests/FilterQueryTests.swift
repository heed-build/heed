@testable import HeedCore
import Testing

struct FilterQueryTests {
    @Test func everyWordMustMatchSomeField() {
        let fields = ["Fix broken anchors", "fix/broken-anchors", "acme/docs-toolkit"]
        #expect(FilterQuery.matches("", fields))
        #expect(FilterQuery.matches("  ", fields))
        #expect(FilterQuery.matches("DOCS fix", fields))
        #expect(!FilterQuery.matches("docs bump", fields))
    }

    @Test func dropsTheLastWord() {
        #expect(FilterQuery.droppingLastWord("atlas fix") == "atlas ")
        #expect(FilterQuery.droppingLastWord("atlas fix  ") == "atlas ")
        #expect(FilterQuery.droppingLastWord("atlas") == "")
    }
}
