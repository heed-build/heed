import Foundation
@testable import HeedCore
import Testing

/// heed's own filters (class, size, agent-ready): applied on this Mac over the reads, never sent to GitHub.
struct BrowseLocalFilterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func item(_ number: Int, labels: [String] = ["bug"]) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            labels: labels, createdAt: now.addingTimeInterval(-9000),
            updatedAt: now.addingTimeInterval(-Double(number) * 3600)
        )
    }

    private func read(_ item: BrowseItem, _ kind: BrowseClass, _ size: BrowseSize, _ ready: Int) -> BrowseRead {
        BrowseRead(
            itemID: item.id,
            kind: kind,
            size: size,
            agentReady: ready,
            tldr: "t",
            readAt: now,
            itemUpdatedAt: item.updatedAt
        )
    }

    private var items: [BrowseItem] { (1 ... 6).map { item($0) } }

    /// 1 bug S 82, 2 bug M 64, 3 feature L 31, 4 bug S 48, 5 docs S 90; 6 is unread.
    private var reads: BrowseReads {
        let list = items
        let all = [
            read(list[0], .bug, .s, 82), read(list[1], .bug, .m, 64), read(list[2], .feature, .l, 31),
            read(list[3], .bug, .s, 48), read(list[4], .docs, .s, 90),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.itemID, $0) })
    }

    private func ids(_ tokens: [BrowseToken], reads given: BrowseReads? = nil) -> [Int] {
        BrowseFilter(query: BrowseQuery(tokens: tokens, showOlder: true), reads: given ?? reads)
            .apply(to: items, now: now).map(\.number)
    }

    @Test func classNarrowsToTheClassesNamed() {
        #expect(ids([.heedClass([.bug])]) == [1, 2, 4])
        #expect(ids([.heedClass([.feature, .docs])]) == [3, 5])
        #expect(ids([.heedClass([])]) == [])
    }

    @Test func sizeNarrowsToTheSizesNamed() {
        #expect(ids([.heedSize([.s])]) == [1, 4, 5])
        #expect(ids([.heedSize([.m, .l])]) == [2, 3])
    }

    @Test func readyKeepsThoseAtLeastAsReady() {
        #expect(ids([.heedReady(70)]) == [1, 5])
        #expect(ids([.heedReady(48)]) == [1, 2, 4, 5])
        #expect(ids([.heedReady(0)]) == [1, 2, 3, 4, 5])
        #expect(ids([.heedReady(91)]) == [])
    }

    @Test func anItemNobodyReadMatchesNoneOfThem() {
        #expect(!ids([.heedReady(0)]).contains(6))
        #expect(!ids([.heedClass(BrowseClass.allCases)]).contains(6))
        #expect(ids([.heedClass([.bug])], reads: [:]) == [])
    }

    @Test func theyCombineWithGitHubsTokensAndEachOther() {
        #expect(ids([.heedClass([.bug]), .heedReady(60), .heedSize([.s])]) == [1])
        #expect(ids([.label(.any, ["bug"]), .heedClass([.docs])]) == [5])
    }

    @Test func aStaleReadStillFilters() {
        var moved = items
        moved[0].updatedAt = now
        let filter = BrowseFilter(query: BrowseQuery(tokens: [.heedClass([.bug])], showOlder: true), reads: reads)
        #expect(filter.apply(to: moved, now: now).map(\.number).contains(1))
    }

    @Test func theyAreNotPartOfWhatGitHubIsAsked() {
        let query = BrowseQuery(
            scope: .org("acme"),
            tokens: [.state(.open), .heedReady(70), .heedClass([.bug]), .heedSize([.s]), .text("anchors")]
        )
        let text = query.rendered(maxAgeDays: 90, now: now)
        #expect(text.hasPrefix("org:acme is:open "))
        #expect(!text.contains("heed") && !text.contains("class") && !text.contains("70") && !text.contains("bug"))
        #expect(text.hasSuffix("anchors"))
        #expect(query.githubTokens == [.state(.open), .text("anchors")])
        #expect(query.localTokens == [.heedReady(70), .heedClass([.bug]), .heedSize([.s])])
        #expect(BrowseFetch.searchText(query, maxAgeDays: 90, now: now).contains("sort:updated-desc"))
        #expect(!BrowseFetch.searchText(query, maxAgeDays: 90, now: now).contains("heed"))
    }

    @Test func aSavedQueryWithThemSurvivesTheStoreAndTheStarterIsAgentReady() async throws {
        let starter = SavedQuery.agentReady
        #expect(starter.glyph == .bolt && starter.query.localTokens == [.heedReady(70)])
        let data = try JSONEncoder.heed.encode(starter)
        let back = try JSONDecoder.heed.decode(SavedQuery.self, from: data)
        #expect(back == starter)
        #expect(!SavedQuery.starters.contains { $0.id == starter.id })
    }

    @Test func countsAndFacetsFollowTheReads() {
        let query = BrowseQuery(tokens: [.heedReady(70)], showOlder: true)
        #expect(BrowseFilter.count(query, in: items, viewer: nil, maxAgeDays: 90, now: now, reads: reads) == 2)
        #expect(BrowseFilter.count(query, in: items, viewer: nil, maxAgeDays: 90, now: now) == 0)
        let facets = BrowseFacets(of: items, reads: reads)
        #expect(facets.classes == [.bug: 3, .feature: 1, .docs: 1])
        #expect(facets.sizes == [.s: 3, .m: 1, .l: 1])
        #expect(facets.read == 5 && facets.ready == 2)
    }

    @Test func theBuilderOffersThemWithCountsAndAppliesThePick() {
        let context = BrowseBuilder.Context(items: items, now: now, reads: reads)
        var builder = BrowseBuilder(base: BrowseQuery(tokens: [.state(.open)], showOlder: true), context: context)
        #expect(BrowseField.heedClass.disabledReason == nil)
        builder.open(.heedClass)
        let classes = builder.picker?.options ?? []
        #expect(classes.map(\.value) == ["bug", "feature", "docs", "question", "chore"])
        #expect(classes.map { $0.count ?? -1 } == [3, 1, 1, 0, 0])
        _ = builder.handle(KeyStroke("Space"))
        #expect(builder.preview.tokens == [.state(.open), .heedClass([.bug])])
        #expect(builder.wouldMatch.matching == 3)
        // The raw GitHub query never carries it.
        #expect(!builder.raw.contains("bug"))
        var ready = BrowseBuilder(base: BrowseQuery(tokens: [.state(.open)], showOlder: true), context: context)
        ready.open(.heedReady)
        #expect(ready.picker?.options.map(\.value) == ["90", "70", "50", "0"])
        // 82 and 90 are at 70 or more, 82, 90 and 64 at 50 or more (48 and 31 are not), and five are read.
        #expect(ready.picker?.options.map { $0.count ?? -1 } == [1, 2, 3, 5])
        _ = ready.handle(KeyStroke("Down"))
        _ = ready.handle(KeyStroke("Space"))
        #expect(ready.preview.tokens.contains(.heedReady(70)))
    }

    @Test func pastingARawQueryKeepsHeedsOwnFilters() {
        let context = BrowseBuilder.Context(items: items, now: now, reads: reads)
        var builder = BrowseBuilder(
            base: BrowseQuery(tokens: [.state(.open), .heedSize([.s])], showOlder: true),
            context: context
        )
        builder.open(.githubQuery)
        let action = builder.handle(KeyStroke("CR"))
        guard case let .apply(query) = action else { Issue.record("expected apply"); return }
        #expect(query.localTokens == [.heedSize([.s])])
    }
}
