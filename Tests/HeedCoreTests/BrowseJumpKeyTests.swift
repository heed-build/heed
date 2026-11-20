@testable import HeedCore
import Testing

struct BrowseJumpKeyTests {
    private func command(_ key: String, in scope: String) -> String? {
        DefaultKeys.scoped[scope]?.first { $0.0 == key }?.1
    }

    /// `gj` ("go jump") is the vim-style alias for ⌘K: both open the same jump, in Browse and over its bulk panel.
    @Test func gjAndCommandKOpenTheSameJump() {
        for scope in ["browse", "browsebulk"] {
            #expect(command("<D-k>", in: scope) == "browse.scope")
            #expect(command("gj", in: scope) == "browse.scope")
        }
    }

    /// The alias lives in Browse only: `gj` is not a global key.
    @Test func gjIsNotBoundOutsideBrowse() {
        for scope in DefaultKeys.scoped.keys where !scope.hasPrefix("browse") {
            #expect(command("gj", in: scope) == nil, "gj in \(scope)")
        }
        #expect(!DefaultKeys.normal.contains { $0.0 == "gj" })
    }
}
