import Foundation
@testable import HeedCore
import Testing

/// Browse keeps only what is checked out: its cache loses the items (and heed's reads of them) of orgs that are not.
@Suite(.scratch) struct BrowsePruneTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func store() throws -> BrowseStore {
        try BrowseStore(path: Scratch.folder("browse").appendingPathComponent("browse.sqlite").path)
    }

    private func item(_ org: String, _ number: Int) -> BrowseItem {
        BrowseItem(
            repo: Repo(org: org, name: "app"), number: number,
            title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            createdAt: now.addingTimeInterval(-9000), updatedAt: now.addingTimeInterval(-Double(number))
        )
    }

    private func read(_ item: BrowseItem) -> BrowseRead {
        BrowseRead(
            itemID: item.id, kind: .bug, size: .s, agentReady: 50, tldr: "t", readAt: now,
            itemUpdatedAt: item.updatedAt
        )
    }

    @Test func itemsAndReadsOutsideTheOrgsGoAndTheRestStays() async throws {
        let store = try store()
        let mine = item("acme", 1), theirs = item("initech", 2), mixed = item("GlobeX", 3)
        try await store.record([mine, theirs, mixed], now: now)
        for each in [mine, theirs, mixed] {
            try await store.save(read(each))
        }
        let removed = try await store.prune(keepingOrgs: ["ACME", "globex"])
        #expect(removed == 1)
        #expect(try await store.items(now: now).map(\.number).sorted() == [1, 3])
        #expect(try await store.reads(now: now).keys.sorted() == [mine.id, mixed.id].sorted())
    }

    @Test func savedQueriesAndPinnedScopesAreNeverTouched() async throws {
        let store = try store()
        try await store.save(SavedQuery(id: "q", name: "Bugs", query: BrowseQuery(tokens: [.label(.any, ["bug"])])))
        try await store.pin(.org("initech"))
        try await store.setLast(BrowseLast(scope: .org("initech"), query: BrowseQuery()))
        try await store.record([item("initech", 1)], now: now)
        try await store.prune(keepingOrgs: ["acme"])
        #expect(try await store.savedQueries().count == 1)
        #expect(try await store.scopes() == [.org("initech")])
        #expect(try await store.last() != nil)
        #expect(try await store.items(now: now).isEmpty)
    }

    @Test func runningItTwiceRemovesNothingTheSecondTime() async throws {
        let store = try store()
        try await store.record([item("acme", 1), item("initech", 2)], now: now)
        #expect(try await store.prune(keepingOrgs: ["acme"]) == 1)
        #expect(try await store.prune(keepingOrgs: ["acme"]) == 0)
        #expect(try await store.items(now: now).count == 1)
    }

    @Test func noOrgsDeletesNothing() async throws {
        let store = try store()
        try await store.record([item("acme", 1)], now: now)
        #expect(try await store.prune(keepingOrgs: []) == 0)
        #expect(try await store.prune(keepingOrgs: [""]) == 0)
        #expect(try await store.items(now: now).count == 1)
    }

    @Test func aCacheLargerThanOneBatchIsClearedAcrossBatches() async throws {
        let store = try store()
        let count = BrowseStore.pruneBatch * 2 + 1
        try await store.record((1 ... count).map { item("initech", $0) } + [item("acme", 9999)], now: now)
        #expect(try await store.prune(keepingOrgs: ["acme"]) == count)
        #expect(try await store.items(now: now).map(\.number) == [9999])
    }
}
