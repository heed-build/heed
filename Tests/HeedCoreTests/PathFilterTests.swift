@testable import HeedCore
import Testing

struct PathFilterTests {
    private let home = "/Users/you"
    private let roots = ["~/code/wt", "~/Projects", "~/code"]

    @Test func pathsSplitAtTheLongestRootTheyLiveUnder() {
        let split = { Paths.split($0, roots: roots, home: home) }
        #expect(split("/Users/you/code/wt/docs-builder/fix-x") == ("~/code/wt/", "docs-builder/fix-x"))
        #expect(split("/Users/you/code/elastic/kibana") == ("~/code/", "elastic/kibana"))
        #expect(split("/Users/you/Projects/heed") == ("~/Projects/", "heed"))
        // Outside every root: relative to the home folder.
        #expect(split("/Users/you/.supacode/repos/mermaid/feature/erd") == (
            "~/",
            ".supacode/repos/mermaid/feature/erd"
        ))
        #expect(split("/opt/elsewhere/repo") == ("", "/opt/elsewhere/repo"))
    }

    @Test func aRootsOwnWordsNoLongerMatch() {
        let relative = Paths.split("/Users/you/code/wt/docs-builder/fix-x", roots: roots, home: home).relative
        #expect(!FilterQuery.matches("code", ["elastic/docs-builder", "fix/x", relative]))
        #expect(FilterQuery.matches("fix", ["elastic/docs-builder", "fix/x", relative]))
    }

    @Test func rangesFindEveryOccurrenceOfEveryWord() {
        let text = "feature/axis-shapes"
        let found = FilterQuery.ranges("AXIS sha", in: text).map { String(text[$0]) }
        #expect(found == ["axis", "sha"])
        #expect(FilterQuery.ranges("a", in: "banana").count == 3)
        #expect(FilterQuery.ranges("", in: "anything").isEmpty)
    }
}
