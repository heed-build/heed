import Foundation
@testable import HeedCore
import Testing

struct BrowseDiffTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func item(_ number: Int, _ title: String? = nil, days: Double = 1, comments: Int = 0) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText(
                title ?? "Item \(number)",
                source: .issueTitle,
                author: .unknown
            ),
            comments: comments, createdAt: now.addingTimeInterval(-1000 * 86400),
            updatedAt: now.addingTimeInterval(-days * 86400)
        )
    }

    /// Newest update first: 1 (1 day), 2 (2 days), 3 (3 days), 4 (4 days).
    private var list: [BrowseItem] { (1 ... 4).map { item($0, days: Double($0)) } }

    @Test func `the same list is no change at all`() {
        let diff = BrowseDiff.between(current: list, fetched: list.reversed(), order: .updated)
        #expect(diff.isEmpty)
        #expect(!diff.isStructural)
        #expect(diff.summary.isEmpty)
        #expect(diff.target.map(\.number) == [1, 2, 3, 4])
    }

    @Test func `a changed field is an update and nothing structural`() {
        let edits: [(String, (inout BrowseItem) -> Void)] = [
            ("title", { $0.title = ExternalText("New title", source: .issueTitle, author: .unknown) }),
            ("labels", { $0.labels = ["bug"] }),
            ("assignees", { $0.assignees = ["jdoe"] }),
            ("comments", { $0.comments += 1 }),
            ("state", { $0.state = .closed }),
            ("draft", { $0.isDraft = true }),
            ("checks", { $0.checks = .failing }),
            ("review", { $0.review = .approved }),
            ("reviewers", { $0.requestedReviewers = ["mara-k"] }),
            ("linked", { $0.hasLinkedPull = true }),
        ]
        // The item stays in place: its update time is the same.
        for (name, edit) in edits {
            var changed = list
            edit(&changed[1])
            let diff = BrowseDiff.between(current: list, fetched: changed, order: .updated)
            #expect(diff.updated.map(\.number) == [2], "\(name)")
            #expect(!diff.isStructural, "\(name)")
            #expect(diff.summary == "1 updated", "\(name)")
        }
    }

    @Test func `a row that was touched is updated, and reordered until the list is refreshed`() {
        var changed = list
        changed[3].updatedAt = now // 4 jumps to the top
        let diff = BrowseDiff.between(current: list, fetched: changed, order: .updated)
        #expect(diff.updated.map(\.number) == [4])
        #expect(diff.moved == ["acme/docs#4"])
        #expect(diff.isStructural)
        #expect(diff.target.map(\.number) == [4, 1, 2, 3])
        #expect(diff.summary == "1 updated, 1 reordered")
        #expect(diff.bannerText == "1 reordered")
    }

    @Test func `new and gone rows`() {
        let fetched = [item(9, days: 0.5)] + list.filter { $0.number != 3 }
        let diff = BrowseDiff.between(current: list, fetched: fetched, order: .updated)
        #expect(diff.added.map(\.number) == [9])
        #expect(diff.removed.map(\.number) == [3])
        #expect(diff.moved.isEmpty)
        #expect(diff.summary == "1 new, 1 gone")
        #expect(diff.bannerText == "1 new \u{B7} 1 gone")
        #expect(diff.target.map(\.number) == [9, 1, 2, 4])
    }

    @Test func `one row that jumps is one move, not many`() {
        var changed = list
        changed[3].updatedAt = now.addingTimeInterval(-3600)
        let diff = BrowseDiff.between(current: list, fetched: changed, order: .updated)
        #expect(diff.moved.count == 1)
    }

    @Test func `a reversed list moves all but one`() {
        let diff = BrowseDiff.between(current: list, fetched: list, order: .oldest)
        #expect(diff.moved.count == 3)
        #expect(diff.target.map(\.number) == [4, 3, 2, 1])
    }

    @Test func `the sort decides what moved`() {
        var counts = list
        counts[3].comments = 50 // the oldest one has the most comments
        let byComments = BrowseDiff.between(current: list, fetched: counts, order: .comments)
        #expect(byComments.target.map(\.number) == [4, 1, 2, 3])
        #expect(byComments.moved == ["acme/docs#4"])
        // Sorted by update time the same change moves nothing.
        let byUpdate = BrowseDiff.between(current: list, fetched: counts, order: .updated)
        #expect(byUpdate.moved.isEmpty)
        #expect(byUpdate.updated.map(\.number) == [4])
    }

    @Test func `an id twice counts once, the last of the fetch and the first shown`() {
        var newer = item(2, "Second answer", days: 2)
        newer.comments = 3
        let fetched = list + [item(2, "First answer", days: 2), newer]
        let diff = BrowseDiff.between(current: list + [item(2, "Ignored", days: 2)], fetched: fetched, order: .updated)
        #expect(diff.target.count == 4)
        #expect(diff.updated.map(\.number) == [2])
        #expect(diff.updated.first?.comments == 3)
        #expect(diff.removed.isEmpty)
        #expect(diff.added.isEmpty)
    }

    @Test func `an empty list fills and an empty answer clears`() {
        let fill = BrowseDiff.between(current: [], fetched: list, order: .updated)
        #expect(fill.added.count == 4)
        #expect(fill.summary == "4 new")
        let clear = BrowseDiff.between(current: list, fetched: [], order: .updated)
        #expect(clear.removed.count == 4)
        #expect(clear.target.isEmpty)
        #expect(BrowseDiff.between(current: [], fetched: [], order: .updated).isEmpty)
    }

    @Test func `the longest run stays`() {
        #expect(BrowseDiff.longestIncreasing([]).isEmpty)
        #expect(BrowseDiff.longestIncreasing([0, 1, 2]) == [0, 1, 2])
        #expect(BrowseDiff.longestIncreasing([3, 0, 1, 2]) == [1, 2, 3])
        #expect(BrowseDiff.longestIncreasing([2, 1, 0]).count == 1)
    }
}
