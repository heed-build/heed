import Foundation
@testable import HeedCore
import Testing

/// Add or clone: `gh repo list` read back, each repo's place among the ones heed knows, the field narrowing the lists,
/// picking several, what ⌘↩ does, and the "then" from config.
struct AddRepoTests {
    private let records = [
        RepoRecord(repo: Repo(org: "acme", name: "docs-toolkit"), path: "/Users/you/Projects/docs-toolkit"),
        RepoRecord(repo: Repo(org: "acme", name: "ingest"), path: "/home/you/code/ingest", location: .host("devbox")),
    ]

    private func listing(_ slug: String, _ description: String = "", hours: Double, archived: Bool = false)
        -> RepoListing
    {
        RepoListing(
            repo: RepoEntry.repo(slug), description: description,
            pushedAt: Date(timeIntervalSince1970: 1e9 - hours * 3600),
            isArchived: archived
        )
    }

    private var lists: [String: AddRepoForm.ListState] {
        [
            "": .loaded([listing("you/dotfiles", hours: 30)]),
            "acme": .loaded([
                listing("acme/docs-toolkit", "builds the docs", hours: 5),
                listing("acme/anchor-lint", "lints heading ids in docs", hours: 2),
                listing("acme/ingest", hours: 70),
                listing("acme/legacy-annotator", hours: 17000, archived: true),
            ]),
            "globex": .loading,
        ]
    }

    private func form(then: AfterAdd = .setup) -> AddRepoForm {
        AddRepoForm(
            orgs: ["acme", "globex"],
            records: records,
            roots: ["~/Projects", "~/code"],
            then: then,
            lists: lists
        )
    }

    private func type(_ text: String, into form: inout AddRepoForm) {
        for character in text {
            _ = form.handle(KeyStroke(String(character)))
        }
    }

