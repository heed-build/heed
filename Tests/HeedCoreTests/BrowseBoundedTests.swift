import Foundation
@testable import HeedCore
import Testing

/// Browse works inside what is checked out and never searches all of GitHub. Found on a fresh install, where the
/// starter queries counted 579 thousand public issues.
struct BrowseBoundedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ org: String, _ name: String, host _: String? = nil) -> RepoRecord {
        RepoRecord(repo: Repo(org: org, name: name), path: "/x/\(name)")
    }

    private var checkouts: BrowseCheckouts {
        BrowseCheckouts(records: [
            record("acme", "app"), record("Acme", "docs"), record("globex", "core"), record("local", "scratch"),
        ])
    }

    private func parsed(_ text: String) -> BrowseQuery {
        BrowseQuery.parse(text, maxAgeDays: 90, now: now)
    }

    // MARK: Places

    @Test func aQueryWithNoPlaceIsUnbounded() {
        #expect(!BrowseQuery(tokens: [.state(.open)]).isBounded)
        #expect(!BrowseQuery(tokens: [.state(.open), .label(.any, ["bug"]), .raw("no:assignee")]).isBounded)
        #expect(!BrowseQuery(tokens: [.assignee("@me")]).isBounded)
        #expect(!BrowseQuery().isBounded)
        // A negated or empty qualifier names no place.
        #expect(!BrowseQuery(tokens: [.raw("-repo:a/b")]).isBounded)
        #expect(!BrowseQuery(tokens: [.raw("org:")]).isBounded)
        #expect(!BrowseQuery(tokens: [.assignee("octocat")]).isBounded)
    }

    @Test func aScopeOrAPlaceTokenIsABoundedQueryAndNamesItsOrg() {
        #expect(BrowseQuery(scope: .org("acme")).places == [BrowsePlace(owner: "acme")])
        #expect(BrowseQuery(scope: .repo(Repo(org: "acme", name: "app"))).places == [BrowsePlace(
            owner: "acme",
            repo: "acme/app"
        )])
        #expect(BrowseQuery(scope: .project(owner: "acme", number: 1, title: "B"))
            .places == [BrowsePlace(owner: "acme")])
        #expect(BrowseQuery(tokens: [.repo("acme/app")]).isBounded)
        #expect(BrowseQuery(tokens: [.project("acme/1")]).places == [BrowsePlace(owner: "acme")])
        for word in ["user:octocat", "org:acme", "project:acme/3", "repo:acme/app"] {
            #expect(parsed("is:open \(word)").isBounded, "\(word)")
        }
        #expect(parsed("repo:acme/app").places == [BrowsePlace(owner: "acme", repo: "acme/app")])
    }

    @Test func theStarterQueriesNameNoPlace() {
        #expect(SavedQuery.starters.allSatisfy { !$0.query.isBounded })
        #expect(!SavedQuery.agentReady.query.isBounded)
    }

    // MARK: Checkouts

    @Test func checkoutsAreTheOrgsOfTheRecordsMostReposFirstIgnoringCase() {
        #expect(checkouts.orgNames == ["acme", "globex"])
        #expect(checkouts.org("ACME")?.repos.map(\.name) == ["app", "docs"])
        #expect(checkouts.contains(org: "Globex") && !checkouts.contains(org: "initech") && !checkouts
            .contains(org: "local"))
        #expect(BrowseCheckouts(records: []).isEmpty)
        #expect(checkouts.qualifiers == ["org:acme", "org:globex"])
        #expect(checkouts.repoQualifiers(of: "acme") == ["repo:acme/app", "repo:Acme/docs"])
    }

    @Test func aRepoOfACheckedOutOrgIsAllowedAndAnotherOrgIsNot() {
        #expect(checkouts.allows(BrowsePlace(owner: "acme", repo: "acme/never-cloned")))
        #expect(!checkouts.allows(BrowsePlace(owner: "initech", repo: "initech/app")))
    }

    // MARK: The gate

    @Test func theGateAnswersWhatWouldBeAsked() throws {
        let starter = SavedQuery.starters[2].query
        let all = try BrowseFetch.searches(for: starter, checkouts: checkouts, maxAgeDays: 90, now: now, sorted: true)
        #expect(all.texts.count == 1)
        #expect(all.texts[0].hasPrefix("org:acme org:globex "))
        #expect(all.texts[0].hasSuffix("sort:updated-desc"))
        // Assigned to me runs inside the checkouts too.
        let assigned = try BrowseFetch.searches(
            for: SavedQuery.starters[0].query, checkouts: checkouts, maxAgeDays: 90, now: now, sorted: false
        )
        #expect(assigned.texts[0].hasPrefix("org:acme org:globex ") && assigned.texts[0].contains("assignee:@me"))
        // Its own scope: as it stands, and the default never joins it.
        var scoped = starter
        scoped.scope = .org("globex")
        let own = try BrowseFetch.searches(for: scoped, checkouts: checkouts, maxAgeDays: 90, now: now, sorted: false)
        #expect(own.texts.count == 1 && own.texts[0].hasPrefix("org:globex ") && !own.texts[0].contains("acme"))
        // A place token of its own: no scope is added.
        let typed = try BrowseFetch.searches(
            for: parsed("is:open repo:acme/app"), checkouts: checkouts, maxAgeDays: 90, now: now, sorted: false
        )
        #expect(typed.texts.count == 1 && !typed.texts[0].contains("org:"))
    }

    @Test func anOrgWithNoCheckoutIsRefusedByName() {
        var other = SavedQuery.starters[2].query
        other.scope = .org("initech")
        #expect(throws: BrowseFetchError.notCheckedOut("initech")) {
            try BrowseFetch.searches(for: other, checkouts: checkouts, maxAgeDays: 90, now: now, sorted: true)
        }
        #expect(throws: BrowseFetchError.notCheckedOut("initech/app")) {
            try BrowseFetch.searches(
                for: parsed("is:open repo:initech/app"), checkouts: checkouts, maxAgeDays: 90, now: now, sorted: true
            )
        }
        // One checked-out org does not make another one allowed.
        #expect(throws: BrowseFetchError.notCheckedOut("initech")) {
            try BrowseFetch.searches(
                for: parsed("org:acme org:initech"), checkouts: checkouts, maxAgeDays: 90, now: now, sorted: true
            )
        }
        #expect(BrowseFetchError.notCheckedOut("initech/app").description.contains("initech/app isn't checked out"))
    }

    /// Every public entry point that takes a query: nothing reaches `gh` (so this needs no network).
    @Test func everyFetchEntryPointRefusesWhatIsNotCheckedOut() async {
        let starter = SavedQuery.starters[2].query
        let none = BrowseCheckouts(records: [])
        var other = starter
        other.scope = .repo(Repo(org: "initech", name: "app"))
        await #expect(throws: BrowseFetchError.unbounded) {
            _ = try await BrowseFetch.search(starter, maxAgeDays: 90, checkouts: none)
        }
        await #expect(throws: BrowseFetchError.unbounded) {
            _ = try await BrowseFetch.count(starter, maxAgeDays: 90, checkouts: none)
        }
        await #expect(throws: BrowseFetchError.notCheckedOut("initech/app")) {
            _ = try await BrowseFetch.search(other, maxAgeDays: 90, checkouts: checkouts)
        }
        await #expect(throws: BrowseFetchError.notCheckedOut("initech/app")) {
            _ = try await BrowseFetch.count(other, maxAgeDays: 90, checkouts: checkouts)
        }
        await #expect(throws: BrowseFetchError.notCheckedOut("initech")) {
            _ = try await BrowseFetch.search(parsed("org:initech"), maxAgeDays: 0, checkouts: none)
        }
    }

    // MARK: Chunks and merge

    @Test func theGroupsAreSplitToFitAndHoldEveryQualifierOnce() {
        let orgs = (1 ... 14).map { "org:organisation-number-\($0)" }
        let rest = "is:open label:bug sort:updated-desc"
        let plan = BrowseDefaultScope.plan(orgs, rest: rest)
        #expect(plan.groups.count > 1 && !plan.omitted)
        for group in plan.groups {
            #expect(BrowseDefaultScope.text(group, rest: rest).count <= 240)
        }
        #expect(plan.groups.flatMap { $0 } == orgs)
    }

    @Test func aGroupFillsToTheLimitExactly() {
        // "org:a" is 5 characters plus a space: with a 14 character rest, 3 x 6 + 14 = 32 fits, one less does not.
        let qualifiers = ["org:a", "org:b", "org:c"]
        let rest = String(repeating: "x", count: 14)
        #expect(BrowseDefaultScope.plan(qualifiers, rest: rest, limit: 32).groups.map(\.count) == [3])
        #expect(BrowseDefaultScope.plan(qualifiers, rest: rest, limit: 31).groups.map(\.count) == [2, 1])
    }

    @Test func tooManyOrgsKeepTheFirstGroupsAndSayHowManyWereNeeded() {
        let orgs = (1 ... 80).map { "org:organisation-number-\($0)" }
        let plan = BrowseDefaultScope.plan(orgs, rest: "is:open")
        #expect(plan.groups.count == BrowseDefaultScope.maxGroups)
        #expect(plan.omitted && plan.totalGroups > plan.groups.count)
    }

    private func item(_ number: Int, ago: Double, org: String = "acme") -> BrowseItem {
        BrowseItem(
            repo: Repo(org: org, name: "app"), number: number,
            title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            createdAt: now.addingTimeInterval(-90000), updatedAt: now.addingTimeInterval(-ago)
        )
    }

    @Test func theGroupsMergeNewestFirstWithTheirCountsAddedAndTheCapOnTheWhole() {
        var one = BrowseFetch.Result()
        one.items = [item(1, ago: 300), item(2, ago: 100)]
        one.total = 40
        var two = BrowseFetch.Result()
        two.items = [item(3, ago: 200), item(4, ago: 50, org: "globex")]
        two.total = 2
        two.hidden = 1
        let merged = BrowseFetch.merge([one, two], cap: 3, now: now)
        #expect(merged.items.map(\.number) == [4, 2, 3])
        #expect(merged.total == 42 && merged.hidden == 1)
        #expect(merged.capped)
        #expect(!BrowseFetch.merge([one, two], cap: 10, now: now).capped)
    }
}
