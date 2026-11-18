import Foundation
@testable import HeedCore
import Testing

struct BrowseQueryTests {
    /// 2033-05-18T03:33:20Z.
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func rendered(_ query: BrowseQuery, days: Int = 90) -> String { query.rendered(maxAgeDays: days, now: now) }

    @Test func tokensRenderAsGitHubQualifiers() {
        let query = BrowseQuery(scope: .org("acme"), tokens: [
            .type(.issues), .state(.open), .label(.any, ["bug", "good first issue"]), .label(.none, ["wontfix"]),
            .assignee("@me"), .milestone("3.2"), .linkedPull(false), .text("anchors lost"),
        ])
        #expect(rendered(query) == "org:acme is:issue is:open label:bug,\"good first issue\" -label:wontfix "
            + "assignee:@me milestone:3.2 -linked:pr updated:>=2033-02-17 anchors lost")
    }

    @Test func allLabelsAreOneQualifierEach() {
        let query = BrowseQuery(tokens: [.label(.all, ["bug", "perf"])], showOlder: true)
        #expect(rendered(query) == "label:bug label:perf")
    }

    @Test func theThreeMonthCapIsTheDefaultAndShowOlderLiftsIt() {
        let query = BrowseQuery(scope: .repo(Repo(org: "acme", name: "docs")))
        #expect(rendered(query, days: 90) == "repo:acme/docs updated:>=2033-02-17")
        var older = query
        older.showOlder = true
        #expect(rendered(older) == "repo:acme/docs")
        #expect(rendered(query, days: 0) == "repo:acme/docs")
    }

    @Test func aQueryWithItsOwnActivityIsNotCapped() {
        let query = BrowseQuery(tokens: [.activity(.olderThan(30))])
        #expect(rendered(query) == "updated:<2033-04-18")
    }

    @Test func projectScopeUsesTheBoardNumber() {
        let scope = BrowseScope.project(owner: "acme", number: 7, title: "Docs 2.0 board")
        #expect(rendered(BrowseQuery(scope: scope, showOlder: true)) == "project:acme/7")
    }

    @Test func aRenderedQueryParsesBack() {
        let queries = [
            BrowseQuery(tokens: [.type(.pulls), .state(.merged), .author("mara-k"), .repo("acme/docs")]),
            BrowseQuery(tokens: [.label(.any, ["bug", "good first issue"]), .label(.none, ["wontfix"])]),
            BrowseQuery(tokens: [.label(.all, ["bug", "perf"]), .linkedPull(true), .text("redirect loop")]),
            BrowseQuery(tokens: [.created(.newerThan(14)), .org("acme"), .project("acme/7")], showOlder: true),
            BrowseQuery(tokens: [.activity(.olderThan(30)), .language("Go"), .raw("sort:updated-asc")]),
            BrowseQuery(tokens: [.milestone("3.2 beta"), .assignee("@me")], showOlder: true),
        ]
        for query in queries {
            let text = rendered(query)
            #expect(BrowseQuery.parse(text, maxAgeDays: 90, now: now) == query, "\(text)")
        }
    }

    @Test func aPastedStringKeepsWhatHeedDoesNotModel() {
        let query = BrowseQuery.parse(
            "is:issue language:C# in:title team:acme/docs-eng retry",
            maxAgeDays: 90,
            now: now
        )
        #expect(query.tokens == [
            .type(.issues), .language("C#"), .raw("in:title"), .raw("team:acme/docs-eng"), .text("retry"),
        ])
        #expect(query.showOlder)
    }

    @Test func theCapDayReadsBackAsTheCapNotAToken() {
        let query = BrowseQuery.parse("is:open updated:>=2033-02-17", maxAgeDays: 90, now: now)
        #expect(query == BrowseQuery(tokens: [.state(.open)]))
        let other = BrowseQuery.parse("is:open updated:>=2033-05-01", maxAgeDays: 90, now: now)
        #expect(other.tokens == [.state(.open), .activity(.newerThan(17))])
    }
}

struct BrowseGuidanceTests {
    @Test func anOrgOverTheThresholdIsOfferedAnOrgViewFirst() {
        #expect(BrowseGuidance.advice(repoCount: 38) == .browse)
        #expect(BrowseGuidance.advice(repoCount: 200) == .browse)
        #expect(BrowseGuidance.advice(repoCount: 1240) == .createOrgView(repos: 1240))
        #expect(BrowseGuidance.advice(repoCount: 50, threshold: 40) == .createOrgView(repos: 50))
        #expect(BrowseGuidance.advice(repoCount: 5000, threshold: 0) == .browse)
    }
}

struct BrowseGlyphTests {
    private func glyph(_ tokens: [BrowseToken]) -> BrowseGlyph { BrowseGlyph.pick(for: BrowseQuery(tokens: tokens)) }

    @Test func theDominantFilterPicksTheGlyph() {
        #expect(glyph([.label(.any, ["bug"]), .state(.open)]) == .bug)
        #expect(glyph([.label(.any, ["good first issue"])]) == .sprout)
        #expect(glyph([.label(.any, ["enhancement"])]) == .star)
        #expect(glyph([.activity(.olderThan(30))]) == .clock)
        #expect(glyph([.milestone("3.2")]) == .flag)
        #expect(glyph([.assignee("@me")]) == .person)
        #expect(glyph([.type(.pulls)]) == .pull)
        #expect(glyph([.label(.any, ["docs"])]) == .tag)
        #expect(glyph([.state(.open)]) == .list)
        // A label a query excludes does not name it.
        #expect(glyph([.label(.none, ["bug"])]) == .tag)
    }

    @Test func aSavedQueryTakesTheAutoPickedGlyphAndTintUnlessOverridden() {
        let query = BrowseQuery(tokens: [.label(.any, ["bug"])])
        let saved = SavedQuery(id: "q1", name: "Bugs", query: query)
        #expect(saved.glyph == .bug && saved.tint == .red)
        let own = SavedQuery(id: "q2", name: "Bugs", glyph: .bolt, tint: .blue, query: query)
        #expect(own.glyph == .bolt && own.tint == .blue)
    }
}
