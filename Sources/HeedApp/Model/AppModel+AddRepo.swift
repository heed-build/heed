import AppKit
import HeedCore

/// Repos › Add or clone (`a`, `:repo.add`): the dialog's lists from `gh repo list` (cached, asked off the main actor),
/// the typed entry looked up as Start work does, a folder completed as `Ip` does, and on ⌘↩ the clones and adds, then
/// the chosen "then" (`[worktrees] after_add`).
extension AppModel {
    /// Opens the dialog on the last lists heed has, and asks gh for fresher ones.
    func openAddRepo() {
        if view != .repos { view = .repos }
        let fake = isFixture || tutor != nil
        let cache = fake ? fixtureRepoLists : loadedRepoListCache()
        let orgs = AddRepoForm.orgs(records: repos, listed: cache.orgs, viewer: nil)
        var form = AddRepoForm(
            orgs: orgs, records: repos, roots: settings.repoRoots, then: settings.afterAdd, lists: cache.states
        )
        form.lookups = repoLookups
        addRepoDialog = form
        if !fake { refreshRepoLists(owners: [""] + orgs) }
    }

    func cancelAddRepo() {
        addRepoFieldTask?.cancel()
        addRepoDialog = nil
    }

    /// The fake world's lists: what `gh repo list` answers there.
    private var fixtureRepoLists: RepoListCache {
        RepoListCache(
            lists: RepoListFixtures.lists.mapValues { .init(at: Clock.now, listings: $0) },
            orgs: RepoListFixtures.orgs
        )
    }

    private func loadedRepoListCache() -> RepoListCache {
        if let cache = repoListCache { return cache }
        let cache = RepoListCache.load()
        repoListCache = cache
        return cache
    }

    /// Asks gh for every stale list, and for the orgs you belong to, each off the main actor; answers land in the
    /// dialog (if still open) and the cache. An org gh names that had no tab gets one, and its list.
    private func refreshRepoLists(owners: [String]) {
        refreshLists(owners)
        Task { [weak self] in
            let orgs = await GitHub.orgs(caller: "repo.add")
            guard let self, !orgs.isEmpty else { return }
            repoListCache?.orgs = orgs
            let fresh = orgs.filter { !owners.contains($0) }
            addRepoDialog?.addOrgs(fresh)
            if !fresh.isEmpty { refreshLists(fresh) }
        }
    }

    private func refreshLists(_ owners: [String]) {
        let now = Date()
        for owner in owners where repoListCache?.isStale(owner, now: now) ?? true {
            if addRepoDialog?.lists[owner] == nil { addRepoDialog?.lists[owner] = .loading }
            Task { [weak self] in
                let answer = await GitHub.listRepos(owner: owner.isEmpty ? nil : owner, caller: "repo.add")
                guard let self else { return }
                switch answer {
                case let .success(listings):
                    addRepoDialog?.lists[owner] = .loaded(listings)
                    repoListCache?.lists[owner] = .init(at: Date(), listings: listings)
                    let cache = repoListCache
                    Task.detached { cache?.save() }
                case let .failure(why):
                    // A list heed had stays; one it never had says why.
                    if case .loaded? = addRepoDialog?.lists[owner] { return }
                    addRepoDialog?.lists[owner] = .failed(why.description)
                }
            }
        }
    }

    // MARK: Keys

    func answerAddRepo(_ stroke: KeyStroke) {
        guard var form = addRepoDialog else { return }
        // While it clones, only ⎋ (which leaves the clones running) does anything.
        if form.progress != nil, stroke != .escape { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            form.paste(text)
            addRepoDialog = form
            return refreshAddRepoField()
        }
        let action = form.handle(stroke)
        addRepoDialog = form
        switch action {
        case .none: break
        case .changed: refreshAddRepoField()
        case .cancel: cancelAddRepo()
        case .submit: submitAddRepo()
        }
    }

    /// A click on a tab, a row, a picker in the dialog.
    func editAddRepo(_ edit: (inout AddRepoForm) -> Void) {
        guard var form = addRepoDialog, form.progress == nil else { return }
        let tab = form.currentTab
        edit(&form)
        addRepoDialog = form
        if form.currentTab != tab, form.currentTab == .folder { refreshAddRepoField() }
    }

    /// After the field changed: a slug no list has is asked of GitHub; on the folder tab, the folders completing the
    /// path and the checkout at it.
    func refreshAddRepoField() {
        guard let form = addRepoDialog else { return }
        addRepoFieldTask?.cancel()
        if form.currentTab == .folder { return refreshAddRepoFolder(form.query) }
        guard case let .slug(repo)? = form.parsed, form.rows.first?.typed == true,
              form.lookups[RepoEntry.Parsed.slug(repo).key] == nil
        else { return }
        let parsed = RepoEntry.Parsed.slug(repo)
        lookUpRepoEntry(parsed, caller: "repo.add") { [weak self] answer, _ in
            self?.addRepoDialog?.lookups[parsed.key] = answer
        }
    }

