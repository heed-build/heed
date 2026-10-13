import Foundation
@testable import HeedCore
import Testing

/// The docs' reference pages are generated; these fail when a command, key or config default changed and
/// `mise run shots` was not run to regenerate them.
struct DocsReferenceTests {
    private func docs(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent("docs/\(path)"), encoding: .utf8)
    }

    @Test func keyReferenceIsCurrent() {
        #expect(docs("keyboard/reference.md") == DocsReference.keys(), "run `mise run shots` to regenerate")
    }

    @Test func configReferenceIsCurrent() {
        #expect(docs("configuration/reference.md") == DocsReference.config(), "run `mise run shots` to regenerate")
    }

    @Test func everyCommandIsInTheKeyReference() {
        let page = DocsReference.keys()
        for spec in Commands.all {
            #expect(page.contains("`\(spec.name)`"), "\(spec.name) missing")
        }
    }
}
