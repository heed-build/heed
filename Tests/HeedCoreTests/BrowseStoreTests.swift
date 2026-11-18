import Foundation
@testable import HeedCore
import Testing

@Suite(.scratch) struct BrowseStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func store() throws -> (BrowseStore, URL) {
        let file = try Scratch.folder("browse").appendingPathComponent("browse.sqlite")
        return try (BrowseStore(path: file.path), file)
    }

    private func item(_ number: Int, updated: Double = 0) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            labels: ["bug"], comments: number, createdAt: now.addingTimeInterval(-9000),
            updatedAt: now.addingTimeInterval(-updated)
        )
    }

    @Test func itemsComeBackNewestFirstAndAReplacedOneKeepsOneRow() async throws {
        let (store, _) = try store()
        try await store.record([item(1, updated: 300), item(2, updated: 100)], now: now)
        try await store.record([item(1, updated: 10)], now: now)
        let back = try await store.items(now: now)
        #expect(back.map(\.number) == [1, 2])
        #expect(back[0].labels == ["bug"] && back[0].title.display == "Item 1")
    }

    @Test func aRowThatNoLongerDecodesIsSkipped() async throws {
        let (store, file) = try store()
        try await store.record([item(1), item(2, updated: 50)], now: now)
        let raw = try SQLiteDatabase(path: file.path)
        try raw.run("UPDATE items SET item = '{\"kind\": \"gone\"}' WHERE id = 'acme/docs#2'")
        let back = try await store.items(now: now)
        #expect(back.map(\.number) == [1])
    }

    @Test func pruningDropsWhatWasFetchedLongAgo() async throws {
        let (store, _) = try store()
        try await store.record([item(1)], now: now.addingTimeInterval(-40 * 86400))
        try await store.record([item(2)], now: now)
        try await store.prune(now: now)
        #expect(try await store.items(now: now.addingTimeInterval(-39 * 86400)).map(\.number) == [2])
    }

    @Test func savedQueriesKeepTheirOrderAndAreReplacedInPlace() async throws {
        let (store, _) = try store()
        let bugs = SavedQuery(id: "q1", name: "Bugs", query: BrowseQuery(tokens: [.label(.any, ["bug"])]))
        let mine = SavedQuery(id: "q2", name: "Mine", query: BrowseQuery(tokens: [.assignee("@me")]))
        try await store.save(bugs)
        try await store.save(mine)
        var renamed = bugs
        renamed.name = "Bugs nobody touched"
        try await store.save(renamed)
        #expect(try await store.savedQueries().map(\.name) == ["Bugs nobody touched", "Mine"])
        try await store.removeQuery(id: "q1")
        #expect(try await store.savedQueries().map(\.id) == ["q2"])
    }

    @Test func whereYouWereSurvivesReopening() async throws {
        let (store, file) = try store()
        #expect(try await store.last() == nil)
        let last = BrowseLast(scope: .org("acme"), query: BrowseQuery(tokens: [.state(.open)], showOlder: true))
        try await store.setLast(last)
        let reopened = try BrowseStore(path: file.path)
        #expect(try await reopened.last() == last)
    }
}

struct BrowseFetchTests {
    private let answer = """
    {"data": {"search": {"issueCount": 47, "pageInfo": {"hasNextPage": true, "endCursor": "c1"}, "nodes": [
      {"number": 2830, "title": "Anchors lost", "url": "https://github.com/acme/docs-toolkit/issues/2830",
       "state": "OPEN", "createdAt": "2033-05-01T10:00:00Z", "updatedAt": "2033-05-15T10:00:00Z",
       "authorAssociation": "MEMBER", "repository": {"nameWithOwner": "acme/docs-toolkit"},
       "author": {"login": "mara-k", "__typename": "User"},
       "labels": {"nodes": [{"name": "bug"}]}, "assignees": {"nodes": [{"login": "jdoe"}]},
       "milestone": {"title": "3.2"}, "comments": {"totalCount": 6},
       "projectItems": {"nodes": [{"project": {"title": "Docs 2.0 board"}}]},
       "closedByPullRequestsReferences": {"totalCount": 1}},
      {"number": 412, "title": "Bump spec tests", "url": "https://github.com/acme/editor-rules/pull/412",
       "state": "MERGED", "createdAt": "2033-05-01T10:00:00Z", "updatedAt": "2033-05-15T10:00:00Z",
       "authorAssociation": "NONE", "repository": {"nameWithOwner": "acme/editor-rules"},
       "author": {"login": "dependabot[bot]", "__typename": "Bot"}, "labels": {"nodes": []},
       "assignees": {"nodes": []}, "milestone": null, "comments": {"totalCount": 1}, "projectItems": {"nodes": []},
       "isDraft": false, "reviewDecision": "APPROVED", "closingIssuesReferences": {"totalCount": 0},
       "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}},
      {}
    ]}}}
    """