    private func refreshAddRepoFolder(_ query: String) {
        if isFixture || tutor != nil || ShotMode.active {
            // Never the real disk: a made-up tree under /Users/you.
            let folders = ["/Users/you/Projects/sandbox", "/Users/you/Projects/side-project", "/Users/you/code/tools"]
            let typed = query.replacingOccurrences(of: "~", with: "/Users/you")
            addRepoDialog?.candidates = folders.filter { $0.hasPrefix(typed) && $0 != typed }
            let found = query.contains("side-project") ? Repo(org: "you", name: "side-project") : nil
            addRepoDialog?.folderRepo = found
            addRepoDialog?.folderNote = found.map { "\($0.slug), checked out here" }
                ?? (query.count > 2 ? "not a git checkout" : nil)
            return
        }
        addRepoFieldTask = Task { [weak self] in
            let candidates = await Task.detached { PathCompletion.candidates(for: query) }.value
            guard !Task.isCancelled, self?.addRepoDialog?.query == query else { return }
            self?.addRepoDialog?.candidates = candidates
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let record = query.isEmpty ? nil : await Git.record(at: Paths.expand(query))
            guard !Task.isCancelled, let self, addRepoDialog?.query == query else { return }
            addRepoDialog?.folderRepo = record?.repo
            addRepoDialog?.folderNote = record.map {
                "\($0.repo.org == "local" ? $0.repo.name : $0.repo.slug), checked out here"
            } ?? (query.isEmpty ? nil : "not a git checkout")
        }
    }

    // MARK: Adding

    /// ⌘↩: clones what is not here into the chosen root, adds a folder in place, then the "then" on the first repo.
    func submitAddRepo() {
        guard let form = addRepoDialog, form.progress == nil else { return }
        let targets = form.targets
        guard !targets.isEmpty else {
            addRepoDialog?.problem = form.currentTab == .folder
                ? "type the path of a git checkout" : "pick a repo, or type owner/name, a GitHub URL or a path"
            return
        }
        let then = form.then
        if isFixture || tutor != nil {
            // The fake world clones nothing: a cloned repo just appears under the root.
            var added: [Repo] = []
            for target in targets {
                switch target {
                case let .clone(repo):
                    commit(.repoUpserted(RepoRecord(
                        repo: repo, path: "\(Paths.expand(form.root))/\(repo.name)", defaultBranch: "main"
                    )))
                    added.append(repo)
                case let .known(repo): added.append(repo)
                case .path: if let repo = form.folderRepo { added.append(repo) }
                }
            }
            addRepoDialog = nil
            return afterAdding(added, then: then)
        }
        Task { await addTargets(targets, root: form.root, then: then) }
    }

    private func addTargets(_ targets: [AddRepoForm.Target], root: String, then: AfterAdd) async {
        var added: [Repo] = []
        for (index, target) in targets.enumerated() {
            let counter = targets.count > 1 ? " (\(index + 1) of \(targets.count))" : ""
            switch target {
            case let .known(repo): added.append(repo)
            case let .clone(repo):
                addRepoDialog?.progress = "cloning \(repo.slug) into \(root)\(counter)…"
                switch await cloneRepo(repo.slug, at: .local, caller: "repo.add", root: root) {
                case let .success(record):
                    // Its worktrees, as a scan would list them.
                    _ = await adoptRepo(at: record.path)
                    added.append(record.repo)
                case let .failure(note):
                    addRepoDialog?.progress = nil
                    addRepoDialog?.problem = note.text
                    if !added.isEmpty { flash = "added " + added.map(\.slug).joined(separator: ", ") }
                    return
                }
            case let .path(path):
                addRepoDialog?.progress = "adding \(path)\(counter)…"
                guard let (worktree, _) = await adoptRepo(at: Paths.expand(path)) else {
                    addRepoDialog?.progress = nil
                    addRepoDialog?.problem = "no git checkout at \(path)"
                    return
                }
                added.append(worktree.repo)
            }
        }
        addRepoDialog = nil
        afterAdding(added, then: then)
    }

    /// Repos on the first added repo, then the "then": Repo setup (a GitHub repo), Start work in it, or nothing.
    func afterAdding(_ added: [Repo], then: AfterAdd) {
        guard let first = added.first else { return }
        view = .repos
        focusRepos("repos")
        pickRepo(first)
        let others = added.count > 1 ? "; added \(added.count - 1) more" : ""
        switch then {
        case .setup where first.org != "local":
            openRepoSetup(nil, repo: first)
            if added
                .count >
                1
            {
                flash =
                    "set up \(first.slug) first\(others): \(keyText(for: "repo.setup", in: "repos")) on each sets it up"
            }
        case .startWork:
            openStartWork(prompt: "", fromCursor: false)
            startWork?.choose(repo: StartContext.id(first, .local))
        default:
            flash = "added \(first.slug)\(others)"
        }
    }

    /// `⌘O` in Repos: the repo's folder in Finder (its main checkout on this Mac).
    func revealRepo() {
        guard let repo = reposUnderCursor.first,
              let record = repos.first(where: { $0.repo == repo && $0.location.isLocal })
        else { return flash = "no repo on this Mac under the cursor" }
        guard !isFixture else { return flash = "fixture: would show \(record.path) in Finder" }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)])
    }
}