    @Test func ghRepoListIsReadNewestPushFirst() throws {
        let json = """
        [{"nameWithOwner":"acme/old","description":"","pushedAt":"2024-01-01T00:00:00Z","isPrivate":false,"isArchived":true},
         {"nameWithOwner":"acme/new","description":"fresh","pushedAt":"2026-11-01T00:00:00Z","isPrivate":true,"isArchived":false},
         {"nameWithOwner":"broken"}]
        """
        let listings = try #require(RepoListing.parse(Data(json.utf8)))
        #expect(listings.map(\.repo.slug) == ["acme/new", "acme/old"])
        #expect(listings[0].isPrivate && listings[0].description == "fresh")
        #expect(listings[1].isArchived)
        #expect(RepoListing.parse(Data("not json".utf8)) == nil)
        #expect(RepoListing.listArguments(owner: "acme", limit: 50) == [
            "repo", "list", "acme", "--limit", "50", "--json",
            "nameWithOwner,description,pushedAt,isPrivate,isArchived",
        ])
        #expect(!RepoListing.listArguments(owner: nil).contains("acme"))
    }

    @Test func eachRepoSaysWhereItAlreadyIs() {
        #expect(RepoPlace.of(Repo(org: "ACME", name: "Docs-Toolkit"), in: records)
            == .here("/Users/you/Projects/docs-toolkit"))
        #expect(RepoPlace.of(Repo(org: "acme", name: "ingest"), in: records) == .hosts(["devbox"]))
        #expect(RepoPlace.of(Repo(org: "acme", name: "anchor-lint"), in: records) == .notCloned)
        #expect(RepoPlace.hosts(["devbox"]).text(archived: false) == "✓ @devbox only · clone here")
        #expect(RepoPlace.notCloned.text(archived: false) == "clone")
        #expect(RepoPlace.notCloned.text(archived: true) == "archived")
        #expect(RepoPlace.hosts(["devbox"]).clones && !RepoPlace.here("/x").clones)
    }

    @Test func yourGitHubIsEveryListTogetherNewestFirst() {
        let form = form()
        #expect(form.rows.map(\.listing.repo.slug) == [
            "acme/anchor-lint", "acme/docs-toolkit", "you/dotfiles", "acme/ingest", "acme/legacy-annotator",
        ])
        #expect(form.count(.mine) == 5)
        #expect(form.count(.org("acme")) == 4)
        #expect(form.count(.org("globex")) == nil)
        #expect(form.tabs == [.mine, .org("acme"), .org("globex"), .folder])
    }

    @Test func typingNarrowsOnTheSlugOrTheDescription() {
        var form = form()
        type("acme/an", into: &form)
        #expect(form.rows.map(\.listing.repo.slug) == ["acme/anchor-lint"])
        form.setQuery("docs")
        #expect(form.rows.map(\.listing.repo.slug) == ["acme/anchor-lint", "acme/docs-toolkit"])
        // A URL narrows by the slug it names.
        form.setQuery("https://github.com/acme/docs-toolkit")
        #expect(form.rows.map(\.listing.repo.slug) == ["acme/docs-toolkit"])
    }

    @Test func aSlugNoListHasIsAskedOfGitHub() {
        var form = form()
        form.setQuery("acme/brand-new")
        #expect(form.rows.map(\.typed) == [true])
        #expect(form.typedNote == "checking acme/brand-new on GitHub…")
        // Not usable until GitHub answered.
        #expect(form.targets.isEmpty)
        form.lookups["acme/brand-new"] = .found(Repo(org: "acme", name: "Brand-New"))
        #expect(form.typedNote == nil)
        #expect(form.targets == [.clone(Repo(org: "acme", name: "Brand-New"))])
        #expect(form.submitTitle == "Clone acme/Brand-New")
        form.lookups["acme/brand-new"] = .missing
        #expect(form.typedNote == "no repo acme/brand-new on GitHub (or gh cannot see it)")
        #expect(form.targets.isEmpty)
    }

    @Test func spacePicksSeveralAndCommandReturnClonesWhatIsNotHere() {
        var form = form()
        // The row under the cursor alone, when nothing is picked.
        #expect(form.targets == [.clone(Repo(org: "acme", name: "anchor-lint"))])
        #expect(form.handle(KeyStroke("Space")) == .none)
        _ = form.handle(KeyStroke("n", .control))
        _ = form.handle(KeyStroke("Space"))
        #expect(form.picked == ["acme/anchor-lint", "acme/docs-toolkit"])
        // docs-toolkit is on this Mac already: added, not cloned.
        #expect(form.targets == [
            .clone(Repo(org: "acme", name: "anchor-lint")),
            .known(Repo(org: "acme", name: "docs-toolkit")),
        ])
        #expect(form.submitTitle == "Clone 2 repos")
        // Space again drops it.
        _ = form.handle(KeyStroke("Space"))
        #expect(form.picked == ["acme/anchor-lint"])
        #expect(form.handle(KeyStroke("CR", .command)) == .submit)
        #expect(form.handle(.escape) == .cancel)
    }

    @Test func onlyKnownReposAddWithoutCloning() {
        var form = form()
        form.setQuery("docs-toolkit")
        #expect(form.submitTitle == "Add")
    }

    @Test func tabsCycleAndAPathOpensTheFolderTab() {
        var form = form()
        _ = form.handle(KeyStroke("Tab"))
        #expect(form.currentTab == .org("acme"))
        #expect(form.rows.count == 4)
        _ = form.handle(KeyStroke("Tab", .shift))
        _ = form.handle(KeyStroke("Tab", .shift))
        #expect(form.currentTab == .folder)
        form.select(tab: 0)
        type("~/Pro", into: &form)
        #expect(form.currentTab == .folder)
        // ⇥ there completes the highlighted folder.
        form.candidates = ["/tmp/Projects"]
        #expect(form.handle(KeyStroke("Tab")) == .changed)
        #expect(form.query == "/tmp/Projects/")
        #expect(form.currentTab == .folder)
        // Nothing at the path yet: nothing to add.
        #expect(form.targets.isEmpty)
        form.folderRepo = Repo(org: "you", name: "side")
        #expect(form.targets == [.path("/tmp/Projects/")])
        #expect(form.submitTitle == "Add")
        // Words again: back to the lists.
        form.setQuery("lint")
        #expect(form.currentTab == .mine)
    }

    @Test func rootAndThenCycle() {
        var form = form(then: .startWork)
        #expect(form.root == "~/Projects")
        _ = form.handle(KeyStroke("r", .control))
        #expect(form.root == "~/code")
        _ = form.handle(KeyStroke("r", .control))
        #expect(form.root == "~/Projects")
        #expect(form.then == .startWork)
        _ = form.handle(KeyStroke("t", .control))
        #expect(form.then == .add)
        _ = form.handle(KeyStroke("t", .control))
        #expect(form.then == .setup)
    }

    @Test func orgsComeFromKnownReposAndGitHubWithoutYourOwnAccount() {
        let orgs = AddRepoForm.orgs(
            records: records + [
                RepoRecord(repo: Repo(org: "you", name: "dotfiles"), path: "/d"),
                RepoRecord(repo: Repo(org: "local", name: "scratch"), path: "/s"),
            ],
            listed: ["globex", "acme"], viewer: "you"
        )
        #expect(orgs == ["acme", "globex"])
        var form = form()
        form.select(tab: 2)
        form.addOrgs(["Globex", "initech"])
        #expect(form.tabs == [.mine, .org("acme"), .org("globex"), .org("initech"), .folder])
        #expect(form.currentTab == .org("globex"))
    }

    @Test func theThenStartsOnTheConfiguredDefault() throws {
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.work.afterAdd == .setup)
        let chosen = ConfigLoader.decode("[worktrees]\nafter_add = \"start_work\"\n")
        #expect(chosen.config?.work.afterAdd == .startWork)
        let wrong = ConfigLoader.decode("[worktrees]\nafter_add = \"later\"\n")
        #expect(wrong.config?.work.afterAdd == .setup)
        #expect(wrong.problems.map(\.path) == ["worktrees.after_add"])
        #expect(try form(then: #require(chosen.config?.work.afterAdd)).then == .startWork)
    }

    @Test func theListCacheSaysWhatIsStale() {
        let now = Date()
        let cache = RepoListCache(lists: [
            "": .init(at: now.addingTimeInterval(-60), listings: []),
            "acme": .init(at: now.addingTimeInterval(-3600), listings: []),
        ])
        #expect(!cache.isStale("", now: now))
        #expect(cache.isStale("acme", now: now))
        #expect(cache.isStale("globex", now: now))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-repo-lists-\(UUID()).json")
        cache.save(to: url)
        #expect(RepoListCache.load(from: url) == cache)
        try? FileManager.default.removeItem(at: url)
    }
}
