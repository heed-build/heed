import Foundation
@testable import HeedCore
import Testing

struct BrowseOrgViewTests {
    private let infos = [
        BrowseRepoInfo(slug: "globex/glossary", language: "C#"),
        BrowseRepoInfo(slug: "globex/glass-api", language: "Go"),
        BrowseRepoInfo(slug: "globex/old-site", language: "C#", isArchived: true),
        BrowseRepoInfo(slug: "globex/infra", language: "HCL"),
    ]

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func theLiveCountFollowsLanguageAndArchivedAndHidesArchivedByDefault() {
        #expect(BrowseOrgViews.repos(matching: [], in: infos) == [
            "globex/glass-api",
            "globex/glossary",
            "globex/infra",
        ])
        #expect(BrowseOrgViews.repos(matching: [.language("c#")], in: infos) == ["globex/glossary"])
        #expect(BrowseOrgViews.repos(matching: [.archived(true)], in: infos) == ["globex/old-site"])
        #expect(BrowseOrgViews.repos(matching: [.archived(true), .language("Go")], in: infos).isEmpty)
    }

    @Test func aViewIsOnlyQualifiersGitHubEvaluatesAndNamesNoRepo() {
        let plain = BrowseOrgView(owner: "globex", name: "all")
        #expect(plain.qualifier == "org:globex archived:false")
        let csharp = BrowseOrgView(owner: "globex", name: "C#", filters: [.language("C#"), .archived(false)])
        #expect(csharp.qualifier == "org:globex language:C# archived:false")
        let old = BrowseOrgView(owner: "globex", name: "x", filters: [.archived(true)])
        #expect(old.qualifier == "org:globex archived:true")
        let query = BrowseQuery(scope: .view(csharp), tokens: [.state(.open)], showOlder: true)
        let text = query.rendered(maxAgeDays: 90, now: now)
        #expect(text == "org:globex language:C# archived:false is:open")
        #expect(!text.contains("repo:"))
    }

    @Test func aViewKeepsOneLanguage() {
        let view = BrowseOrgView(owner: "globex", name: "x", filters: [.language("Go"), .language("C#")])
        #expect(view.filters == [.language("Go")] && view.qualifier == "org:globex language:Go archived:false")
    }

    @Test func aViewScopeContainsItsOrgAndSurvivesTheStore() throws {
        let view = BrowseScope.view(BrowseOrgView(owner: "globex", name: "docs", filters: [.language("C#")]))
        let item = BrowseItem(
            repo: Repo(org: "globex", name: "glossary"), number: 1,
            title: ExternalText("t", source: .issueTitle, author: .unknown)
        )
        let other = BrowseItem(
            repo: Repo(org: "initech", name: "infra"), number: 2,
            title: ExternalText("t", source: .issueTitle, author: .unknown)
        )
        #expect(view.contains(item) && !view.contains(other))
        let back = try JSONDecoder.heed.decode(BrowseScope.self, from: JSONEncoder.heed.encode(view))
        #expect(back == view && back.id == "view:globex/docs")
    }

    @Test func aViewStoredWithTopicsTeamsAndReposStillLoadsWithoutThem() throws {
        // The shape the current build writes, so the old one below is the same shape and not a guess.
        let language = try String(decoding: JSONEncoder.heed.encode(BrowseToken.language("C#")), as: UTF8.self)
        #expect(language == #"{"language":{"_0":"C#"}}"#)
        let old = #"""
        {"view":{"_0":{"owner":"globex","name":"docs","repos":["globex/a","globex/b"],
        "filters":[{"topic":{"_0":"docs"}},{"team":{"_0":"docs-eng"}},{"language":{"_0":"C#"}},{"archived":{"_0":true}}]}}}
        """#
        let scope = try JSONDecoder.heed.decode(BrowseScope.self, from: Data(old.utf8))
        guard case let .view(view) = scope else { Issue.record("not a view"); return }
        #expect(view.filters == [.language("C#"), .archived(true)])
        #expect(view.qualifier == "org:globex language:C# archived:true")
    }

    @Test func aSavedQueryStoredWithATopicLoadsWithTheRestKept() throws {
        let old = #"""
        {"tokens":[{"topic":{"_0":"docs"}},{"state":{"_0":"open"}},{"team":{"_0":"x/y"}}],"showOlder":true}
        """#
        let query = try JSONDecoder.heed.decode(BrowseQuery.self, from: Data(old.utf8))
        #expect(query.tokens == [.state(.open)] && query.showOlder && query.scope == nil)
    }

    @Test func repoListsParseFromGhWithoutTopics() {
        let json = #"[{"nameWithOwner":"globex/glossary","primaryLanguage":{"name":"C#"},"isArchived":false},{"nameWithOwner":"globex/x","primaryLanguage":null,"isArchived":true}]"#
        #expect(BrowseRepoInfo.parse(Data(json.utf8)) == [
            BrowseRepoInfo(slug: "globex/glossary", language: "C#"),
            BrowseRepoInfo(slug: "globex/x", language: nil, isArchived: true),
        ])
        #expect(BrowseRepoInfo.listArguments(owner: "globex").last == "nameWithOwner,primaryLanguage,isArchived")
    }

    @Test func theBuilderCountsLiveAndCreatesAViewThatStoresNoRepos() {
        var builder = BrowseOrgBuilder(owner: "globex", infos: infos)
        #expect(builder.repos.count == 3)
        _ = builder.handle(KeyStroke("CR")) // Language
        _ = builder.handle(KeyStroke("Down")) // past "any language"
        #expect(builder.handle(KeyStroke("CR")) == .changed) // C# (two repos, one archived: one live)
        #expect(builder.repos == ["globex/glossary"])
        for _ in 0 ..< 3 {
            _ = builder.handle(KeyStroke("Down"))
        }
        #expect(builder.onCreate)
        guard case let .create(view) = builder.handle(KeyStroke("CR")) else { Issue.record("not created"); return }
        #expect(view.name == "C#" && view.filters == [.language("C#")])
        #expect(view.qualifier == "org:globex language:C# archived:false")
    }

    @Test func aViewThatKeepsNoRepoIsNotCreatedAndAnyLanguageClearsTheFilter() {
        var builder = BrowseOrgBuilder(owner: "globex", infos: infos, filters: [.language("Rust")])
        #expect(builder.repos.isEmpty)
        for _ in 0 ..< 2 {
            _ = builder.handle(KeyStroke("Down"))
        }
        #expect(builder.handle(KeyStroke("CR")) == .none)
        _ = builder.handle(KeyStroke("Up"))
        _ = builder.handle(KeyStroke("Up"))
        _ = builder.handle(KeyStroke("CR")) // Language picker, cursor on "any language"
        _ = builder.handle(KeyStroke("CR"))
        #expect(builder.filters.isEmpty && builder.repos.count == 3)
    }
}
