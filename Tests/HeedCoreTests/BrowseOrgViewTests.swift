import Foundation
@testable import HeedCore
import Testing

struct BrowseOrgViewTests {
    private let infos = [
        BrowseRepoInfo(slug: "globex/glossary", language: "C#", topics: ["docs"]),
        BrowseRepoInfo(slug: "globex/glass-api", language: "Go", topics: ["api", "docs"]),
        BrowseRepoInfo(slug: "globex/old-site", language: "C#", topics: ["docs"], isArchived: true),
        BrowseRepoInfo(slug: "globex/infra", language: "HCL", topics: []),
    ]

    @Test func filtersAreAndAcrossFieldsOrWithinOneAndArchivedIsHiddenByDefault() {
        #expect(BrowseOrgViews.repos(matching: [], in: infos) == [
            "globex/glass-api",
            "globex/glossary",
            "globex/infra",
        ])
        #expect(BrowseOrgViews.repos(matching: [.topic("docs")], in: infos) == ["globex/glass-api", "globex/glossary"])
        #expect(BrowseOrgViews.repos(matching: [.topic("docs"), .language("C#")], in: infos) == ["globex/glossary"])
        #expect(BrowseOrgViews.repos(matching: [.language("C#"), .language("Go")], in: infos).count == 2)
        #expect(BrowseOrgViews.repos(matching: [.archived(true)], in: infos) == ["globex/old-site"])
    }

    @Test func aTeamKeepsItsReposOnceTheyAreLoadedAndNothingBefore() {
        let filters: [BrowseToken] = [.team("docs-eng")]
        #expect(BrowseOrgViews.repos(matching: filters, in: infos).isEmpty)
        let teams = ["docs-eng": BrowseRepoInfo.teamRepos("globex/glossary\nGlobex/Infra\n")]
        #expect(BrowseOrgViews.repos(matching: filters, in: infos, teams: teams) == ["globex/glossary", "globex/infra"])
    }

    @Test func aViewRendersRepoQualifiersAndSplitsToFitGitHubsSearchLength() {
        let repos = (1 ... 30).map { "globex/service-number-\($0)" }
        let query = BrowseQuery(
            scope: .view(BrowseOrgView(owner: "globex", name: "svc", repos: repos)),
            tokens: [.state(.open), .label(.any, ["bug"])],
            showOlder: true
        )
        let searches = query.renderedSearches(maxAgeDays: 90, now: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(searches.count > 1)
        for search in searches {
            #expect(search.count + " sort:updated-desc".count <= BrowseQuery.searchLimit)
            #expect(search.hasSuffix("is:open label:bug"))
        }
        let named = searches.flatMap { $0.split(separator: " ").filter { $0.hasPrefix("repo:") } }
        #expect(named.count == 30 && Set(named).count == 30)
    }

    @Test func aWholeOrgViewIsOneOrgSearchAndAnEmptyOneSearchesNothing() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let whole = BrowseQuery(
            scope: .view(BrowseOrgView(owner: "globex", name: "all")),
            tokens: [.state(.open)],
            showOlder: true
        )
        #expect(whole.renderedSearches(maxAgeDays: 90, now: now) == ["org:globex is:open"])
        let none = BrowseQuery(scope: .view(BrowseOrgView(owner: "globex", name: "x", repos: [])), showOlder: true)
        #expect(none.renderedSearches(maxAgeDays: 90, now: now).isEmpty)
    }

    @Test func aViewScopeContainsItsReposAndSurvivesTheStore() throws {
        let view = BrowseScope.view(BrowseOrgView(
            owner: "globex",
            name: "docs",
            filters: [.topic("docs")],
            repos: ["globex/glossary"]
        ))
        let item = BrowseItem(
            repo: Repo(org: "globex", name: "glossary"),
            number: 1,
            title: ExternalText("t", source: .issueTitle, author: .unknown)
        )
        let other = BrowseItem(
            repo: Repo(org: "globex", name: "infra"),
            number: 2,
            title: ExternalText("t", source: .issueTitle, author: .unknown)
        )
        #expect(view.contains(item) && !view.contains(other))
        let back = try JSONDecoder.heed.decode(BrowseScope.self, from: JSONEncoder.heed.encode(view))
        #expect(back == view && back.id == "view:globex/docs")
    }

    @Test func repoListsParseFromGh() {
        let json = #"[{"nameWithOwner":"globex/glossary","primaryLanguage":{"name":"C#"},"repositoryTopics":[{"name":"docs"}],"isArchived":false},{"nameWithOwner":"globex/x","primaryLanguage":null,"repositoryTopics":null,"isArchived":true}]"#
        let parsed = BrowseRepoInfo.parse(Data(json.utf8))
        #expect(parsed == [
            BrowseRepoInfo(slug: "globex/glossary", language: "C#", topics: ["docs"]),
            BrowseRepoInfo(slug: "globex/x", language: nil, topics: [], isArchived: true),
        ])
    }

    @Test func theBuilderCountsLiveAndCreatesTheView() {
        var builder = BrowseOrgBuilder(owner: "globex", infos: infos, teams: ["docs-eng"])
        #expect(builder.repos.count == 3)
        _ = builder.handle(KeyStroke("CR")) // Topic
        _ = builder.handle(KeyStroke("Space")) // docs is the most common
        #expect(builder.handle(KeyStroke("CR")) == .changed)
        #expect(builder.repos == ["globex/glass-api", "globex/glossary"])
        for _ in 0 ..< 4 {
            _ = builder.handle(KeyStroke("Down"))
        }
        #expect(builder.onCreate)
        guard case let .create(view) = builder.handle(KeyStroke("CR")) else { Issue.record("not created"); return }
        #expect(view.name == "docs" && view.filters == [.topic("docs")] && view.repos?.count == 2)
    }

    @Test func aViewThatKeepsNoRepoIsNotCreatedAndATeamAsksForItsRepos() {
        var builder = BrowseOrgBuilder(owner: "globex", infos: infos, teams: ["docs-eng"])
        _ = builder.handle(KeyStroke("Down")) // Team
        _ = builder.handle(KeyStroke("CR"))
        _ = builder.handle(KeyStroke("Space"))
        #expect(builder.handle(KeyStroke("CR")) == .loadTeam("docs-eng"))
        #expect(builder.repos.isEmpty)
        for _ in 0 ..< 4 {
            _ = builder.handle(KeyStroke("Down"))
        }
        #expect(builder.handle(KeyStroke("CR")) == .none)
    }
}
