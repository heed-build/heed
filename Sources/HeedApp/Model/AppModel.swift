import AppKit
import HeedCore
import Observation

/// The views behind `⌘1`..`⌘6`.
enum AppView: String, CaseIterable, Identifiable {
    case sessions, inbox, issues, prs, repos, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .inbox: "Inbox"
        case .issues: "Issues"
        case .prs: "PRs"
        case .repos: "Repos"
        case .history: "History"
        }
    }
}

enum Overlay: Equatable {
    case help
    case pr
    case diff
}

/// Everything the window draws, on the main actor.
///
/// The domain arrives as separate stored properties (sessions, layouts, repos, worktrees) so Observation redraws only
/// what reads the one that changed. Every edit, from the UI or an adapter, is a `DomainChange` that goes through
/// `commit`: applied here, then to the store off the main actor, which persists it. Nothing here waits on a process,
/// the network or the disk.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = NSUserInterfaceItemIdentifier("heed.main")
    // Domain
    private(set) var sessions: [Session] = [] { didSet { rebuildList() } }
    private(set) var layouts: [String: SessionLayout] = [:]
    private(set) var repos: [RepoRecord] = []
    private(set) var worktrees: [Worktree] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var github = GitHubState()
    private(set) var pullDetails: [String: PullDetail] = [:]
    private(set) var feedback: [String: PullFeedback] = [:]
    private(set) var list = SessionList([])
    private(set) var settings: WorkSettings
    private(set) var config = HeedConfig.default
    /// What is wrong with config.toml, if anything; the last good config stays in use.
    private(set) var configProblems: [ConfigProblem] = []
    let configFile = ConfigLoader.defaultFile()
    private var configWatcher: ConfigWatcher?
    /// Results of pinned tasks by pane: the exit code of the last run.
    private(set) var taskResults: [String: Int] = [:]
    /// Opens the Settings window (set by the view, which has the SwiftUI action).
    var openSettings: (() -> Void)?
    /// Nil for fixtures: nothing is persisted and no adapter runs.
    private var store: DomainStore?
    let isFixture: Bool
    private var hookServer: HookServer?
    let integration = IntegrationFiles.default()
    /// The latest hook events per session, newest first: shown in the inspector, not persisted (agents own history).
    private(set) var events: [String: [AgentEvent]] = [:]

    // Filtering (`/`): typed into while `filtering`; applies to the sessions list or the history list.
    private(set) var filtering = false
    private(set) var sessionFilter = "" { didSet { rebuildList() } }
    private(set) var historyFilter = ""
    private(set) var historyOutcome: Outcome?
    private(set) var historyCursor = 0

    // GitHub lists: cursor and picked ids per view
    private(set) var itemCursor: [AppView: Int] = [:]
    private(set) var picked: [AppView: Set<String>] = [:]
    private(set) var inboxFilter: InboxFilter = .unread

    // Resume on launch
    private(set) var resume: ResumeForm?
    /// Resumed sessions that were mid-turn: they get the continue prompt once their agent reports idle.
    private var pendingContinue: Set<String> = []

    // Cursors
    private(set) var cursor = 0
    private var previousSessionID: String?
    private(set) var repoCursor = 0
    /// VISUAL selection in the Repos table: worktree ids toggled with space, plus the range from the anchor.
    private(set) var toggledRows: Set<String> = []
    private var visualAnchor: Int?

    // Keys and modes
    private(set) var engine: ModeEngine
    private(set) var keyProblems: [Keymaps.Problem]
    var mode: Mode { engine.mode }
    var pendingKeys: String { engine.pendingDisplay }

    // Chrome
    private(set) var view: AppView = .sessions { didSet { updateScope() } }
    private(set) var overlay: Overlay? { didSet { updateScope() } }
    /// The PR open in the reader, over whatever view it was opened from.
    private(set) var reader: PullRef? { didSet { updateScope() } }
    /// The PR the overlay shows (one of the current session's).
    private(set) var overlayPull: PullRef?
    private(set) var feedbackCursor = 0
    /// When you last typed into each session's panes; feedback waits after that.
    private var lastTyped: [String: Date] = [:]
    /// PRs with queued feedback waiting for their agent to be idle.
    private var pendingDelivery: Set<PullRef> = []

    /// Scoped key bindings follow what has focus: the diff, the PR overlay or reader, else the view.
    private func updateScope() {
        engine.scope = overlay == .diff ? "diff"
            : (overlay == .pr || reader != nil) ? "pr" : (view == .sessions ? nil : view.rawValue)
    }

    // Diff overlay
    private(set) var diffScope: DiffScope = .all
    private(set) var diffFiles: [FileDiff] = []
    private(set) var diffCommits: [CommitSummary] = []
    private(set) var diffFileIndex = 0
    private(set) var diffRow = 0
    private(set) var diffSplit = false
    private(set) var diffLoading = false
    private var diffTask: Task<Void, Never>?

    /// Pane collapse state is a UI preference, not domain: kept in UserDefaults.
    private(set) var inspectorVisible = UserDefaults.standard.object(forKey: "inspectorVisible") as? Bool ?? true {
        didSet { if !isFixture { UserDefaults.standard.set(inspectorVisible, forKey: "inspectorVisible") } }
    }

    private(set) var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { if !isFixture { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }
    }

    private(set) var commandText = ""
    private(set) var flash: String?
    private(set) var hintText = ""
    private var hintThenInsert = false
    /// The Start work dialog, while open.
    private(set) var startWork: StartWorkForm?
    private(set) var startingWork = false
    /// Bumped when the focused terminal should take keyboard focus (entering INSERT, moving panes).
    private(set) var terminalFocusRequest = 0
    /// A text field owns the keyboard; the key router lets keys through to it.
    var textInputActive = false

    init(domain: Domain, settings: WorkSettings = .default, isFixture: Bool) {
        self.settings = settings
        self.isFixture = isFixture
        let built = Keymaps.build()
        engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        keyProblems = built.problems
        replace(with: domain)
    }

    // MARK: Domain

    /// Starts from the cache, then refreshes from git. The window is already up showing whatever the cache holds.
    func start(cache file: URL) async {
        startConfig()
        startHooks()
        let integration = integration
        Task.detached(priority: .utility) {
            do { try integration.write() } catch { NSLog("heed: could not write hook files: \(error)") }
        }
        let cached = await DomainStore.load(from: file)
        replace(with: cached)
        store = DomainStore(domain: cached, file: file)
        await offerResume(domain: cached)
        startGitHubSync()
        await refreshRepos()
    }

    // MARK: GitHub

    private var githubTask: Task<Void, Never>?
    private(set) var syncing = false

    /// Syncs now and then every minute. A failed sync keeps the cached data and marks it offline.
    private func startGitHubSync() {
        githubTask?.cancel()
        githubTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncGitHub()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func syncGitHub() async {
        guard !isFixture, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let previous = github
        let tracked = Array(Set(sessions.flatMap(\.trackedPRs)))
        do {
            let state = try await GitHub.sync(tracked: tracked, previous: previous)
            commit([.githubSynced(state)] + PullTracking.changes(sessions: sessions, pulls: state.pulls))
            await refreshWatchedDetails()
        } catch {
            var offline = previous
            offline.status = .offline("\(error)")
            commit(.githubSynced(offline))
        }
    }

    // MARK: Resume on launch

    /// Works out what to resume (checking which agent sessions still exist, off the main actor) and asks, resumes or
    /// does nothing, per `resumeOnLaunch`.
    private func offerResume(domain: Domain) async {
        guard settings.resumeOnLaunch != .never, !domain.sessions.isEmpty else { return }
        let settings = settings
        let integration = integration
        let candidates = await Task.detached(priority: .userInitiated) {
            Resume.candidates(domain: domain, settings: settings, integration: integration) { session in
                let directory = domain.layouts[session.id]?.tabs.first?.tree.panes.first?.directory ?? ""
                return AgentIntegration.hasSession(
                    agent: session.agent,
                    id: session.agentSessionID ?? "",
                    directory: directory
                )
            }
        }.value
        guard !candidates.isEmpty else { return }
        if settings.resumeOnLaunch == .always {
            resumeSessions(candidates.filter(\.defaultSelected))
        } else {
            resume = ResumeForm(candidates: candidates)
        }
    }

    /// Fixture: open on the resume dialog for the fixture's sessions, without checking any files.
    func showResumeForFixture() {
        resume = ResumeForm(candidates: Resume.candidates(
            domain: Domain(sessions: sessions, layouts: layouts), settings: settings, integration: integration
        ))
    }

    private func handleResume(_ stroke: KeyStroke) {
        guard var form = resume else { return }
        switch form.handle(stroke) {
        case .handled:
            resume = form
        case let .resume(chosen):
            resume = nil
            resumeSessions(chosen)
        case .startEmpty:
            resume = nil
        }
    }

    /// Starts each chosen session's agent pane on its resume (or fresh) command, now, even off screen.
    private func resumeSessions(_ chosen: [ResumeCandidate]) {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        for candidate in chosen {
            guard var layout = layouts[candidate.id], var session = sessions.first(where: { $0.id == candidate.id })
            else { continue }
            guard let (tabIndex, paneID) = agentPane(in: layout) else { continue }
            layout.tabs[tabIndex].tree = layout.tabs[tabIndex].tree.updating(paneID) { $0.command = candidate.command }
            session.record(candidate.mode == .startFresh ? "relaunched · started fresh" : "resumed after restart")
            session.state = ObservedState(.idle, source: .guessed, reason: "resuming")
            commit([.layoutChanged(session: session.id, layout), .sessionUpserted(session)])
            TerminalSurfaces.shared.autostartPanes.insert(paneID)
            if let pane = layout.tabs[tabIndex].tree.panes.first(where: { $0.id == paneID }) {
                TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
            }
            if candidate.mode == .resumeThenContinue, !settings.continuePrompt.isEmpty {
                pendingContinue.insert(session.id)
            }
        }
        if !chosen.isEmpty { flash = "resumed \(chosen.count) session\(chosen.count == 1 ? "" : "s")" }
    }

    /// The pane the agent runs in: the first `.agent` pane, else the first pane.
    private func agentPane(in layout: SessionLayout) -> (Int, String)? {
        for (index, tab) in layout.tabs.enumerated() {
            if let pane = tab.tree.panes.first(where: { $0.role == .agent }) { return (index, pane.id) }
        }
        return layout.tabs.first?.tree.panes.first.map { (0, $0.id) }
    }

    // MARK: Config

    /// Loads config.toml (writing the commented default the first time) and reloads it whenever it is saved.
    private func startConfig() {
        let watcher = ConfigWatcher(file: configFile) { [weak self] text in
            Task { @MainActor in self?.applyConfig(source: text) }
        }
        configWatcher = watcher
        applyConfig(source: watcher.start())
    }

    func applyConfig(source: String) {
        let (decoded, problems) = ConfigLoader.decode(source)
        configProblems = problems
        guard let decoded else { return }
        config = decoded
        settings = decoded.work
        let built = decoded.keymaps()
        engine.setKeymaps(built.keymaps, scoped: built.scoped)
        updateScope()
        keyProblems = built.problems
        Palette.shared.apply(decoded)
    }

    /// Settings writes one value into config.toml; the watcher picks the change up like any other edit.
    func setConfig(_ path: [String], _ value: TOMLValue) {
        do {
            try ConfigWatcher.set(path, to: value, in: configFile)
        } catch {
            flash = "could not write config.toml: \(error)"
        }
    }

    // MARK: Hooks

    private func startHooks() {
        let server = HookServer()
        do {
            try server.start()
        } catch {
            flash = "hooks: \(error)"
            return
        }
        hookServer = server
        Task {
            for await message in server.messages {
                receive(message)
            }
        }
    }

    /// One message from an agent's hook, applied to its session.
    func receive(_ message: HookMessage) {
        guard var session = sessions.first(where: { $0.id == message.session }) else { return }
        switch message.kind {
        case let .state(state, reason):
            session.state = session.state.accepting(ObservedState(state, source: .reported, reason: reason))
            session.activity = reason.map { "\(state.rawValue) · \($0)" } ?? state.rawValue
            session.lastActivity = message.sentAt
            var log = events[session.id] ?? []
            log.insert(AgentEvent(at: message.sentAt, state: state, reason: reason), at: 0)
            events[session.id] = Array(log.prefix(20))
            if state == .idle || state == .done {
                let waiting = pendingDelivery.filter { session.trackedPRs.contains($0) }
                Task { @MainActor in
                    for ref in waiting {
                        self.deliver(ref, explicit: false)
                    }
                }
            }
            if state == .idle, pendingContinue.remove(session.id) != nil,
               let layout = layouts[session.id], let (_, paneID) = agentPane(in: layout)
            {
                TerminalSurfaces.shared.typeLine(settings.continuePrompt, paneID: paneID)
                session.record("sent “\(settings.continuePrompt)”")
            }
        case let .title(title):
            session.title = title
        case let .prAdd(url):
            guard let pull = PullRef(url: url), !session.trackedPRs.contains(pull) else { return }
            session.trackedPRs.append(pull)
            session.record("tracking PR \(pull.repo.name)#\(pull.number)")
        case let .agentSession(id, _):
            session.agentSessionID = id
        case let .notify(text):
            flash = "\(session.title): \(text)"
            return
        case let .taskExit(code):
            if let pane = message.pane { taskResults[pane] = code }
            return
        }
        commit(.sessionUpserted(session))
    }

    func flush() async { await store?.flush() }

    private func rebuildList() {
        let filter = sessionFilter.lowercased()
        list = SessionList(filter.isEmpty ? sessions : sessions.filter { session in
            ([session.title, session.branch, session.agent] + session.repos.map(\.name)
                + session.trackedPRs.map { "#\($0.number)" })
                .contains { $0.lowercased().contains(filter) }
        })
    }

    private func replace(with domain: Domain) {
        sessions = domain.sessions
        layouts = domain.layouts
        repos = domain.repos
        worktrees = domain.worktrees
        history = domain.history
        github = domain.github
        pullDetails = domain.pullDetails
        feedback = domain.feedback
        cursor = min(cursor, max(list.ordered.count - 1, 0))
    }

    /// The one way the domain changes. Only properties that actually changed are written, so only their readers redraw.
    func commit(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        let before = currentDomain
        let after = before.applying(changes)
        if after.history != before.history { history = after.history }
        if after.github != before.github { github = after.github }
        if after.pullDetails != before.pullDetails { pullDetails = after.pullDetails }
        if after.feedback != before.feedback { feedback = after.feedback }
        if after.sessions != before.sessions { sessions = after.sessions }
        if after.layouts != before.layouts { layouts = after.layouts }
        if after.repos != before.repos { repos = after.repos }
        if after.worktrees != before.worktrees { worktrees = after.worktrees }
        if let store { Task { await store.apply(changes) } }
    }

    func commit(_ change: DomainChange) { commit([change]) }

    var currentDomain: Domain {
        Domain(
            repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts, history: history, github: github,
            pullDetails: pullDetails, feedback: feedback
        )
    }

    /// Scans the repo roots and lists every repo's worktrees with their status, concurrently and off the main actor.
    func refreshRepos() async {
        guard !isFixture else { return }
        let found = await RepoScanner.scan(roots: settings.repoRoots)
        commit(found.map { .repoUpserted($0) })
        await withTaskGroup(of: [DomainChange].self) { group in
            for record in repos {
                group.addTask {
                    guard var listed = try? await Git.worktrees(of: record) else { return [] }
                    for index in listed.indices {
                        listed[index].status = try? await Git.status(at: listed[index].path)
                    }
                    return [.worktreesListed(repo: record.repo, listed)]
                }
            }
            for await changes in group {
                commit(changes)
            }
        }
    }

    // MARK: Derived

    var currentSession: Session? {
        let ordered = list.ordered
        return ordered.indices.contains(cursor) ? ordered[cursor] : nil
    }

    var currentLayout: SessionLayout? { currentSession.flatMap { layouts[$0.id] } }
    var currentTabs: [PaneTab] { currentLayout?.tabs ?? [] }
    var currentTabIndex: Int { currentLayout?.activeTab ?? 0 }

    var currentTab: PaneTab? {
        let all = currentTabs
        return all.indices.contains(currentTabIndex) ? all[currentTabIndex] : nil
    }

    var blockedCount: Int { sessions.count { $0.state.state == .blocked } }
    var askingCount: Int { sessions.count { $0.state.state == .asking } }

    /// Added worktrees (not main checkouts), in table order: by repo, then path.
    var worktreeRows: [Worktree] {
        worktrees.filter { !$0.isMain }.sorted {
            $0.repo.slug == $1.repo.slug ? $0.path < $1.path : $0.repo.slug < $1.repo.slug
        }
    }

    func session(for worktree: Worktree) -> Session? {
        sessions.first { $0.branch == worktree.branch && $0.repos.contains(worktree.repo) }
    }

    /// Rows selected in VISUAL: the range from the anchor to the cursor, plus rows toggled with space.
    var selectedRows: Set<String> {
        let rows = worktreeRows
        var selected = toggledRows
        if mode == .visual, let anchor = visualAnchor, !rows.isEmpty {
            let range = min(anchor, repoCursor) ... max(anchor, repoCursor)
            for index in range where rows.indices.contains(index) {
                selected.insert(rows[index].id)
            }
        }
        return selected
    }

    /// Hint labels for every session row and every pane of the current tab, in that order.
    var hintTargets: [(label: String, target: HintTarget)] {
        let targets = list.ordered.map { HintTarget.session($0.id) }
            + (currentTab?.tree.panes.map { HintTarget.pane($0.id) } ?? [])
        return zip(HintLabels.generate(count: targets.count), targets).map { ($0, $1) }
    }

    func hintLabel(for target: HintTarget) -> String? {
        guard mode == .hint else { return nil }
        return hintTargets.first { $0.target == target }?.label
    }

    // MARK: Keys

    /// Returns true when the key was used by the app, false when it should go on to the terminal.
    func handle(_ stroke: KeyStroke) -> Bool {
        if resume != nil {
            handleResume(stroke)
            return true
        }
        if filtering {
            typeFilter(stroke)
            return true
        }
        if startWork != nil {
            handleStartWork(stroke)
            return true
        }
        let before = engine.mode
        let outcome = engine.handle(stroke)
        switch outcome {
        case .terminal:
            if let id = currentSession?.id { lastTyped[id] = Date() }
            return false
        case let .text(stroke):
            typeText(stroke)
        case .pending, .cleared:
            break
        case let .run(invocation):
            flash = nil
            perform(invocation)
        case let .unbound(keys):
            flash = "\(KeyNotation.format(keys)) is not bound"
        }
        if engine.mode != before { modeChanged(from: before) }
        return true
    }

    private func modeChanged(from previous: Mode) {
        if previous == .command { commandText = "" }
        if previous == .hint { hintText = "" }
        if previous == .visual {
            toggledRows = []
            visualAnchor = nil
        }
        if mode == .visual {
            visualAnchor = switch view {
            case .repos: repoCursor
            case .inbox, .issues: itemCursor[view] ?? 0
            default: nil
            }
        }
        if mode == .insert { terminalFocusRequest += 1 }
    }

    private func typeText(_ stroke: KeyStroke) {
        switch mode {
        case .command:
            if stroke.key == "BS" {
                if commandText.isEmpty { engine.enter(.normal) } else { commandText.removeLast() }
            } else if stroke.key == "Space" {
                commandText += " "
            } else if !stroke.isNamed, stroke.modifiers.isEmpty {
                commandText += stroke.key
            }
        case .hint:
            guard !stroke.isNamed, stroke.modifiers.isEmpty else { return }
            hintText += stroke.key
            let matches = hintTargets.filter { $0.label.hasPrefix(hintText) }
            if let only = matches.first, matches.count == 1, only.label == hintText {
                jump(to: only.target)
            } else if matches.isEmpty {
                engine.enter(.normal)
                hintText = ""
            }
        default:
            break
        }
    }

    // MARK: Commands

    func perform(_ command: CommandInvocation) {
        let count = command.count ?? 1
        switch command.name {
        case "row.next": moveRow(by: count)
        case "row.prev": moveRow(by: -count)
        case "row.first": setRow(command.count.map { $0 - 1 } ?? 0)
        case "row.last": setRow(command.count.map { $0 - 1 } ?? Int.max)
        case "session.attention":
            view = .sessions
            if let next = list.nextNeedingYou(after: cursor) { setCursor(next) } else { flash = "nobody needs you" }
        case "session.pin": togglePin()
        case "session.park": updateCurrent { $0.parked.toggle() }
        case "session.close": closeCurrent()
        case "session.back": goBack()
        case "pin.jump": jumpToPin(Int(command.arguments.first ?? "") ?? 1)
        case "work.start": openStartWork(prompt: command.arguments.joined(separator: " "))
        case "work.again": openStartWork(prompt: currentSession?.prompt ?? "")
        case "worktree.new": openStartWork(prompt: "")
        case "repo.scan", "repo.add": rescan()
        case "pane.left": updateTab { $0.focus(.left) }
        case "pane.right": updateTab { $0.focus(.right) }
        case "pane.up": updateTab { $0.focus(.up) }
        case "pane.down": updateTab { $0.focus(.down) }
        case "pane.split.right": split(.horizontal)
        case "pane.split.below": split(.vertical)
        case "pane.zoom": updateTab { $0.zoomed.toggle() }
        case "pane.close": closePane()
        case "tab.next": cycleTab(by: count)
        case "tab.prev": cycleTab(by: -count)
        case "tab.new": newTab()
        case "view": if let target = AppView(rawValue: command.arguments.first ?? "") { view = target }
        case "view.history": view = .history
        case "view.repos": view = .repos
        case "overlay.help": overlay = overlay == .help ? nil : .help
        case "overlay.diff": toggleDiff()
        case "diff.hunk.next": jumpHunk(by: 1)
        case "diff.hunk.prev": jumpHunk(by: -1)
        case "diff.file.next": moveDiffFile(by: 1)
        case "diff.file.prev": moveDiffFile(by: -1)
        case "diff.scope.next": cycleDiffScope(by: 1)
        case "diff.scope.prev": cycleDiffScope(by: -1)
        case "diff.commit": cycleDiffCommit()
        case "diff.split": diffSplit.toggle()
        case "diff.ask": askAboutHunk()
        case "diff.copy": copyDiffLocation()
        case "diff.edit": openDiffFile()
        case "overlay.close": closeTopmost()
        case "inspector.toggle": inspectorVisible.toggle()
        case "sidebar.toggle": sidebarCollapsed.toggle()
        case "mode.normal", "mode.insert", "mode.visual", "mode.command", "mode.hint":
            if command.name == "mode.insert", view != .sessions || currentTab == nil { engine.enter(.normal) }
            hintThenInsert = false
        case "hint.insert":
            engine.enter(.hint)
            hintThenInsert = true
        case "command.submit": submitCommandLine()
        case "command.complete": completeCommandLine()
        case "select.toggle": toggleRow()
        case "select.copy": copySelectedPaths()
        case "select.open": openSelected()
        case "select.remove": removeSelected()
        case "session.filter": startFilter()
        case "github.sync": Task { await syncGitHub() }
        case "items.start": startFromItems()
        case "items.add": addItemsToSession()
        case "items.read": markItemsRead()
        case "items.filter": inboxFilter = inboxFilter.next
        case "open.reader": openReader()
        case "open.browser": openInBrowser()
        case "overlay.pr": togglePullOverlay()
        case "pr.next": cyclePull(by: 1)
        case "pr.prev": cyclePull(by: -1)
        case "jump.back": closeReaderOrOverlay()
        case "feedback.queue": toggleQueued()
        case "feedback.send": if let ref = feedbackPull { deliver(ref, explicit: true) }
        case "feedback.mode": updateFeedback { $0.autoFeed = $0.autoFeed.next }
        case "feedback.watch": updateFeedback { $0.watching.toggle() }
        case "feedback.dismiss": dismissItem()
        case "feedback.session": startFromPull()
        case "pr.session": jumpToPullSession()
        case "history.reopen": reopenSelected()
        case "history.again": openStartWork(prompt: selectedHistory?.session.prompt ?? "")
        case "history.outcome": cycleOutcome()
        case "app.quit": NSApp.terminate(nil)
        case "config.edit": NSWorkspace.shared.open(configFile)
        case "settings.open": openSettings?()
        default:
            flash = "\(command.name): not built yet"
        }
    }

    /// `<Esc>` in NORMAL: the reader, an overlay, then back from a view to Sessions.
    private func closeTopmost() {
        if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        } else if view != .sessions {
            view = .sessions
        }
    }

    private func submitCommandLine() {
        let line = commandText.trimmingCharacters(in: .whitespaces)
        engine.enter(.normal)
        commandText = ""
        guard !line.isEmpty else { return }
        let invocation = CommandAliases.resolve(line)
        guard Commands.spec(invocation.name) != nil else {
            flash = "unknown command: \(invocation.name)"
            return
        }
        perform(invocation)
    }

    private func completeCommandLine() {
        let matches = Commands.complete(commandText)
        if matches.count == 1 { commandText = matches[0].name + (matches[0].arguments == nil ? "" : " ") }
    }

    var commandCompletions: [CommandSpec] {
        guard mode == .command, !commandText.contains(" ") else { return [] }
        return Array(Commands.complete(commandText).prefix(8))
    }

    // MARK: Rows

    private func moveRow(by delta: Int) {
        if overlay == .diff {
            let count = diffRows.count
            if count > 0 { diffRow = min(max(diffRow + delta, 0), count - 1) }
            return
        }
        if feedbackPull != nil, overlay == .pr || reader != nil {
            let count = feedbackItems.count
            if count > 0 { feedbackCursor = min(max(feedbackCursor + delta, 0), count - 1) }
            return
        }
        switch view {
        case .repos: setRow(repoCursor + delta)
        case .history: setRow(historyCursor + delta)
        case .inbox, .issues, .prs: setRow((itemCursor[view] ?? 0) + delta)
        case .sessions: setCursor(cursor + delta)
        }
    }

    private func setRow(_ index: Int) {
        if [.inbox, .issues, .prs].contains(view) {
            let count = itemIDs(view).count
            guard count > 0 else { return }
            itemCursor[view] = min(max(index, 0), count - 1)
        } else if view == .history {
            let count = historyRows.count
            guard count > 0 else { return }
            historyCursor = min(max(index, 0), count - 1)
        } else if view == .repos {
            let count = worktreeRows.count
            guard count > 0 else { return }
            repoCursor = min(max(index, 0), count - 1)
        } else {
            setCursor(index)
        }
    }

    private func setCursor(_ index: Int) {
        let count = list.ordered.count
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        if clamped != cursor { previousSessionID = currentSession?.id }
        cursor = clamped
    }

    private func select(sessionID: String) {
        if let index = list.ordered.firstIndex(where: { $0.id == sessionID }) { setCursor(index) }
    }

    private func goBack() {
        guard let previous = previousSessionID else { return }
        select(sessionID: previous)
    }

    private func jumpToPin(_ number: Int) {
        let pins = list.pins
        guard pins.indices.contains(number - 1) else {
            flash = "no pinned session \(number)"
            return
        }
        view = .sessions
        select(sessionID: pins[number - 1].id)
    }

    private func togglePin() {
        guard let session = currentSession else { return }
        if !session.pinned, list.pins.count >= SessionGroup.maxPins {
            flash = "already \(SessionGroup.maxPins) pins; unpin one first"
            return
        }
        updateCurrent { $0.pinned.toggle() }
    }

    /// Edits the current session and keeps the cursor on it, even when the edit moves it to another group.
    private func updateCurrent(_ edit: (inout Session) -> Void) {
        guard var session = currentSession else { return }
        edit(&session)
        commit(.sessionUpserted(session))
        select(sessionID: session.id)
    }

    private func closeCurrent() {
        guard var session = currentSession else { return }
        let id = session.id
        let minutes = Int(Date().timeIntervalSince(session.createdAt) / 60)
        session.record("ended after \(minutes / 60)h \(minutes % 60)m")
        commit(.sessionClosed(HistoryEntry(
            session: session, closedAt: Date(), outcome: HistoryEntry.outcome(closing: session)
        )))
        for pane in layouts[id]?.tabs.flatMap(\.tree.panes) ?? [] {
            TerminalSurfaces.shared.close(paneID: pane.id)
        }
        cursor = min(cursor, max(list.ordered.count - 1, 0))
        flash = "closed; worktree kept · in history (gh)"
    }

    private func jump(to target: HintTarget) {
        let thenInsert = hintThenInsert
        hintThenInsert = false
        hintText = ""
        switch target {
        case let .session(id):
            select(sessionID: id)
            engine.enter(.normal)
        case let .pane(id):
            updateTab { $0.focused = id }
            engine.enter(thenInsert ? .insert : .normal)
            if thenInsert { terminalFocusRequest += 1 }
        }
    }

    // MARK: Repos view

    private func toggleRow() {
        if view == .inbox || view == .issues {
            let ids = itemIDs(view)
            let index = itemCursor[view] ?? 0
            guard ids.indices.contains(index) else { return }
            if picked[view, default: []].contains(ids[index]) {
                picked[view]?.remove(ids[index])
            } else {
                picked[view, default: []].insert(ids[index])
            }
            return
        }
        let rows = worktreeRows
        guard view == .repos, rows.indices.contains(repoCursor) else { return }
        let id = rows[repoCursor].id
        if toggledRows.contains(id) { toggledRows.remove(id) } else { toggledRows.insert(id) }
    }

    private var actionRows: [Worktree] {
        let rows = worktreeRows
        let selected = selectedRows
        if !selected.isEmpty { return rows.filter { selected.contains($0.id) } }
        return rows.indices.contains(repoCursor) ? [rows[repoCursor]] : []
    }

    private func copySelectedPaths() {
        let paths = actionRows.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flash = "copied \(paths.count) path\(paths.count == 1 ? "" : "s")"
        engine.enter(.normal)
        modeChanged(from: .visual)
    }

    private func openSelected() {
        guard let row = actionRows.first else { return }
        engine.enter(.normal)
        modeChanged(from: .visual)
        if let session = session(for: row) {
            view = .sessions
            select(sessionID: session.id)
        } else {
            flash = "no session for \(row.branch ?? row.path)"
        }
    }

    private func removeSelected() {
        flash = "removing worktrees comes with the cleanup sweep (step 9)"
        engine.enter(.normal)
        modeChanged(from: .visual)
    }

    private func rescan() {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "scanning \(settings.repoRoots.joined(separator: ", "))…"
        Task {
            await refreshRepos()
            flash = "\(repos.count) repos · \(worktreeRows.count) worktrees"
        }
    }

    // MARK: History

    /// History in display order (newest first), filtered by `/` text and the outcome chip.
    var historyRows: [HistoryEntry] {
        let filter = historyFilter.lowercased()
        return history.filter { entry in
            (historyOutcome == nil || entry.outcome == historyOutcome)
                && (filter.isEmpty || [entry.session.title, entry.session.prompt, entry.session.branch]
                    .contains { $0.lowercased().contains(filter) })
        }
    }

    var selectedHistory: HistoryEntry? {
        let rows = historyRows
        return rows.indices.contains(historyCursor) ? rows[historyCursor] : nil
    }

    private func cycleOutcome() {
        let all: [Outcome?] = [nil] + Outcome.allCases
        let index = all.firstIndex(of: historyOutcome) ?? 0
        historyOutcome = all[(index + 1) % all.count]
        historyCursor = 0
    }

    private func reopenSelected() {
        guard let entry = selectedHistory else { return }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        let domain = currentDomain
        let settings = settings
        let integration = integration
        flash = "reopening \(entry.session.title)…"
        Task {
            do {
                let changes = try await Reopen.execute(
                    entry,
                    domain: domain,
                    settings: settings,
                    integration: integration
                )
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                view = .sessions
                select(sessionID: entry.id)
                flash = "reopened \(entry.session.title)"
            } catch {
                flash = "reopen failed: \(error)"
            }
        }
    }

    // MARK: GitHub lists

    var inboxRows: [InboxItem] { github.inbox.filter(inboxFilter.matches) }

    func itemIDs(_ view: AppView) -> [String] {
        switch view {
        case .inbox: inboxRows.map(\.id)
        case .issues: github.issues.map(\.id)
        case .prs: github.pulls.map(\.id)
        default: []
        }
    }

    func cursor(in view: AppView) -> Int { itemCursor[view] ?? 0 }

    /// Picked ids in a list: toggled ones plus the VISUAL range.
    func pickedIDs(_ view: AppView) -> Set<String> {
        var result = picked[view] ?? []
        if mode == .visual, self.view == view, let anchor = visualAnchor {
            let ids = itemIDs(view)
            let current = cursor(in: view)
            for index in min(anchor, current) ... max(anchor, current) where ids.indices.contains(index) {
                result.insert(ids[index])
            }
        }
        return result
    }

    /// What `s`, `a`, `m` act on: the picked items, else the one under the cursor.
    private func actionIDs(_ view: AppView) -> [String] {
        let ids = itemIDs(view)
        let chosen = pickedIDs(view)
        if !chosen.isEmpty { return ids.filter(chosen.contains) }
        let index = cursor(in: view)
        return ids.indices.contains(index) ? [ids[index]] : []
    }

    private func clearPicks() {
        picked[view] = []
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
    }

    private var itemsPrompt: String {
        let ids = actionIDs(view)
        switch view {
        case .issues: return WorkPrompt.from(issues: github.issues.filter { ids.contains($0.id) })
        case .inbox:
            let items = inboxRows.filter { ids.contains($0.id) }
            // Issues in the inbox get their full text when Issues has it.
            let issues = items.compactMap { item in
                github.issues.first { $0.repo == item.repo && $0.number == item.number }
            }
            return issues.count == items.count ? WorkPrompt.from(issues: issues) : WorkPrompt.from(inbox: items)
        default: return ""
        }
    }

    var itemsPromptPreview: String { itemsPrompt }

    private func startFromItems() {
        let prompt = itemsPrompt
        guard !prompt.isEmpty else { return }
        clearPicks()
        openStartWork(prompt: prompt)
    }

    private func addItemsToSession() {
        let prompt = itemsPrompt
        guard !prompt.isEmpty, let session = currentSession, let layout = layouts[session.id],
              let (_, paneID) = agentPane(in: layout)
        else {
            flash = "no session to add to"
            return
        }
        guard session.state.state != .blocked, session.state.state != .asking else {
            flash = "\(session.title) is waiting on you; answer it first"
            return
        }
        TerminalSurfaces.shared.typeLine(prompt.replacingOccurrences(of: "\n", with: " "), paneID: paneID)
        clearPicks()
        flash = "added to \(session.title)"
    }

    private func markItemsRead() {
        guard view == .inbox else { return }
        let ids = actionIDs(.inbox)
        guard !ids.isEmpty else { return }
        commit(.inboxRead(ids))
        clearPicks()
        guard !isFixture else { return }
        Task {
            for id in ids {
                try? await GitHub.markRead(threadID: id)
            }
        }
    }

    private var urlUnderCursor: String? {
        if let ref = feedbackPull { return pullDetails[ref.description].map { _ in ref.url } ?? ref.url }
        let index = cursor(in: view)
        switch view {
        case .inbox: return inboxRows.indices.contains(index) ? inboxRows[index].url : nil
        case .issues: return github.issues.indices.contains(index) ? github.issues[index].url : nil
        case .prs: return github.pulls.indices.contains(index) ? github.pulls[index].url : nil
        case .sessions: return currentSession?.trackedPRs.first?.url
        default: return nil
        }
    }

    private func openInBrowser() {
        guard let text = urlUnderCursor, let url = URL(string: text) else {
            flash = "nothing to open"
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func jumpToPullSession() {
        let ref: PullRef
        if let open = feedbackPull, overlay == .pr || reader != nil {
            ref = open
        } else {
            let index = cursor(in: .prs)
            guard view == .prs, github.pulls.indices.contains(index) else { return }
            ref = github.pulls[index].ref
        }
        reader = nil
        overlay = nil
        if let session = sessions.first(where: { $0.trackedPRs.contains(ref) }) {
            view = .sessions
            select(sessionID: session.id)
        } else {
            flash = "no session tracks \(ref)"
        }
    }

    // MARK: PR overlay, reader and feedback

    /// The PR the overlay or reader is about.
    var feedbackPull: PullRef? { reader ?? (overlay == .pr ? overlayPull : nil) }

    /// Items in display order: open ones first (queued, new, sent, addressed), then resolved.
    var feedbackItems: [FeedbackItem] {
        guard let ref = feedbackPull, let pipeline = feedback[ref.description] else { return [] }
        let order: [FeedbackItem.Status] = [.queued, .new, .sent, .addressed, .resolved]
        return pipeline.items.sorted { order.firstIndex(of: $0.status)! < order.firstIndex(of: $1.status)! }
    }

    /// The PR under the cursor where `o` was pressed: a PRs row, a PR in the inbox, or the session's first PR.
    private var pullUnderCursor: PullRef? {
        let index = cursor(in: view)
        switch view {
        case .prs: return github.pulls.indices.contains(index) ? github.pulls[index].ref : nil
        case .inbox:
            guard inboxRows.indices.contains(index), inboxRows[index].kind == .pr,
                  let number = inboxRows[index].number else { return nil }
            return PullRef(repo: inboxRows[index].repo, number: number)
        case .sessions: return currentSession?.trackedPRs.first
        default: return nil
        }
    }

    private func openReader() {
        guard let ref = pullUnderCursor else {
            openInBrowser()
            return
        }
        reader = ref
        feedbackCursor = 0
        fetchDetail(ref)
    }

    private func togglePullOverlay() {
        if overlay == .pr {
            overlay = nil
            return
        }
        guard let first = currentSession?.trackedPRs.first else {
            flash = "this session tracks no PR yet"
            return
        }
        overlayPull = overlayPull.flatMap { currentSession?.trackedPRs.contains($0) == true ? $0 : nil } ?? first
        overlay = .pr
        feedbackCursor = 0
        if let ref = overlayPull { fetchDetail(ref) }
    }

    private func cyclePull(by delta: Int) {
        guard overlay == .pr, let prs = currentSession?.trackedPRs, !prs.isEmpty else { return }
        let index = overlayPull.flatMap { prs.firstIndex(of: $0) } ?? 0
        overlayPull = prs[((index + delta) % prs.count + prs.count) % prs.count]
        feedbackCursor = 0
        if let ref = overlayPull { fetchDetail(ref) }
    }

    private func closeReaderOrOverlay() {
        if reader != nil { reader = nil } else if overlay != nil { overlay = nil } else { goBack() }
    }

    private func updateFeedback(_ edit: (inout PullFeedback) -> Void) {
        guard let ref = feedbackPull else { return }
        var pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
        edit(&pipeline)
        commit(.feedbackChanged(pipeline))
        if pipeline.autoFeed == .auto { deliver(ref, explicit: false) }
    }

    private func toggleQueued() {
        let items = feedbackItems
        guard items.indices.contains(feedbackCursor) else { return }
        let id = items[feedbackCursor].id
        updateFeedback { pipeline in
            guard let index = pipeline.items.firstIndex(where: { $0.id == id }) else { return }
            switch pipeline.items[index].status {
            case .new: pipeline.items[index].status = .queued
            case .queued: pipeline.items[index].status = .new
            default: break
            }
        }
    }

    private func dismissItem() {
        let items = feedbackItems
        guard items.indices.contains(feedbackCursor) else { return }
        let id = items[feedbackCursor].id
        updateFeedback { pipeline in pipeline.items.removeAll { $0.id == id } }
    }

    private func startFromPull() {
        guard let ref = feedbackPull else { return }
        let detail = pullDetails[ref.description]
        let pipeline = feedback[ref.description]
        var prompt = "Continue PR \(ref.repo.name)#\(ref.number): \(detail?.title ?? "")"
        if let open = pipeline?.items.filter({ $0.status != .resolved }), !open.isEmpty {
            prompt += "\n" + open.map { "- " + $0.promptLine }.joined(separator: "\n")
        }
        reader = nil
        overlay = nil
        openStartWork(prompt: prompt)
    }

    /// Fetches a PR's detail off the main actor; the merge into its pipeline happens in `commit`. Reports checks that
    /// went from failing to passing (the CI loop).
    func fetchDetail(_ ref: PullRef) {
        guard !isFixture else { return }
        Task {
            guard let detail = try? await GitHub.pullDetail(ref) else { return }
            let before = feedback[ref.description]?.items.filter { $0.status != .resolved }.map(\.id) ?? []
            commit(.pullDetailFetched(detail))
            let fixed = feedback[ref.description]?.items
                .filter { before.contains($0.id) && $0.status == .resolved } ?? []
            let checks = fixed.compactMap { if case let .check(name) = $0.kind { name } else { nil } }
            if !checks.isEmpty { flash = "\(checks.joined(separator: ", ")) passing now on #\(ref.number)" }
            if feedback[ref.description]?.autoFeed == .auto { deliver(ref, explicit: false) }
        }
    }

    /// Details for every PR an active session tracks and watches, so auto-feed sees new feedback.
    private func refreshWatchedDetails() async {
        let refs = Set(sessions.flatMap(\.trackedPRs)).filter { feedback[$0.description]?.watching ?? true }
        for ref in refs.prefix(10) {
            fetchDetail(ref)
        }
    }

    /// Sends a PR's queued feedback to the session tracking it, as one prompt, when delivery allows.
    func deliver(_ ref: PullRef, explicit: Bool) {
        guard var pipeline = feedback[ref.description], let prompt = pipeline.prompt() else {
            if explicit { flash = "nothing queued (space queues an item)" }
            return
        }
        guard explicit || (pipeline.autoFeed == .auto && pipeline.watching && !pipeline.roundsExhausted) else {
            if pipeline.roundsExhausted, pipeline.autoFeed == .auto {
                flash = "auto-feed stopped on #\(ref.number): \(PullFeedback.maxRounds) rounds without a new approval"
            }
            return
        }
        guard var session = sessions.first(where: { $0.trackedPRs.contains(ref) }), let layout = layouts[session.id],
              let (_, paneID) = agentPane(in: layout)
        else {
            if explicit { flash = "no session tracks #\(ref.number)" }
            return
        }
        switch Delivery.verdict(state: session.state.state, lastTyped: lastTyped[session.id]) {
        case let .wait(reason):
            pendingDelivery.insert(ref)
            if explicit { flash = "waiting: \(reason); it goes once the agent is idle" }
        case .deliver:
            guard !isFixture else {
                flash = "fixture: no IO"
                return
            }
            pendingDelivery.remove(ref)
            TerminalSurfaces.shared.typeLine(prompt, paneID: paneID)
            let count = pipeline.queued.count
            pipeline.markSent(at: pullDetails[ref.description]?.headSHA)
            session.record("sent \(count) feedback item\(count == 1 ? "" : "s") for #\(ref.number)")
            commit([.feedbackChanged(pipeline), .sessionUpserted(session)])
            flash = "sent \(count) item\(count == 1 ? "" : "s") to \(session.title)"
        }
    }

    // MARK: Diff overlay

    /// One row of the current file: a hunk header or a line.
    enum DiffRow: Hashable {
        case header(hunk: Int, text: String)
        case line(hunk: Int, DiffLine)
    }

    var currentDiffFile: FileDiff? { diffFiles.indices.contains(diffFileIndex) ? diffFiles[diffFileIndex] : nil }

    var diffRows: [DiffRow] {
        guard let file = currentDiffFile else { return [] }
        return file.hunks.enumerated().flatMap { index, hunk in
            [DiffRow.header(hunk: index, text: hunk.header)] + hunk.lines.map { DiffRow.line(hunk: index, $0) }
        }
    }

    private func toggleDiff() {
        if overlay == .diff {
            overlay = nil
            return
        }
        guard currentSession != nil else {
            flash = "no session"
            return
        }
        overlay = .diff
        loadDiff()
    }

    /// Diffs every worktree of the current session (cross-repo sessions show each repo's files), off the main actor.
    private func loadDiff() {
        guard let session = currentSession else { return }
        let targets = worktrees.filter { $0.branch == session.branch && session.repos.contains($0.repo) }
            .map { worktree in (worktree, repos.first { $0.repo == worktree.repo }?.defaultBranch ?? "main") }
        guard !targets.isEmpty, !isFixture else {
            diffFiles = isFixture ? Fixtures.diff : []
            diffCommits = isFixture ? Fixtures.diffCommits : []
            if !isFixture { flash = "no worktree for \(session.branch) yet" }
            return
        }
        let scope = diffScope
        diffLoading = true
        diffTask?.cancel()
        diffTask = Task {
            defer { diffLoading = false }
            var files: [FileDiff] = []
            for (worktree, base) in targets {
                if let diff = try? await Git.diff(at: worktree.path, scope: scope, base: base, repo: worktree.repo) {
                    files += diff
                }
            }
            let commits = await (try? Git.commits(at: targets[0].0.path, base: targets[0].1)) ?? []
            guard !Task.isCancelled else { return }
            diffFiles = files
            diffCommits = commits
            diffFileIndex = min(diffFileIndex, max(files.count - 1, 0))
            diffRow = 0
        }
    }

    private func jumpHunk(by delta: Int) {
        let rows = diffRows
        let headers = rows.indices.filter { if case .header = rows[$0] { true } else { false } }
        guard !headers.isEmpty else { return }
        if delta > 0 {
            if let next = headers.first(where: { $0 > diffRow }) { diffRow = next } else { moveDiffFile(by: 1) }
        } else if let previous = headers.last(where: { $0 < diffRow }) {
            diffRow = previous
        }
    }

    private func moveDiffFile(by delta: Int) {
        guard !diffFiles.isEmpty else { return }
        diffFileIndex = min(max(diffFileIndex + delta, 0), diffFiles.count - 1)
        diffRow = 0
    }

    private func cycleDiffScope(by delta: Int) {
        let cycle = DiffScope.cycle
        let index = cycle.firstIndex(of: diffScope) ?? 0
        diffScope = cycle[((index + delta) % cycle.count + cycle.count) % cycle.count]
        loadDiff()
    }

    private func cycleDiffCommit() {
        guard !diffCommits.isEmpty else {
            flash = "no commits on this branch yet"
            return
        }
        if case let .commit(sha) = diffScope, let index = diffCommits.firstIndex(where: { $0.sha == sha }),
           index + 1 < diffCommits.count
        {
            diffScope = .commit(diffCommits[index + 1].sha)
        } else if case .commit = diffScope {
            diffScope = .all
        } else {
            diffScope = .commit(diffCommits[0].sha)
        }
        loadDiff()
    }

    /// The file line under the cursor (the new side, else the old side).
    private var diffLocation: (path: String, line: Int)? {
        guard let file = currentDiffFile else { return nil }
        let rows = diffRows
        guard rows.indices.contains(diffRow) else { return (file.path, 1) }
        switch rows[diffRow] {
        case let .line(_, line): return (file.path, line.newNumber ?? line.oldNumber ?? 1)
        case let .header(hunk, _): return (file.path, file.hunks[hunk].newStart)
        }
    }

    private func copyDiffLocation() {
        guard let location = diffLocation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(location.path):\(location.line)", forType: .string)
        flash = "copied \(location.path):\(location.line)"
    }

    private func worktreePath(for file: FileDiff) -> String? {
        guard let session = currentSession else { return nil }
        return worktrees.first { $0.branch == session.branch && $0.repo == (file.repo ?? session.repos.first) }?.path
    }

    private func openDiffFile() {
        guard let file = currentDiffFile, let root = worktreePath(for: file) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.path))
    }

    /// Types a question about the hunk into the agent's pane, unsent, and switches to INSERT there to finish it.
    private func askAboutHunk() {
        guard let location = diffLocation, let session = currentSession, let layout = layouts[session.id],
              let (tabIndex, paneID) = agentPane(in: layout)
        else { return }
        TerminalSurfaces.shared.typeText(
            "About \(location.path) around line \(location.line) (the hunk in my diff): ",
            paneID: paneID
        )
        overlay = nil
        updateLayout { $0.activeTab = tabIndex }
        updateTab { $0.focused = paneID }
        engine.enter(.insert)
        terminalFocusRequest += 1
    }

    // MARK: Filter

    private func startFilter() {
        guard view == .sessions || view == .history else { return }
        filtering = true
    }

    private func typeFilter(_ stroke: KeyStroke) {
        var text = view == .history ? historyFilter : sessionFilter
        switch stroke {
        case .escape:
            text = ""
            filtering = false
        case KeyStroke("CR"):
            filtering = false
        case KeyStroke("BS"):
            if text.isEmpty { filtering = false } else { text.removeLast() }
        case KeyStroke("Space"):
            text += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.isEmpty else { return }
            text += stroke.key
        }
        if view == .history {
            historyFilter = text
            historyCursor = 0
        } else {
            sessionFilter = text
            cursor = 0
        }
    }

    // MARK: Start work

    private func openStartWork(prompt: String) {
        if view == .history { view = .sessions }
        startWork = StartWorkForm(
            repos: repos, history: sessions, settings: settings, prompt: prompt, integration: integration
        )
    }

    private func handleStartWork(_ stroke: KeyStroke) {
        guard var form = startWork else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            form.paste(text)
            startWork = form
            return
        }
        switch form.handle(stroke) {
        case .handled, .ignored:
            startWork = form
        case .cancel:
            startWork = nil
        case let .start(plan):
            startWork = form
            begin(plan)
        }
    }

    private func begin(_ plan: StartWorkPlan) {
        guard !startingWork else { return }
        guard !isFixture else {
            flash = "fixture: no IO"
            startWork = nil
            return
        }
        startingWork = true
        let settings = settings
        Task {
            defer { startingWork = false }
            do {
                let changes = try await StartWork.execute(plan, settings: settings)
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                startWork = nil
                view = .sessions
                if case let .sessionUpserted(session)? = changes.first(where: {
                    if case .sessionUpserted = $0 { true } else { false }
                }) {
                    select(sessionID: session.id)
                }
                flash = "started \(plan.name)"
            } catch {
                flash = "start work failed: \(error)"
            }
        }
    }

    // MARK: Panes and tabs

    private func updateLayout(_ edit: (inout SessionLayout) -> Void) {
        guard let id = currentSession?.id, var layout = layouts[id] else { return }
        edit(&layout)
        commit(.layoutChanged(session: id, layout))
    }

    private func updateTab(_ edit: (inout PaneTab) -> Void) {
        updateLayout { layout in
            guard layout.tabs.indices.contains(layout.activeTab) else { return }
            edit(&layout.tabs[layout.activeTab])
        }
    }

    private func split(_ axis: PaneTree.Axis) {
        guard let session = currentSession else { return }
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        updateTab { $0.split(axis, with: PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: directory)) }
    }

    private func closePane() {
        let closing = currentTab?.focused
        updateLayout { layout in
            guard layout.tabs.indices.contains(layout.activeTab) else { return }
            if !layout.tabs[layout.activeTab].closeFocused() {
                layout.tabs.remove(at: layout.activeTab)
                layout.activeTab = max(0, min(layout.activeTab, layout.tabs.count - 1))
            }
        }
        if let closing { TerminalSurfaces.shared.close(paneID: closing) }
        if currentTabs.isEmpty, mode == .insert { engine.enter(.normal) }
    }

    private func cycleTab(by delta: Int) {
        updateLayout { layout in
            let count = layout.tabs.count
            guard count > 0 else { return }
            layout.activeTab = ((layout.activeTab + delta) % count + count) % count
        }
    }

    private func newTab() {
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        updateLayout { layout in
            layout.tabs.append(PaneTab(title: "shell", tree: .leaf(PaneSpec(
                role: .shell, title: "zsh", directory: directory
            ))))
            layout.activeTab = layout.tabs.count - 1
        }
    }

    func selectTab(_ index: Int) {
        updateLayout { $0.activeTab = index }
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }
    func toggleInspector() { inspectorVisible.toggle() }

    func focusPane(_ paneID: String) {
        updateTab { $0.focused = paneID }
    }
}

/// One hook event, for the inspector's event list.
struct AgentEvent: Hashable {
    let at: Date
    let state: AgentState
    let reason: String?
}

enum InboxFilter: String, CaseIterable {
    case unread = "Unread", all = "All", review = "Review requested", assigned = "Assigned", ci = "CI"

    var next: InboxFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ item: InboxItem) -> Bool {
        switch self {
        case .unread: item.unread
        case .all: true
        case .review: item.reason == "review_requested"
        case .assigned: item.reason == "assign"
        case .ci: item.kind == .ci || item.reason == "ci_activity"
        }
    }
}

enum HintTarget: Hashable {
    case session(String)
    case pane(String)
}
