import Foundation
import Testing
@testable import HeedCore

struct BrowseFilterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")
    private let ingest = Repo(org: "acme", name: "ingest")
    private let other = Repo(org: "globex", name: "glossary")
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    private func item(
        _ repo: Repo, _ number: Int, _ title: String, kind: BrowseItem.Kind = .issue, labels: [String] = [],
        assignees: [String] = [], author: String = "mara-k", days: Double = 1, comments: Int = 0,
        milestone: String? = nil, linked: Bool = false
    ) -> BrowseItem {
        BrowseItem(
            repo: repo, number: number, kind: kind, title: ExternalText(title, source: .issueTitle, author: .unknown),
            author: author, labels: labels, assignees: assignees, milestone: milestone, comments: comments,
            createdAt: ago(days + 5), updatedAt: ago(days), hasLinkedPull: linked
        )
    }

    private var items: [BrowseItem] {
        [
            item(docs, 1, "Anchors lost when a page is moved", labels: ["bug"], assignees: ["jdoe"], days: 3, comments: 4),
            item(docs, 2, "Redirect loop", labels: ["bug", "redirects"], days: 2, comments: 6, linked: true),
            item(ingest, 3, "Backpressure drops events", labels: ["perf"], author: "jdoe", days: 7, comments: 9),
            item(docs, 4, "Bump spec tests", kind: .pull, labels: ["chore"], days: 20),
            item(other, 5, "Old and quiet", labels: ["docs"], days: 200, milestone: "3.2"),
        ]
    }

    private func ids(_ query: BrowseQuery, sort: BrowseSort = .updated, viewer: String? = "jdoe") -> [Int] {
        BrowseFilter(query: query, viewer: viewer).apply(to: items, sort: sort, now: now).map(\.number)
    }

    @Test func eachTokenNarrows() {
        #expect(ids(BrowseQuery(tokens: [.type(.pulls)])) == [4])
        #expect(ids(BrowseQuery(tokens: [.label(.any, ["bug", "perf"])])) == [2, 1, 3])
        #expect(ids(BrowseQuery(tokens: [.label(.all, ["bug", "redirects"])])) == [2])
        #expect(ids(BrowseQuery(tokens: [.type(.issues), .label(.none, ["bug"])])) == [3])
        #expect(ids(BrowseQuery(tokens: [.assignee("@me")])) == [1])
        #expect(ids(BrowseQuery(tokens: [.author("@me")])) == [3])
        #expect(ids(BrowseQuery(tokens: [.repo("ACME/ingest")])) == [3])
        #expect(ids(BrowseQuery(tokens: [.linkedPull(true)])) == [2])
        #expect(ids(BrowseQuery(tokens: [.text("redirect")])) == [2])
        #expect(ids(BrowseQuery(tokens: [.activity(.olderThan(10))], showOlder: true)) == [4, 5])
    }

    @Test func theScopeNarrowsToItsOrgOrRepo() {
        #expect(ids(BrowseQuery(scope: .org("acme"))) == [2, 1, 3, 4])
        #expect(ids(BrowseQuery(scope: .repo(ingest))) == [3])
    }

    @Test func theCapHidesOldItemsUntilShowOlder() {
        #expect(ids(BrowseQuery(tokens: [.label(.any, ["docs"])])) == [])
        #expect(ids(BrowseQuery(tokens: [.label(.any, ["docs"])], showOlder: true)) == [5])
    }

    @Test func sortingOrdersTheResult() {
        let all = BrowseQuery(showOlder: true)
        #expect(ids(all, sort: .updated) == [2, 1, 3, 4, 5])
        #expect(ids(all, sort: .comments) == [3, 2, 1, 4, 5])
        #expect(ids(all, sort: .oldest) == [5, 4, 3, 1, 2])
        #expect(ids(all, sort: .created) == [2, 1, 3, 4, 5])
    }

    @Test func facetsCountEachField() {
        let facets = BrowseFacets(of: items)
        #expect(facets.issues == 4 && facets.pulls == 1)
        #expect(facets.repos["acme/docs"] == 3)
        #expect(facets.labels["bug"] == 2)
        #expect(facets.orgs == ["acme": 4, "globex": 1])
        #expect(BrowseFacets.ranked(facets.labels).first?.name == "bug")
        #expect(facets.milestones == ["3.2": 1])
    }

    @Test func theRailCountsAScopeOverTheCache() {
        let count = BrowseFilter.count(
            BrowseQuery(scope: .org("acme")), in: items, viewer: nil, maxAgeDays: 90, now: now
        )
        #expect(count == 4)
    }
}

struct BrowsePaletteTests {
    private func palette() -> BrowsePalette {
        BrowsePalette(
            orgs: [
                .init(name: "acme", repoCount: 38, openCount: 212),
                .init(name: "globex", repoCount: 1240),
                .init(name: "Mpdreamz", repoCount: 61, personal: true),
            ],
            listings: [
                RepoListing(repo: Repo(org: "globex", name: "glossary")),
                RepoListing(repo: Repo(org: "globex", name: "glass-api")),
                RepoListing(repo: Repo(org: "acme", name: "docs-toolkit")),
            ],
            records: [RepoRecord(repo: Repo(org: "globex", name: "glossary"), path: "/Users/you/code/glossary")]
        )
    }

    private func type(_ text: String, into palette: inout BrowsePalette) {
        for character in text { _ = palette.handle(KeyStroke(String(character))) }
    }

    @Test func typingFindsOrgsAndTheReposMatching() {
        var palette = palette()
        #expect(palette.rows.count == 3)
        type("gl", into: &palette)
        let names = palette.rows.map { row -> String in
            switch row {
            case let .org(org): org.name
            case let .repo(repo): repo.listing.repo.slug
            }
        }
        #expect(names == ["globex", "globex/glossary", "globex/glass-api"])
        guard case let .repo(glossary) = palette.rows[1], case let .repo(api) = palette.rows[2] else {
            Issue.record("expected repos")
            return
        }
        #expect(glossary.place.clones == false && api.place == .notCloned)
    }

    @Test func aBigOrgIsOfferedAViewInsteadOfBeingBrowsedWhole() {
        var palette = palette()
        _ = palette.handle(KeyStroke("Down"))
        #expect(palette.guidance == .createOrgView(repos: 1240))
        #expect(palette.handle(KeyStroke("CR")) == .createOrgView("globex"))
        #expect(palette.handle(KeyStroke("b", .control)) == .choose(.org("globex")))
        _ = palette.handle(KeyStroke("Up"))
        #expect(palette.guidance == .browse)
        #expect(palette.handle(KeyStroke("CR")) == .choose(.org("acme")))
    }

    @Test func enterOnARepoChoosesIt() {
        var palette = palette()
        type("glos", into: &palette)
        _ = palette.handle(KeyStroke("Down"))
        #expect(palette.handle(KeyStroke("CR")) == .choose(.repo(Repo(org: "globex", name: "glossary"))))
        #expect(palette.handle(.escape) == .cancel)
    }
}
