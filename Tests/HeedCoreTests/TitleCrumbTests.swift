@testable import HeedCore
import Testing

/// The title bar's middle, fitted to the room between the view tabs and the status.
struct TitleCrumbTests {
    private let session = TitleCrumb(lead: "docs-builder", main: "fix-anchors-redirects", tags: ["#2841"])

    /// Columns the fitted crumb takes, gaps included.
    private func width(_ crumb: TitleCrumb) -> Int {
        let parts = [crumb.lead, crumb.lead.map { _ in "/" }, crumb.main] + crumb.tags.map(Optional.some)
            + [crumb.detail]
        let shown = parts.compactMap(\.self)
        return shown.reduce(0) { $0 + $1.count } + shown.count - 1
    }

    @Test func everythingWholeWhenThereIsRoom() {
        let crumb = TitleCrumb(lead: "docs-builder", main: "#2841", detail: "Fix broken anchors in redirects")
        #expect(crumb.fitted(columns: 80) == crumb)
        #expect(session.fitted(columns: 80) == session)
    }

    @Test func theBranchGivesWayAndTheNumberStaysWhole() {
        let fitted = session.fitted(columns: 34)
        #expect(fitted.tags == ["#2841"])
        #expect(fitted.main == "fix-an…irects")
        #expect(width(fitted) <= 34)
    }

    @Test func theNumberGoesRatherThanBeingCut() {
        // 15 + 6 for the number would leave the branch fewer than 12 columns: drop the number, keep the branch.
        let fitted = session.fitted(columns: 26)
        #expect(fitted.tags.isEmpty)
        #expect(fitted.main == "fix-a…rects")
        #expect(width(fitted) <= 26)
        for columns in 1 ... 60 {
            let fitted = session.fitted(columns: columns)
            #expect(fitted.tags.allSatisfy { $0 == "#2841" })
            #expect(fitted.detail == nil)
        }
    }

    @Test func tagsGoLastFirst() {
        let remote = TitleCrumb(lead: "docs-builder", main: "flake-hunt", tags: ["#12", "@devbox"])
        #expect(remote.fitted(columns: 37).tags == ["#12", "@devbox"])
        #expect(remote.fitted(columns: 36).tags == ["#12"])
        #expect(remote.fitted(columns: 29).tags == ["#12"])
        #expect(remote.fitted(columns: 28).tags.isEmpty)
        #expect(remote.fitted(columns: 28).main == "flake-hunt")
    }

    @Test func theTitleIsCutAtTheEndAndDroppedBeforeItIsUseless() {
        let pull = TitleCrumb(lead: "docs-builder", main: "#2841", detail: "Fix broken anchors in redirects")
        #expect(pull.fitted(columns: 30).detail == "Fix brok…")
        #expect(width(pull.fitted(columns: 30)) == 30)
        #expect(pull.fitted(columns: 23).detail == "F…")
        #expect(pull.fitted(columns: 22).detail == nil)
        #expect(pull.fitted(columns: 22).main == "#2841")
    }
}
