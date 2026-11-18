import AppKit
import HeedCore

/// Browse (`gv`): the issues and PRs of an org, a repo or a Project, searched on GitHub, with the thread beside them.
/// The list is `browse.rows`; the cursor and the picks are `itemCursor` and `picked` as in Attention.
extension AppModel {
    /// Whether this is the fake world: no IO, and its own Mac.
    var isFixtureWorld: Bool { isFixture }

    /// A click on a rail row: the list starts again at the top.
    func browseOpenedQuery() {
        itemCursor[.browse] = 0
        browseSelectionChanged()
    }

    var browseRows: [BrowseItem] { browse.rows }

    var browseSelected: BrowseItem? {
        let rows = browse.rows
        let index = itemCursor[.browse] ?? 0
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// Whether heed has a checkout of the repo on this Mac (the fake world's Mac has its own).
    func browseIsCloned(_ repo: Repo) -> Bool {
        !RepoPlace.of(repo, in: browseRecords).clones
    }

    var browseRecords: [RepoRecord] { isFixture ? Fixtures.Browse.records : repos }

    /// Into Browse: the cached list draws at once, GitHub is asked for a fresh one.
    func enteredBrowse() {
        browse.configure(config.browse, viewer: github.viewer)
        browse.refilter()
        if (itemCursor[.browse] ?? 0) >= browse.rows.count { itemCursor[.browse] = 0 }
        browse.fetch()
        browseSelectionChanged()
    }

    /// The row under the cursor changed: the thread loads once the cursor rests on it.
    func browseSelectionChanged() {
        updateScope()
        guard view == .browse, !isFixture, let item = browseSelected else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard view == .browse, browseSelected?.id == item.id else { return }
            loadConversation(item.repo, item.number, updatedAt: item.updatedAt)
        }
    }

    func performBrowse(_ command: CommandInvocation) {
        browse.configure(config.browse, viewer: github.viewer)
        switch command.name {
        case "view.browse": view = .browse
        case "browse.open":
            guard let item = browseSelected else { return }
            loadConversation(item.repo, item.number)
        case "browse.scope": openBrowsePalette()
        case "browse.scope.next": browse.nextScope(by: 1); browseQueryChanged()
        case "browse.scope.prev": browse.nextScope(by: -1); browseQueryChanged()
        case "browse.query.next": browse.nextQuery(by: 1); browseQueryChanged()
        case "browse.query.prev": browse.nextQuery(by: -1); browseQueryChanged()
        case "browse.query.save":
            browse.saveQuery()
            say("kept “\(browse.activeSaved?.name ?? "the query")” in the rail")
        case "browse.older":
            browse.toggleOlder()
            browseQueryChanged()
            say(browse.query.showOlder ? "showing older items" : "back to the last \(browse.cap)")
        case "browse.refresh": browse.fetch()
        case "browse.sort":
            browse.cycleSort()
            itemCursor[.browse] = 0
            say("sorted by \(browse.sort.rawValue)")
        default: break
        }
    }

    private func browseQueryChanged() {
        itemCursor[.browse] = 0
        browseSelectionChanged()
    }

    // MARK: Quick jump (⌘K)

    func openBrowsePalette() {
        if view != .browse { view = .browse }
        if isFixture || tutor != nil {
            let data = Fixtures.Browse.self
            browse.palette = BrowsePalette(
                orgs: data.orgs, listings: data.listings, records: data.records, openCounts: data.openCounts,
                threshold: config.browse.manyRepos
            )
            return
        }
        let cache = repoListCache ?? RepoListCache.load()
        repoListCache = cache
        let listed = AddRepoForm.orgs(records: repos, listed: cache.orgs, viewer: github.viewer)
        var orgs = listed.map { name in
            BrowsePalette.Org(
                name: name,
                repoCount: browse.repoCounts[name.lowercased()] ?? cache.lists[name]?.listings.count
            )
        }
        if let viewer = github.viewer {
            orgs.insert(
                .init(
                    name: viewer, repoCount: browse.repoCounts[viewer.lowercased()] ?? cache.lists[""]?.listings.count,
                    personal: true
                ), at: 0
            )
        }
        browse.palette = BrowsePalette(
            orgs: orgs, listings: cache.lists.values.flatMap(\.listings), records: repos,
            threshold: config.browse.manyRepos
        )
        for org in orgs {
            browse.learnRepoCount(of: org.name)
        }
        refreshPaletteLists(owners: orgs.map(\.name))
    }

    /// Asks gh for the lists the palette lacks, each off the main actor, and for the orgs you belong to.
    private func refreshPaletteLists(owners: [String]) {
        Task { [weak self] in
            let known = owners
            let orgs = await GitHub.orgs(caller: "browse.scope")
            guard let self else { return }
            for org in orgs where !known.contains(org) {
                browse.palette?.orgs.append(.init(name: org))
                browse.learnRepoCount(of: org)
            }
            for owner in known + orgs.filter({ !known.contains($0) })
                where repoListCache?.isStale(owner, now: Date()) ?? true
            {
                guard case let .success(listings) = await GitHub.listRepos(owner: owner, caller: "browse.scope") else {
                    continue
                }
                repoListCache?.lists[owner] = .init(at: Date(), listings: listings)
                browse.palette?.listings.append(contentsOf: listings.filter { new in
                    !(browse.palette?.listings.contains { $0.repo == new.repo } ?? false)
                })
            }
            let cache = repoListCache
            Task.detached { cache?.save() }
        }
    }

    func answerBrowsePalette(_ stroke: KeyStroke) {
        guard var palette = browse.palette else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            for character in text.prefix(80)
                where character != "\n"
            {
                _ = palette.handle(KeyStroke(String(character)))
            }
            browse.palette = palette
            return
        }
        let action = palette.handle(stroke)
        browse.palette = palette
        switch action {
        case .none, .changed: break
        case .cancel: browse.palette = nil
        case let .choose(scope):
            browse.palette = nil
            browse.go(to: scope)
            browseQueryChanged()
        case let .createOrgView(org):
            say("\(org) has too many repos to browse at once: ⌃b browses it whole")
        }
    }
}
