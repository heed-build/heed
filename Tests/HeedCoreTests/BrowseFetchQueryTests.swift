import Testing
@testable import HeedCore

struct BrowseFetchQueryTests {
    /// Found by running the query against real GitHub: `projectItems` needs the `read:project` token scope, so asking
    /// for it made every search fail for anyone whose token (gh's default) lacks it.
    @Test func theSearchAsksForNothingThatNeedsAnExtraTokenScope() {
        #expect(!BrowseFetch.query.contains("projectItems"))
        #expect(!BrowseFetch.query.contains("projectsV2"))
    }
}
