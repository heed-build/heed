import AppKit
import HeedCore

/// Browse (`gb`): the issues and PRs of an org, a repo or a Project, searched on GitHub, with the thread beside them.
/// The list is `browse.rows`; the cursor and the picks are `itemCursor` and `picked` as in Attention.
extension AppModel {
    /// Whether this is the fake world: no IO, and its own Mac.
    var isFixtureWorld: Bool { isFixture }

    /// A click on a rail row: the list starts again at the top.
    func browseOpenedQuery() {
        browse.reading = false
        itemCursor[.browse] = 0
        browseSelectionChanged()
    }

    var browseRows: [BrowseItem] { browse.rows }

    var browseSelected: BrowseItem? {
        let rows = browse.rows
        let index = itemCursor[.browse] ?? 0
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// The quick filter at the right of the count: only the items with an agent, a session or a goal, and back. The
    /// cursor goes to the top, since the rows it pointed into change.
    func toggleBrowseFilter(_ filter: BrowseWorkFilter) {
        browse.workFilter = browse.shownFilter == filter ? nil : filter
        itemCursor[.browse] = 0
    }

    /// To a session or goal an item was started from, in Sessions or Goals.
    func openBrowseOrigin(session id: String) {
        view = .sessions
        select(sessionID: id)
    }

    func openBrowseOrigin(goal id: String) {
        view = .goals
        goals.point(to: id)
    }

    /// Which items have sessions or goals started from them: rebuilt when sessions or goals change.
    func refreshBrowseOrigins() {
        let refs = sessions.map { BrowseOrigins.SessionRefs(id: $0.id, issues: issues(of: $0), pulls: $0.trackedPRs) }
        browse.origins = BrowseOrigins.build(sessions: refs, goalItems: goals.snapshot.items)
    }

    /// Whether heed has a checkout of the repo on this Mac (the fake world's Mac has its own).
    func browseIsCloned(_ repo: Repo) -> Bool {
        !RepoPlace.of(repo, in: browseRecords).clones
    }

    var browseRecords: [RepoRecord] { isFixture ? Fixtures.Browse.records : repos }

    /// Browse works inside what is checked out: the orgs of `repos`, as they are now.
    func refreshBrowseCheckouts() {
        browse.setCheckouts(BrowseCheckouts(records: browseRecords))
    }

    /// Into Browse: the cached list draws at once, GitHub is asked for a fresh one.
    func enteredBrowse() {
        browse.configure(config.browse, viewer: github.viewer)
        refreshBrowseCheckouts()
        goals.onSnapshot = { [weak self] in self?.refreshBrowseOrigins() }
        refreshBrowseOrigins()
        browse.refilter()
        if (itemCursor[.browse] ?? 0) >= browse.rows.count { itemCursor[.browse] = 0 }
        browse.landed = { [weak self] in
            guard let self else { return }
            let last = max(browse.rows.count - 1, 0)
            if (itemCursor[.browse] ?? 0) > last { itemCursor[.browse] = last }
            queueAheadBrowseReads()
        }
        browse.holdState = { [weak self] in
            var state = BrowseRefreshPolicy.State()
            self?.browseHolds(into: &state)
            return state
        }
        browse.cursorState = { [weak self] in
            guard let self else { return (nil, 0, []) }
            return (browseSelected?.id, itemCursor[.browse] ?? 0, pickedIDs(.browse))
        }
        browse.adopt = { [weak self] outcome in self?.browseAdopted(outcome) }
        browseAutoRefresh(.viewSwitch)
        browse.startCounts { [weak self] in self?.view == .browse }
        browseSelectionChanged()
        queueAheadBrowseReads()
    }

    // MARK: Staying current

    /// What holds the list still: an item the reader shows or a run works on, picks, a pushed reader, a sheet.
    func browseHolds(into state: inout BrowseRefreshPolicy.State) {
        state.cursorInReader = view == .browse && browseSelected != nil
            && (browse.layout.showsReaderBeside || browse.reading)
        state.picks = pickedIDs(.browse).count
        state.readerPushed = browse.reading && !browse.layout.showsReaderBeside
        state.runLive = browse.runs.runs.contains { $0.isLive }
        state.overlayOpen = browse.palette != nil || browse.builder != nil || browse.orgBuilder != nil
            || browse.jumpSheet || browse.runs.input != nil
        state.bulkOpen = browse.bulk != nil
    }

    /// Coming back to Browse (the view, the app, the window): asks GitHub quietly for the view you are on when the last
    /// answer is old enough. Never raises a window or takes focus.
    func browseAutoRefresh(_ trigger: BrowseRefreshPolicy.Trigger) {
        var state = browse.refreshState()
        state.trigger = trigger
        state.frontIsBrowse = view == .browse && tutor == nil
        browseHolds(into: &state)
        if BrowseRefreshPolicy.decide(state: state).fetch { browse.fetch(.refresh) }
    }

    /// The app coming forward and the main window regaining key, while Browse is in front.
    func startBrowseActivation() {
        guard !isFixture else { return }
        let center = NotificationCenter.default
        center
            .addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.browseCameBack(.appActive) }
            }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let main = (note.object as? NSWindow)?.identifier == Self.mainWindowID
            MainActor.assumeIsolated { if main { self?.browseCameBack(.windowKey) } }
        }
    }

    private func browseCameBack(_ trigger: BrowseRefreshPolicy.Trigger) {
        guard view == .browse else { return }
        browse.configure(config.browse, viewer: github.viewer)
        browseAutoRefresh(trigger)
    }

    /// A held diff became the list: the cursor stays on its item, the picks that still exist stay picked.
    private func browseAdopted(_ outcome: BrowseRefreshApply.Outcome) {
        if (itemCursor[.browse] ?? 0) != outcome.cursor { itemCursor[.browse] = outcome.cursor }
        if !outcome.droppedPicks.isEmpty {
            pick((picked[.browse] ?? []).subtracting(outcome.droppedPicks), in: .browse)
        }
        if let note = outcome.note { say(note) }
    }

    /// The row under the cursor changed: the thread loads once the cursor rests on it.
    func browseSelectionChanged() {
        updateScope()
        guard view == .browse, !isFixture, let item = browseSelected else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard view == .browse, browseSelected?.id == item.id else { return }
            loadConversation(item.repo, item.number, updatedAt: item.updatedAt)
            browseReadOnOpen(item)
        }
    }

    func performBrowse(_ command: CommandInvocation) {
        browse.configure(config.browse, viewer: github.viewer)
        refreshBrowseCheckouts()
        switch command.name {
        case "view.browse": view = .browse
        case "browse.open":
            guard let item = browseSelected else { return }
            // Half and third widths: the reader is pushed over the list, and esc goes back.
            if !browse.layout.showsReaderBeside { browse.reading = true }
            // On an item with a run, ↩ is the card's first button (clone) or the steer line.
            if let run = browse.runs.current(for: item.id) {
                return run.phase == .needsClone ? browseCloneGo() : browseRunSteer()
            }
            loadConversation(item.repo, item.number)
        case "browse.scope": openBrowsePalette()
        case "browse.scope.next": browse.nextScope(by: 1); browseQueryChanged()
        case "browse.scope.prev": browse.nextScope(by: -1); browseQueryChanged()
        case "browse.scope.toggle":
            guard let owner = browse.scope?.owner
            else { return say("pick an org first: \(keyText(for: "browse.scope", in: "browse"))") }
            browse.toggleExpansion(of: owner)
        case "browse.query.next": browse.nextQuery(by: 1); browseQueryChanged()
        case "browse.query.prev": browse.nextQuery(by: -1); browseQueryChanged()
        case "browse.filter.add": openBrowseBuilder()
        case "browse.filter.remove":
            guard !browse.query.tokens.isEmpty else { return say("no filter to remove") }
            var next = browse.query
            next.tokens.removeLast()
            browse.applyBuilder(next)
            browseQueryChanged()
        case "browse.query.save":
            openBrowseBuilder()
            browse.builder?.startSaving()
        case "browse.query.rename":
            guard let saved = browse.activeSaved
            else { return say("run a saved query first: \(keyText(for: "browse.query.next", in: "browse"))") }
            browse.builder = BrowseBuilder(renaming: saved, context: browse.builderContext(wordsOff: browseWordsOff))
        case "browse.query.delete":
            guard let saved = browse.activeSaved
            else { return say("run a saved query first: \(keyText(for: "browse.query.next", in: "browse"))") }
            browse.removeQuery(saved.id)
            say("removed “\(saved.name)” from the rail")
        case "browse.query.up", "browse.query.down":
            guard let saved = browse.activeSaved
            else { return say("run a saved query first: \(keyText(for: "browse.query.next", in: "browse"))") }
            browse.moveQuery(saved.id, by: command.name == "browse.query.up" ? -1 : 1)
        case "browse.view.new":
            guard let owner = browse.scope?.owner
            else { return say("pick an org first: \(keyText(for: "browse.scope", in: "browse"))") }
            browse.openOrgBuilder(owner: owner)
        case "browse.older":
            browse.toggleOlder()
            browseQueryChanged()
            say(browse.query.showOlder ? "showing older items" : "back to the last \(browse.cap)")
        case "browse.refresh":
            // A banner waits with new, gone and reordered rows: apply it, no new question to GitHub.
            if browse.pending != nil { browse.applyPending() } else { browse.fetch() }
        case "browse.read": browseReadNow()
        case "browse.fix": browseVerb(.fix)
        case "browse.implement": browseVerb(.implement)
        case "browse.chat": browseVerb(.chat)
        case "browse.review": browseVerb(.review)
        case "browse.agents": toggleBrowseFilter(.agent)
        case "browse.from.sessions": toggleBrowseFilter(.session)
        case "browse.from.goals": toggleBrowseFilter(.goal)
        case "browse.tell": browseTellRun()
        case "browse.run.close": browseEscape()
        case "browse.run.keep": keepBrowseRun()
        case "browse.run.steer": browseRunSteer()
        case "browse.run.review.post": postBrowseReview()
        case "browse.run.review.edit": editBrowseReview()
        case "browse.run.review.discard": discardBrowseReview()
        case "browse.clone.go": browseCloneGo()
        case "browse.clone.only": browseCloneOnly()
        case "browse.clone.folder": browseCloneFolder()
        case "browse.sort":
            browse.cycleSort()
            itemCursor[.browse] = 0
            say("sorted by \(browse.sort.rawValue)")
        default: performBrowseBulk(command)
        }
    }

    /// ⎋ in Browse, from the inside out: a bulk step, the picks, the jump sheet, a run's reader, a pushed reader.
    private func browseEscape() {
        if browse.bulk != nil { return browse.bulk = nil }
        if !pickedIDs(.browse).isEmpty { return clearPicks() }
        if browse.jumpSheet { return browse.jumpSheet = false }
        if let item = browseSelected, browse.runs.current(for: item.id) != nil
            || browse.runs.runs.contains(where: { $0.itemID == item.id }) { return closeBrowseRun() }
        if browse.reading, !browse.layout.showsReaderBeside { return browse.reading = false }
        closeBrowseRun()
    }

    private func browseQueryChanged() {
        browse.reading = false
        itemCursor[.browse] = 0
        browseSelectionChanged()
        queueAheadBrowseReads()
    }

    // MARK: Quick jump (⌘K)

    /// The saved queries as the jump lists them: newest used first, each with its count.
    private var paletteQueries: [BrowsePalette.QueryRow] {
        BrowsePalette.byRecency(browse.queries, used: browse.queryUsed).map {
            .init(query: $0, count: browse.count(of: $0))
        }
    }

    func openBrowsePalette() {
        if view != .browse { view = .browse }
        if isFixture || tutor != nil {
            let data = Fixtures.Browse.self
            browse.palette = BrowsePalette(
                orgs: data.orgs, listings: data.listings, records: data.records, openCounts: data.openCounts,
                threshold: config.browse.manyRepos, queries: paletteQueries
            )
            return
        }
        let cache = repoListCache ?? RepoListCache.load()
        repoListCache = cache
        let listed = AddRepoForm.orgs(records: repos, listed: cache.orgs, viewer: github.viewer)
        let checkouts = browse.checkouts
        // Every checked-out org is listed, with or without a GitHub list; the others only as typed text matches.
        let names = checkouts.orgNames + listed.filter { !checkouts.contains(org: $0) }
        var orgs = names.map { name in
            BrowsePalette.Org(
                name: name,
                repoCount: browse.repoCounts[name.lowercased()] ?? cache.lists[name]?.listings.count,
                checkedOut: checkouts.contains(org: name), ownRepos: checkouts.org(name)?.repos.count ?? 0
            )
        }
        if let viewer = github.viewer {
            orgs.insert(
                .init(
                    name: viewer, repoCount: browse.repoCounts[viewer.lowercased()] ?? cache.lists[""]?.listings.count,
                    personal: true, checkedOut: checkouts.contains(org: viewer),
                    ownRepos: checkouts.org(viewer)?.repos.count ?? 0
                ), at: 0
            )
        }
        browse.palette = BrowsePalette(
            orgs: orgs, listings: cache.lists.values.flatMap(\.listings), records: repos,
            threshold: config.browse.manyRepos, queries: paletteQueries
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
                browse.palette?.orgs.append(.init(name: org, checkedOut: browse.checkouts.contains(org: org)))
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
            browse.palette = nil
            browse.openOrgBuilder(owner: org)
        case let .run(saved):
            browse.palette = nil
            browse.run(saved)
            browseQueryChanged()
        case let .searchGitHub(words):
            // ⌘K is the one dialog for "get me to X or find Y": the words go to the add-filter card as typed there.
            browse.palette = nil
            openBrowseBuilder()
            guard var builder = browse.builder else { return }
            let action = builder.askWords(words)
            browse.builder = builder
            if case let .read(sentence) = action { readBrowseWords(sentence) }
            if case let .apply(query) = action {
                browse.builder = nil
                browse.applyBuilder(query)
                browseQueryChanged()
            }
        }
    }

    // MARK: The add-filter popover (/)

    /// Why words cannot go to the model, or nil when they can: `[llm] enabled`, and never in the fake world's real
    /// call (it answers from a fixture).
    var browseWordsOff: String? {
        config.llm.enabled ? nil : "heed's model calls are off ([llm] enabled = false), so words search as text"
    }

    func openBrowseBuilder() {
        if view != .browse { view = .browse }
        browse.configure(config.browse, viewer: github.viewer)
        browse.openBuilder(wordsOff: browseWordsOff)
    }

    func answerBrowseBuilder(_ stroke: KeyStroke) {
        guard var builder = browse.builder else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            for character in (text.split(separator: "\n").first ?? "").prefix(600) {
                _ = builder.handle(KeyStroke(character == " " ? "Space" : String(character)))
            }
            browse.builder = builder
            return
        }
        let action = builder.handle(stroke)
        browse.builder = builder
        switch action {
        case .none, .changed: break
        case .close: browse.builder = nil
        case let .apply(query):
            if builder.stage == .fields, builder.input.isEmpty, stroke == KeyStroke("BS") {
                browse.builder?.base = query // stays open: it only removed a token
                browse.query = query
                browse.activeQuery = nil
                browse.refilter()
                browse.changed()
            } else {
                browse.builder = nil
                browse.applyBuilder(query)
            }
            browseQueryChanged()
        case let .read(words): readBrowseWords(words)
        case let .copy(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            say("copied the GitHub query")
        case let .keep(keep):
            browse.builder = nil
            browse.keep(keep)
            say("kept “\(keep.name)” in the rail")
        }
    }

    /// Words to tokens: the cheap model reads the sentence, the pure parser turns its JSON into typed tokens. In the
    /// fake world the answer is a fixture. A failure, or the model being off, is said on the card.
    private func readBrowseWords(_ words: String) {
        if isFixture || tutor != nil {
            browse.builder?.setReading(.ready(Fixtures.Browse.understood))
            return
        }
        let summarizer = summarizer
        let viewer = github.viewer
        Task { [weak self] in
            do {
                let answer = try await summarizer.summarize(
                    kind: .browseWords, inputs: BrowseWords.inputs(words), caller: BrowseWords.caller,
                    priority: .interactive
                )
                guard let self, browse.builder?.sentence == words else { return }
                browse.builder?.setReading(.ready(BrowseWords.understand(answer, viewer: viewer)))
            } catch {
                guard let self, browse.builder?.sentence == words else { return }
                browse.builder?.setReading(.failed("\(error)"))
            }
        }
    }

    // MARK: Org view builder

    func answerBrowseOrgBuilder(_ stroke: KeyStroke) {
        guard var builder = browse.orgBuilder else { return }
        let action = builder.handle(stroke)
        browse.orgBuilder = builder
        switch action {
        case .none, .changed: break
        case .close: browse.orgBuilder = nil
        case let .create(view):
            browse.create(view)
            browseQueryChanged()
            say("kept “\(view.name)” as a scope: \(view.qualifier)")
        }
    }
}