    @Test func anAnswerBecomesItemsWithEverythingTheListNeeds() throws {
        let page = BrowseFetch.parse(Data(answer.utf8))
        #expect(page.total == 47 && page.next == "c1")
        #expect(page.items.count == 2)
        let issue = page.items[0]
        #expect(issue.id == "acme/docs-toolkit#2830" && issue.kind == .issue && issue.state == .open)
        #expect(issue.labels == ["bug"] && issue.assignees == ["jdoe"] && issue.milestone == "3.2")
        #expect(issue.projects == ["Docs 2.0 board"] && issue.comments == 6 && issue.hasLinkedPull)
        #expect(issue.title.author.trust == .member && issue.title.author.login == "mara-k")
        let pull = page.items[1]
        #expect(pull.kind == .pull && pull.state == .merged && pull.checks == .failing && pull.review == .approved)
        #expect(pull.authorIsBot && pull.title.author.trust == .bot && !pull.hasLinkedPull)
    }

    @Test func theSearchTextIsTheQueryNewestFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let text = BrowseFetch.searchText(BrowseQuery(scope: .org("acme")), maxAgeDays: 90, now: now)
        #expect(text == "org:acme updated:>=2033-02-17 sort:updated-desc")
    }
}

@Suite(.scratch) struct BrowseRailStoreTests {
    @Test func pinnedScopesKeepTheirOrderAndStarterQueriesSeedOnce() async throws {
        let file = try Scratch.folder("browse").appendingPathComponent("browse.sqlite")
        let store = try BrowseStore(path: file.path)
        try await store.pin(.org("acme"))
        try await store.pin(.repo(Repo(org: "acme", name: "docs")))
        try await store.pin(.org("acme"))
        #expect(try await store.scopes() == [.org("acme"), .repo(Repo(org: "acme", name: "docs"))])
        try await store.unpin(.org("acme"))
        #expect(try await store.scopes().count == 1)
        #expect(try await store.flag("starters") == false)
        try await store.setFlag("starters")
        #expect(try await store.flag("starters"))
    }

    @Test func theStartersCarryTheirGlyphs() {
        #expect(SavedQuery.starters.map(\.glyph) == [.person, .bug, .sprout, .clock])
    }

    @Test func savedQueriesCanBeRenamedReorderedAndDeleted() async throws {
        let db = try BrowseStore(path: Scratch.folder("browse").appendingPathComponent("browse.sqlite").path)
        for id in ["a", "b", "c"] {
            try await db.save(SavedQuery(
                id: id,
                name: id.uppercased(),
                glyph: .tag,
                query: BrowseQuery(tokens: [.state(.open)])
            ))
        }
        var renamed = try await db.savedQueries()[1]
        renamed.name = "Bee"
        renamed.glyph = .star
        renamed.tint = .teal
        try await db.save(renamed)
        var kept = try await db.savedQueries()
        #expect(kept.map(\.name) == ["A", "Bee", "C"] && kept[1].glyph == .star && kept[1].tint == .teal)
        try await db.reorderQueries(SavedQuery.moved(kept, id: "c", by: -2).map(\.id))
        kept = try await db.savedQueries()
        #expect(kept.map(\.id) == ["c", "a", "b"])
        try await db.removeQuery(id: "a")
        #expect(try await db.savedQueries().map(\.id) == ["c", "b"])
    }

    @Test func anOrgViewIsPinnedLikeAnyScope() async throws {
        let db = try BrowseStore(path: Scratch.folder("browse").appendingPathComponent("browse.sqlite").path)
        let view = BrowseScope.view(BrowseOrgView(
            owner: "globex",
            name: "docs",
            filters: [.language("Go")]
        ))
        try await db.pin(view)
        try await db.pin(view)
        #expect(try await db.scopes() == [view])
    }
}
