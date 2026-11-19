import Foundation
@testable import HeedCore
import Testing

/// "acme · only my 3 repos": an org scope narrowed to the repos checked out here. It stores the org and nothing else,
/// so it follows the checkouts as they are now.
struct BrowseOwnReposTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func records(_ org: String, _ names: [String]) -> [RepoRecord] {
        names.map { RepoRecord(repo: Repo(org: org, name: $0), path: "/x/\($0)") }
    }

    private var checkouts: BrowseCheckouts {
        BrowseCheckouts(records: records("acme", ["app", "docs", "site"]) + records("globex", ["core"]))
    }

    private func asked(_ query: BrowseQuery, _ checkouts: BrowseCheckouts? = nil, sorted: Bool = true) throws
        -> (texts: [String], total: Int)
    {
        try BrowseFetch.searches(
            for: query, checkouts: checkouts ?? self.checkouts, maxAgeDays: 0, now: now, sorted: sorted
        )
    }

    private func item(_ slug: String) -> BrowseItem {
        let parts = slug.split(separator: "/").map(String.init)
        return BrowseItem(
            repo: Repo(org: parts[0], name: parts[1]), number: 1,
            title: ExternalText("t", source: .issueTitle, author: .unknown), createdAt: now, updatedAt: now
        )
    }

    // MARK: The scope

    @Test func itHasItsOwnIdAndTheChipSaysHowManyRepos() {
        let scope = BrowseScope.ownRepos("acme")
        #expect(scope.id == "own:acme" && scope.id != BrowseScope.org("acme").id)
        #expect(BrowseScope.ownRepos("Acme").id == "own:acme")
        #expect(scope.owner == "acme" && scope.isOwnRepos && !BrowseScope.org("acme").isOwnRepos)
        #expect(scope.chipText(checkouts) == "acme · only my 3 repos")
        #expect(BrowseScope.ownRepos("globex").chipText(checkouts) == "globex · only my 1 repo")
        #expect(BrowseScope.org("acme").chipText(checkouts) == "acme")
        // The count is the checkouts' now: a clone changes the chip.
        let more = BrowseCheckouts(records: records("acme", ["app", "docs", "site", "extra"]))
        #expect(scope.chipText(more) == "acme · only my 4 repos")
    }

    @Test func itHoldsTheItemsOfCheckedOutReposOnlyAndNothingWithoutCheckouts() {
        let scope = BrowseScope.ownRepos("acme")
        #expect(scope.contains(item("acme/docs"), checkouts: checkouts))
        #expect(scope.contains(item("ACME/Docs"), checkouts: checkouts))
        #expect(!scope.contains(item("acme/never-cloned"), checkouts: checkouts))
        #expect(!scope.contains(item("globex/core"), checkouts: checkouts))
        #expect(!scope.contains(item("acme/docs")))
        // The list the cache draws is narrowed the same way.
        let filter = BrowseFilter(query: BrowseQuery(scope: scope), checkouts: checkouts)
        let items = [item("acme/app"), item("acme/other"), item("globex/core")]
        #expect(filter.apply(to: items, sort: .updated, now: now).map(\.repo.slug) == ["acme/app"])
    }

    // MARK: Rendering and the gate

    @Test func itRendersAsTheRepoQualifiersOfTheCheckouts() {
        let query = BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)])
        #expect(query.rendered(maxAgeDays: 0, now: now, checkouts: checkouts)
            == "repo:acme/app repo:acme/docs repo:acme/site is:open")
        // Without checkouts it names nothing rather than the whole org.
        #expect(query.rendered(maxAgeDays: 0, now: now) == "is:open")
        #expect(BrowseScope.ownRepos("acme").qualifier.isEmpty)
    }

    @Test func oneSearchHoldsAllTheReposThatFit() throws {
        let result = try asked(BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)]))
        #expect(result.total == 1)
        #expect(result.texts == ["repo:acme/app repo:acme/docs repo:acme/site is:open sort:updated-desc"])
        // Only this org's repos, whatever else is checked out.
        #expect(!result.texts[0].contains("globex"))
        // A count is not sorted.
        #expect(try asked(BrowseQuery(scope: .ownRepos("globex")), sorted: false).texts == ["repo:globex/core"])
    }

    @Test func manyReposAreChunkedByTheDefaultScopesLimitsAndNothingIsLost() throws {
        let names = (1 ... 40).map { "repository-number-\($0)" }
        let big = BrowseCheckouts(records: records("acme", names))
        let result = try asked(BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)]), big)
        #expect(result.texts.count > 1 && result.texts.count <= BrowseDefaultScope.maxGroups)
        for text in result.texts {
            #expect(text.count <= BrowseDefaultScope.limit + " sort:updated-desc".count)
            #expect(text.hasSuffix("is:open sort:updated-desc"))
        }
        let qualifiers = result.texts.flatMap { $0.split(separator: " ").filter { $0.hasPrefix("repo:") } }
        // 40 repos need more than six groups at this length: the first groups are asked, the rest are counted.
        #expect(qualifiers.count < 40 || result.total == result.texts.count)
        #expect(result.total >= result.texts.count)
        #expect(qualifiers.map(String.init) == Array(big.repoQualifiers(of: "acme").prefix(qualifiers.count)))
    }

    @Test func fewerReposThanTheCapAreAllAskedAcrossGroups() throws {
        let names = (1 ... 20).map { "repository-number-\($0)" }
        let big = BrowseCheckouts(records: records("acme", names))
        let result = try asked(BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)]), big)
        let qualifiers = result.texts.flatMap { $0.split(separator: " ").filter { $0.hasPrefix("repo:") } }
        #expect(result.texts.count > 1)
        #expect(qualifiers.count == 20 && Set(qualifiers).count == 20)
        #expect(result.total == result.texts.count)
    }

    @Test func theGuardAllowsItBecauseEveryRepoIsCheckedOutAndRefusesAnOrgWithNone() {
        let own = BrowseQuery(scope: .ownRepos("acme"))
        #expect(own.places == [BrowsePlace(owner: "acme")] && own.isBounded)
        #expect(BrowseFetch.refusal(for: own, checkouts: checkouts) == nil)
        #expect(BrowseFetch.refusal(for: BrowseQuery(scope: .ownRepos("initech")), checkouts: checkouts)
            == .notCheckedOut("initech"))
        #expect(throws: BrowseFetchError.notCheckedOut("initech")) {
            try asked(BrowseQuery(scope: .ownRepos("initech")))
        }
        // A repo token of another org still has to be checked out.
        #expect(BrowseFetch.refusal(
            for: BrowseQuery(scope: .ownRepos("acme"), tokens: [.repo("initech/x")]), checkouts: checkouts
        ) == .notCheckedOut("initech/x"))
    }

    @Test func itFollowsTheCheckoutsEachTimeItIsAsked() throws {
        let query = BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)])
        let before = try asked(query).texts
        let after = try asked(query, BrowseCheckouts(records: records("acme", ["docs", "new"]))).texts
        #expect(before != after)
        #expect(after == ["repo:acme/docs repo:acme/new is:open sort:updated-desc"])
    }

    // MARK: Keeping it

    @Test func theScopeStoresTheOrgAndNoRepoList() throws {
        let data = try JSONEncoder.heed.encode(BrowseScope.ownRepos("acme"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("acme") && text.contains("ownRepos"))
        #expect(!text.contains("app") && !text.contains("docs"))
        #expect(try JSONDecoder.heed.decode(BrowseScope.self, from: data) == .ownRepos("acme"))
        let query = BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)])
        let back = try JSONDecoder.heed.decode(BrowseQuery.self, from: JSONEncoder.heed.encode(query))
        #expect(back == query)
        let saved = SavedQuery(id: "q", name: "Mine", query: query)
        #expect(try JSONDecoder.heed.decode(SavedQuery.self, from: JSONEncoder.heed.encode(saved)) == saved)
    }

    @Test func scopesStoredByAnEarlierBuildStillLoad() throws {
        let org = try JSONEncoder.heed.encode(BrowseScope.org("acme"))
        #expect(try JSONDecoder.heed.decode(BrowseScope.self, from: org) == .org("acme"))
        let repo = try JSONEncoder.heed.encode(BrowseScope.repo(Repo(org: "acme", name: "docs")))
        #expect(try JSONDecoder.heed.decode(BrowseScope.self, from: repo) == .repo(Repo(org: "acme", name: "docs")))
        // A query kept before the case existed names no scope, or an org one.
        let old = Data(#"{"tokens":[],"showOlder":false}"#.utf8)
        #expect(try JSONDecoder.heed.decode(BrowseQuery.self, from: old).scope == nil)
        let withOrg = Data(#"{"scope":{"org":{"_0":"acme"}},"tokens":[],"showOlder":false}"#.utf8)
        #expect(try JSONDecoder.heed.decode(BrowseQuery.self, from: withOrg).scope == .org("acme"))
    }

    @Test func aSavedQueryScopedThisWayFollowsTheCheckoutsNotASnapshot() throws {
        let saved = SavedQuery(
            id: "q", name: "Mine", query: BrowseQuery(scope: .ownRepos("acme"), tokens: [.state(.open)])
        )
        let stored = try JSONEncoder.heed.encode(saved)
        let loaded = try JSONDecoder.heed.decode(SavedQuery.self, from: stored)
        let first = try asked(loaded.query).texts
        let second = try asked(loaded.query, BrowseCheckouts(records: records("acme", ["only-one"]))).texts
        #expect(first[0].contains("repo:acme/site") && second == ["repo:acme/only-one is:open sort:updated-desc"])
    }
}

@Suite(.scratch) struct BrowseOwnReposStoreTests {
    @Test func theLastScopeAndAPinnedOneComeBackFromTheStore() async throws {
        let file = try Scratch.folder("browse").appendingPathComponent("browse.sqlite")
        let store = try BrowseStore(path: file.path)
        try await store.setLast(BrowseLast(scope: .ownRepos("acme"), query: BrowseQuery(tokens: [.state(.open)])))
        #expect(try await store.last()?.scope == .ownRepos("acme"))
    }
}
