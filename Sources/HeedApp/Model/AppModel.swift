import AppKit
import HeedCore
import Observation

/// The app's views, switched with `g` keys (`gs`, `gm`, `gi`, `gp`, `gr`, `gh`).
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

    /// The command that switches to this view; its key comes from the live keymap.
    var command: String { "view.\(rawValue)" }
}

enum Overlay: Equatable {
    case help
    case pr
    case diff

    var name: String {
        switch self {
        case .help: "help"
        case .pr: "pr"
        case .diff: "diff"
        }
    }
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
    private(set) var sessions: [Session] = [] {
        didSet {
            rebuildList()
            if filters[.repos] != nil { rebuildWorktreeRows() }
            updateOutsideWindow()
        }
    }

    private(set) var layouts: [String: SessionLayout] = [:]
    private(set) var repos: [RepoRecord] = [] { didSet { if repos != oldValue { rebuildWorktreeRows() } } }
    private(set) var worktrees: [Worktree] = [] { didSet { if worktrees != oldValue { rebuildWorktreeRows() } } }
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
    /// Last commit date per worktree path, gathered with the repo refresh (sweep activity).
    private(set) var lastCommits: [String: Date] = [:]
    private var sweepTask: Task<Void, Never>?
    /// Results of pinned tasks by pane: the exit code of the last run.
    private(set) var taskResults: [String: Int] = [:]
    /// The first-run screen, while shown.
    private(set) var firstRun: FirstRunReport?
    /// Where git and gh were found, and the search path every command and pane runs with.
    private(set) var tools: ToolReport?
    /// Opens the Settings window (set by the view, which has the SwiftUI action).
    var openSettings: (() -> Void)?
    /// Nil for fixtures: nothing is persisted and no adapter runs.
    private var store: DomainStore?
    let isFixture: Bool
    private var hookServer: HookServer?
    /// Where the per-run hook files live. Screenshots show a made-up home, never the real one.
    let integration = ShotMode.active
        ? IntegrationFiles(
            directory: URL(fileURLWithPath: "/Users/you/Library/Application Support/Heed"),
            heedBinary: "/Applications/Heed.app/Contents/Helpers/heed"
        )
        : IntegrationFiles.default(heedBinary: Helper.path ?? "true")
    /// The latest hook events per session, newest first: shown in the inspector, not persisted (agents own history).
    private(set) var events: [String: [AgentEvent]] = [:]

    // Filtering (`/`): typed in the status bar while `filtering`, one filter per view; each view shows its own as a
    // pill.
    private(set) var filtering = false
    private(set) var filters: [AppView: String] = [:] {
        didSet {
            if filters[.sessions] != oldValue[.sessions] { rebuildList() }
            if filters[.repos] != oldValue[.repos] { rebuildWorktreeRows() }
        }
    }

    func filter(for view: AppView) -> String { filters[view] ?? "" }
    var sessionFilter: String { filter(for: .sessions) }
    private(set) var historyOutcome: Outcome?
    private(set) var historyCursor = 0

    // GitHub lists: cursor and picked ids per view
    private(set) var itemCursor: [AppView: Int] = [:]
    private(set) var picked: [AppView: Set<String>] = [:]
    private(set) var inboxFilter: InboxFilter = .unread
    private(set) var issueFilter: IssueFilter = .all
    /// The repo picked in the Issues repo column; nil is all of them.
    private(set) var issueRepo: Repo?

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
    private(set) var view: AppView = .sessions {
        didSet {
            updateScope()
            if view != oldValue { viewChangedForSync() }
        }
    }
    private(set) var overlay: Overlay? { didSet { updateScope() } }
    /// The PR open in the reader, over whatever view it was opened from.
    private(set) var reader: PullRef? { didSet { updateScope() } }
    /// The issue being read (`go` or ↩ on an issue).
    private(set) var issueReader: Issue? { didSet { updateScope() } }
    /// The PR the overlay shows (one of the current session's).
    private(set) var overlayPull: PullRef?
    private(set) var feedbackCursor = 0
    /// When you last typed into each session's panes; feedback waits after that.
    private var lastTyped: [String: Date] = [:]
    /// PRs with queued feedback waiting for their agent to be idle.
    private var pendingDelivery: Set<PullRef> = []

    /// Scoped key bindings follow what has focus: the diff, the PR overlay or reader, else the view.
    private func updateScope() {
        engine.scope = overlay == .diff ? "diff" : issueReader != nil ? "issue"
            : (overlay == .pr || reader != nil) ? "pr" : view.rawValue
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
    private(set) var startWork: StartWorkForm? {
        didSet {
            if startWork == nil, startWorkStandalone {
                startWorkStandalone = false
                StartWorkPanelController.shared.close()
            }
        }
    }

    /// The Start work dialog is showing in its own panel over other apps (`[keys] global_start_work`).
    private(set) var startWorkStandalone = false
    /// Why the last start failed, shown in the dialog (the standalone panel has no status bar).
    private(set) var startWorkError: String?
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
        if isFixture { config.issues = Fixtures.issueRules }
        replace(with: domain)
        updateScope()
    }

    // MARK: Domain

    /// Starts from the cache, then refreshes from git. The window is already up showing whatever the cache holds.
    func start(cache file: URL) async {
        startConfig()
        if !isFixture { await detectTools() }
        startHooks()
        let integration = integration
        Task.detached(priority: .utility) {
            do { try integration.write() } catch { NSLog("heed: could not write hook files: \(error)") }
        }
        let cached = await DomainStore.load(from: file)
        replace(with: cached)
        loadAvatars()
        store = DomainStore(domain: cached, file: file)
        await offerResume(domain: cached)
        startGitHubSync()
        startScreenReading()
        await refreshRepos()
        startSweepSchedule()
    }

    // MARK: Screen reading

    private var screenTask: Task<Void, Never>?

    /// Once a second, reads the agent pane of sessions whose agent does not report every state, and guesses the
    /// missing ones from the screen. Matching runs off the main actor; a guess never overrides a reported state.
    private func startScreenReading() {
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.readScreens()
            }
        }
    }

    private func readScreens() async {
        var work: [(String, String, ScreenGuess.Patterns, Set<AgentState>)] = []
        for session in sessions {
            guard let agent = settings.agent(session.agent) else { continue }
            let reported = ScreenGuess.reported(by: agent.name)
            guard reported.count < 7, let layout = layouts[session.id], let (_, paneID) = agentPane(in: layout),
                  let text = TerminalSurfaces.shared.visibleText(paneID: paneID)
            else { continue }
            work.append((session.id, text, ScreenGuess.patterns(for: agent), reported))
        }
        guard !work.isEmpty else { return }
        let guesses = await Task.detached(priority: .utility) {
            work.map { id, text, patterns, reported -> (String, AgentState?) in
                // Only states the agent cannot report are guessed, so such a guess may replace a reported state.
                let state = ScreenGuess.guess(text, patterns: patterns)
                return (id, state.flatMap { reported.contains($0) ? nil : $0 })
            }
        }.value
        var changes: [DomainChange] = []
        for (id, guess) in guesses {
            guard var session = sessions.first(where: { $0.id == id }) else { continue }
            let next: ObservedState
            if let guess {
                next = ObservedState(guess, source: .guessed, reason: "from the screen")
            } else if session.state.source == .guessed, [.blocked, .asking, .limited].contains(session.state.state) {
                // The prompt left the screen: the agent is past it.
                next = ObservedState(.working, source: .guessed, reason: "from the screen")
            } else {
                continue
            }
            guard next.state != session.state.state || next.source != session.state.source else { continue }
            session.state = next
            session.activity = "\(next.state.rawValue) · guessed"
            changes.append(.sessionUpserted(session))
        }
        commit(changes)
    }

    // MARK: Cleanup

    var sweepPlan: SweepPlan {
        Sweep.plan(domain: currentDomain, rule: config.cleanup, lastCommit: lastCommits)
    }

    /// Sweeps hourly unless config asks to be asked first; `gs` always runs one now.
    private func startSweepSchedule() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self, config.cleanup.enabled, !self.config.cleanup.askBeforeSweep else { continue }
                await refreshRepos()
                await runSweep(explicit: false)
            }
        }
    }

    func runSweep(explicit: Bool) async {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        guard config.cleanup.enabled else {
            if explicit {
                flash = "automatic cleanup is off ([cleanup] enabled, or Settings); dd removes worktrees by hand"
            }
            return
        }
        let plan = sweepPlan
        guard !plan.removals.isEmpty else {
            if explicit { flash = plan.summary }
            return
        }
        let (changes, failures) = await Sweep.execute(plan, domain: currentDomain)
        commit(changes)
        flash = failures.isEmpty
            ? "cleaned up \(plan.removals.count) worktree\(plan.removals.count == 1 ? "" : "s")"
            : "cleanup: \(failures.count) failed: \(failures[0])"
    }

    // MARK: GitHub

    private var githubTask: Task<Void, Never>?
    private(set) var syncing = false

    private var syncSchedule = SyncSchedule()

    /// Syncs now and then every `poll_seconds`: what the window shows each time, the rest every fifth time. A failed
    /// sync keeps the cached data and marks it offline.
    private func startGitHubSync() {
        githubTask?.cancel()
        githubTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await syncGitHub(force: false)
                try? await Task.sleep(for: .seconds(syncSchedule.front))
            }
        }
    }

    /// The parts the window is showing now.
    private var frontParts: Set<GitHubPart> {
        switch view {
        case .inbox: [.inbox]
        case .issues: [.issues]
        // Sessions show their PRs' state; Repos and History their PR numbers.
        case .sessions, .prs, .repos, .history: [.pulls]
        }
    }

    /// `force` (gr refresh, :github.sync, signing in): every part. Otherwise what is due; `parts` asks for some now.
    func syncGitHub(force: Bool = true, parts wanted: Set<GitHubPart> = []) async {
        guard !isFixture, !syncing else { return }
        syncSchedule.front = TimeInterval(config.githubPollSeconds)
        let parts = wanted.isEmpty ? syncSchedule.due(now: Date(), front: frontParts, force: force) : wanted
        guard !parts.isEmpty else {
            await refreshWatchedDetails()
            return
        }
        syncing = true
        defer { syncing = false }
        let previous = github
        let tracked = Array(Set(sessions.flatMap(\.trackedPRs)))
        do {
            let state = try await GitHub.sync(
                parts: parts, tracked: tracked, previous: previous, issueRules: config.issues,
                localRepos: repos.map(\.repo)
            )
            syncSchedule.fetched(parts, at: Date())
            commit([.githubSynced(state)] + PullTracking.changes(sessions: sessions, pulls: state.pulls))
            await refreshWatchedDetails()
        } catch {
            var offline = previous
            offline.status = .offline("\(error)")
            commit(.githubSynced(offline))
        }
    }

    /// Switching to a view whose data is older than a poll fetches it right away instead of on the next tick.
    private func viewChangedForSync() {
        guard !isFixture, github.syncedAt != nil else { return }
        let due = syncSchedule.due(now: Date(), front: frontParts).intersection(frontParts)
        if !due.isEmpty { Task { await syncGitHub(parts: due) } }
    }

    // MARK: Resume on launch

    /// Works out what to resume (checking which agent sessions still exist, off the main actor) and asks, resumes or
    /// does nothing, per `resumeOnLaunch`.
    /// `asked`: `:resume`, which always shows the dialog (never resuming silently) and says when there is nothing.
    private func offerResume(domain: Domain, asked: Bool = false) async {
        guard asked || settings.resumeOnLaunch != .never, !domain.sessions.isEmpty else {
            if asked { flash = "no sessions to resume" }
            return
        }
        guard !isFixture else {
            if asked { showResumeForFixture() }
            return
        }
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
        guard !candidates.isEmpty else {
            if asked { flash = "nothing to resume: every session's agent is running or gone" }
            return
        }
        if settings.resumeOnLaunch == .always, !asked {
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
        if watcher.createdFile { showFirstRun() }
    }

    /// Opens the first-run screen and fills it in as gh and the agent lookups answer.
    func showFirstRun(report: FirstRunReport? = nil) {
        firstRun = report ?? FirstRunReport()
        guard report == nil, !isFixture else { return }
        // Re-checks every few seconds while the screen is open, so `gh auth login` or installing an agent in another
        // terminal shows up without a restart.
        firstRunTask?.cancel()
        firstRunTask = Task { [weak self] in
            while !Task.isCancelled, self?.firstRun != nil {
                await self?.refreshFirstRun()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var firstRunTask: Task<Void, Never>?
    private(set) var firstRunChecking = false

    /// Gathers the report again (`r`, or on its own every few seconds). Signing in to gh starts a GitHub sync now.
    func refreshFirstRun() async {
        guard firstRun != nil, !firstRunChecking else { return }
        firstRunChecking = true
        defer { firstRunChecking = false }
        let wasSignedIn = firstRun?.githubUser != nil
        let gathered = await FirstRunReport.gather(agents: settings.agents)
        guard firstRun != nil else { return }
        firstRun = gathered
        if !wasSignedIn, gathered.githubUser != nil { await syncGitHub() }
    }

    /// Every org Heed shows: repos, sessions, GitHub items.
    private func loadAvatars() {
        guard !isFixture else { return }
        let orgs = repos.map(\.repo.org) + sessions.flatMap(\.repos).map(\.org) + github.pulls.map(\.ref.repo.org)
            + github.inbox.map(\.repo.org) + github.issues.map(\.repo.org)
        // "local" stands for repos without a GitHub remote; github.com/local is someone else.
        Avatars.shared.load(orgs.filter { $0 != "local" })
    }

    func applyConfig(source: String) {
        let (decoded, problems) = ConfigLoader.decode(source)
        configProblems = problems
        guard let decoded else { return }
        let toolsChanged = decoded.tools != config.tools
        let issuesChanged = decoded.issues != config.issues
        config = decoded
        settings = decoded.work
        let built = decoded.keymaps()
        engine.setKeymaps(built.keymaps, scoped: built.scoped)
        updateScope()
        keyProblems = built.problems
        Palette.shared.apply(decoded)
        if !isFixture {
            let shortcuts: [(GlobalHotKey.Name, String, () -> Void)] = [
                (.startWork, decoded.globalStartWork, { [weak self] in self?.openStandaloneStartWork() }),
                (.activate, decoded.globalActivate, { [weak self] in self?.activateHeed() }),
            ]
            for (name, notation, action) in shortcuts {
                if let problem = GlobalHotKey.register(name, notation, action: action) {
                    configProblems.append(ConfigProblem(path: "", message: problem))
                }
            }
        }
        updateOutsideWindow()
        if toolsChanged, !isFixture { Task { await detectTools() } }
        // Repos that now show all issues need fetching; ones that no longer do are hidden by issueRows right away.
        if issuesChanged, !isFixture, github.syncedAt != nil { Task { await syncGitHub(parts: [.issues]) } }
    }

    /// Finds git and gh (config, login shell PATH, usual places) and hands the search path to new panes.
    func detectTools(force: Bool = false) async {
        let report = await ToolLocator.shared.configure(config.tools, force: force)
        tools = report
        TerminalSurfaces.shared.searchPath = report.pathVariable
        if force {
            flash = report.problems.first
                ?? report.tools.map { "\($0.name): \(Paths.abbreviate($0.path ?? "?"))" }.joined(separator: "  ")
        }
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
            events[session.id] = AgentEvent.log(
                events[session.id] ?? [], adding: AgentEvent(at: message.sentAt, state: state, reason: reason)
            )
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
        let filter = sessionFilter
        list = SessionList(filter.isEmpty ? sessions : sessions.filter { session in
            FilterQuery.matches(
                filter,
                [session.title, session.branch, session.agent] + session.repos.map(\.name)
                    + session.trackedPRs.map { "#\($0.number)" }
            )
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
        if after.repos != before.repos || after.github.pulls != before.github.pulls { loadAvatars() }
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
        var found = await RepoScanner.scan(roots: settings.repoRoots)
        for path in settings.repoPaths {
            if let record = await Git.record(at: Paths.expand(path)), !found.contains(record) { found.append(record) }
        }
        commit(found.map { .repoUpserted($0) })
        // Every clone, not one per repo: two checkouts of the same GitHub repo (in ~/Projects and ~/code, say) share
        // one record, and each has worktrees of its own. A repo's list is committed once all its clones answered.
        let clones = Dictionary(grouping: found + repos.filter { !found.map(\.path).contains($0.path) }) { $0.repo }
        await withTaskGroup(of: [DomainChange].self) { group in
            for (repo, records) in clones {
                group.addTask {
                    var listed: [Worktree] = []
                    for record in records {
                        for worktree in await (try? Git.worktrees(of: record)) ?? []
                            where !listed.contains(where: { $0.path == worktree.path })
                        {
                            listed.append(worktree)
                        }
                    }
                    guard !listed.isEmpty else { return [] }
                    for index in listed.indices {
                        listed[index].status = try? await Git.status(at: listed[index].path)
                    }
                    return [.worktreesListed(repo: repo, listed)]
                }
            }
            for await changes in group {
                commit(changes)
            }
        }
        var commits: [String: Date] = [:]
        for worktree in worktrees where !worktree.isMain {
            if let date = await Git.lastCommitDate(at: worktree.path) { commits[worktree.path] = date }
        }
        lastCommits = commits
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

    // MARK: Title

    struct TitleContext: Equatable {
        var lead: String?
        var main: String
        var detail: String?
    }

    /// The title bar's middle: what is open, else what the cursor is on in the current view.
    var titleContext: TitleContext? {
        if let issue = issueReader { return TitleContext(
            lead: issue.repo.name,
            main: "#\(issue.number)",
            detail: issue.title
        ) }
        if let ref = reader ?? (overlay == .pr ? overlayPull : nil) { return pullContext(ref) }
        let index = cursor(in: view)
        switch view {
        case .sessions:
            guard let session = currentSession else { return nil }
            return TitleContext(
                lead: session.repos.first?.name, main: session.branch,
                detail: session.trackedPRs.first.map { "#\($0.number)" }
            )
        case .inbox:
            let rows = inboxRows
            guard rows.indices.contains(index) else { return nil }
            let item = rows[index]
            return TitleContext(
                lead: item.repo.name,
                main: item.number.map { "#\($0)" } ?? item.kind.rawValue,
                detail: item.title
            )
        case .issues:
            let rows = issueRows
            guard rows.indices.contains(index) else { return nil }
            return TitleContext(lead: rows[index].repo.name, main: "#\(rows[index].number)", detail: rows[index].title)
        case .prs:
            let rows = pullRows
            return rows.indices.contains(index) ? pullContext(rows[index].ref) : nil
        case .repos:
            guard worktreeRows.indices.contains(repoCursor) else { return nil }
            let worktree = worktreeRows[repoCursor]
            return TitleContext(lead: worktree.repo.name, main: worktree.branch ?? "detached \(worktree.head)")
        case .history:
            guard let entry = selectedHistory else { return nil }
            return TitleContext(
                lead: entry.session.repos.first?.name,
                main: entry.session.branch,
                detail: entry.session.title
            )
        }
    }

    private func pullContext(_ ref: PullRef) -> TitleContext {
        TitleContext(
            lead: ref.repo.name,
            main: "#\(ref.number)",
            detail: github.pull(ref)?.title ?? pullDetails[ref.description]?.title
        )
    }

    // The Repos view's lists, kept rather than computed on every read: the table reads them per row and per repo.
    /// Added worktrees (not main checkouts), in table order: grouped by repo in `sortedRepos` order, then by path;
    /// narrowed by the Repos `/` filter.
    private(set) var worktreeRows: [Worktree] = []
    /// Repos as Repos lists them: most worktrees first, then by name.
    private(set) var sortedRepos: [RepoRecord] = []
    /// Rows per repo slug in `worktreeRows`.
    private(set) var worktreeRowCounts: [String: Int] = [:]
    /// Every added worktree, whatever the filter.
    private(set) var worktreeCount = 0

    private func rebuildWorktreeRows() {
        let counts = RepoOrder.worktreeCounts(worktrees)
        sortedRepos = RepoOrder.sorted(repos, counts: counts)
        worktreeCount = counts.values.reduce(0, +)
        let rank = Dictionary(sortedRepos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let filter = filter(for: .repos)
        let added = worktrees.filter { !$0.isMain }
        let matching = filter.isEmpty ? added : added.filter { worktree in
            FilterQuery.matches(
                filter, [worktree.repo.slug, worktree.branch ?? "", worktree.path, session(for: worktree)?.agent ?? ""]
            )
        }
        worktreeRows = matching.sorted {
            $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        worktreeRowCounts = Dictionary(grouping: worktreeRows, by: \.repo.slug).mapValues(\.count)
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
    /// What `f` labels: in Sessions the sessions and the panes; elsewhere the rows of the view's list.
    var hintTargets: [(label: String, target: HintTarget)] {
        let targets: [HintTarget] = switch view {
        case .sessions:
            list.ordered
                .map { HintTarget.session($0.id) } + (currentTab?.tree.panes.map { HintTarget.pane($0.id) } ?? [])
        case .inbox, .issues, .prs: itemIDs(view).indices.map { HintTarget.row(view, $0) }
        case .repos: worktreeRows.indices.map { HintTarget.row(.repos, $0) }
        case .history: historyRows.indices.map { HintTarget.row(.history, $0) }
        }
        return zip(HintLabels.generate(count: targets.count), targets).map { ($0, $1) }
    }

    func hintLabel(for target: HintTarget) -> String? {
        guard mode == .hint else { return nil }
        return hintTargets.first { $0.target == target }?.label
    }

    // MARK: Keys

    /// Returns true when the key was used by the app, false when it should go on to the terminal.
    func handle(_ stroke: KeyStroke) -> Bool {
        let used = handleKey(stroke)
        if tutor != nil { observeTutor(stroke) }
        return used
    }

    private func handleKey(_ stroke: KeyStroke) -> Bool {
        if tutorPicker != nil {
            answerTutorPicker(stroke)
            return true
        }
        if answerFinishedTutor(stroke) { return true }
        // A step just done shows green; ↩ only dismisses it (it would otherwise open whatever is under the cursor).
        if tutor?.justDone != nil, stroke == KeyStroke("CR"), startWork == nil, confirmation == nil, overlay == nil,
           mode == .normal
        {
            return true
        }
        // `?` then `t`: the lesson for the view you are on.
        if overlay == .help, stroke == KeyStroke("t") {
            let lesson = Tutor.lessonID(forView: view.rawValue)
            overlay = nil
            onTutorRequest?(.start(lesson: lesson, world: nil))
            return true
        }
        if confirmation != nil {
            answerConfirmation(stroke)
            return true
        }
        if importPicker != nil {
            answerImportPicker(stroke)
            return true
        }
        if pathImport != nil {
            answerPathImport(stroke)
            return true
        }
        if firstRun != nil {
            if stroke == KeyStroke("CR") || stroke == KeyStroke("CR", .command) || stroke == .escape {
                firstRun = nil
                firstRunTask?.cancel()
            } else if stroke == KeyStroke("r") {
                Task { await refreshFirstRun() }
            } else if stroke == KeyStroke("e") {
                NSWorkspace.shared.open(configFile)
            } else if stroke == KeyStroke("t") {
                firstRun = nil
                firstRunTask?.cancel()
                onTutorRequest?(.start(lesson: Tutor.tour.id, world: nil))
            }
            return true
        }
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
            if var session = currentSession {
                let now = Date()
                lastTyped[session.id] = now
                if now.timeIntervalSince(session.lastActivity) > 60 {
                    session.lastActivity = now
                    commit(.sessionUpserted(session))
                }
            }
            return false
        case let .text(stroke):
            typeText(stroke)
        case .pending, .cleared:
            break
        case let .run(invocation):
            flash = nil
            perform(invocation)
        case let .unbound(keys):
            // A ⌘ shortcut Heed does not bind is the app menu's, as in any Mac app: ⌘W closes the window, ⌘Q quits,
            // ⌘H hides, ⌘M minimises.
            if keys.count == 1, keys[0].modifiers.contains(.command) { return false }
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
        case "row.halfpage.down": moveRow(by: 10 * count)
        case "row.halfpage.up": moveRow(by: -10 * count)
        case "group.next": moveGroup(forward: true)
        case "group.prev": moveGroup(forward: false)
        case "session.attention":
            view = .sessions
            if let next = list.nextNeedingYou(after: cursor) { setCursor(next) } else { flash = "nobody needs you" }
        case "session.pin": togglePin()
        case "session.park": updateCurrent { $0.parked.toggle() }
        case "session.close": confirmClose()
        case "session.delete": confirmDelete()
        case "session.import.path": openPathImport()
        case "session.import":
            if command.arguments.isEmpty {
                openImportPicker()
            } else {
                importPath(command.arguments.joined(separator: " "))
            }
        case "session.back": goBack()
        case "pin.jump": jumpToPin(Int(command.arguments.first ?? "") ?? 1)
        case "work.start" where command.arguments.first == "--agent":
            // `:agent codex`: Start work with that agent chosen.
            let name = command.arguments.dropFirst().first ?? ""
            openStartWork(prompt: "")
            if startWork?.choose(agent: name) == false {
                flash = "no agent \(name) (\(settings.agents.map(\.name).joined(separator: ", ")))"
            }
        case "work.start": openStartWork(prompt: command.arguments.joined(separator: " "))
        case "work.start.panel": openStandaloneStartWork()
        case "resume": Task { await offerResume(domain: currentDomain, asked: true) }
        case "session.open": openSession(matching: command.arguments.joined(separator: " "))
        case "tab.go":
            if let n = command.arguments.first.flatMap(Int.init) ?? command.count, currentTabs.indices.contains(n - 1) {
                selectTab(n - 1)
            } else {
                flash = "no tab \(command.arguments.first ?? "") (this session has \(currentTabs.count))"
            }
        case "filter.clear":
            filtering = false
            clearFilter(view)
        case "issues.repo": pickIssueRepo(named: command.arguments.first)
        case "app.activate": activateHeed()
        case "pr.track": trackPull(command.arguments.first)
        case "select.pin": pinSelected()
        case "work.again": openStartWork(prompt: currentSession?.prompt ?? "")
        case "worktree.new":
            openStartWork(prompt: "")
            if let repo = worktreeRows.indices.contains(repoCursor) ? worktreeRows[repoCursor].repo : nil {
                startWork?.choose(repo: repo.slug)
            }
        case "repo.scan": rescan()
        case "repo.add": addRepo(command.arguments.joined(separator: " "))
        case "cleanup.rules":
            view = .repos
            inspectorVisible = true
        case "pane.left": updateTab { $0.focus(.left) }
        case "pane.right": updateTab { $0.focus(.right) }
        case "pane.up": updateTab { $0.focus(.up) }
        case "pane.down": updateTab { $0.focus(.down) }
        case "pane.split.right": split(.horizontal)
        case "pane.split.below": split(.vertical)
        case "pane.zoom": updateTab { $0.zoomed.toggle() }
        case "pane.close": confirmClosePane()
        case "tab.next": cycleTab(by: count)
        case "tab.prev": cycleTab(by: -count)
        case "tab.new": newTab()
        case "view": if let target = AppView(rawValue: command.arguments.first ?? "") { view = target }
        case "view.history": view = .history
        case "view.repos": view = .repos
        case "view.sessions": view = .sessions
        case "view.inbox": view = .inbox
        case "view.issues": view = .issues
        case "view.prs": view = .prs
        case "overlay.help": overlay = overlay == .help ? nil : .help
        case "tutor": openTutor(command.arguments)
        case "tutor.back": if tutor == nil { flash = "the tutor is not running (:tutor starts it)" } else { tutorBack() }
        case "tutor.skip": if tutor == nil { flash = "the tutor is not running (:tutor starts it)" } else { tutorSkip() }
        case "tutor.exit": if tutor == nil { flash = "the tutor is not running" } else { onTutorRequest?(.exit) }
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
        case "select.remove": confirmRemoveSelected()
        case "session.filter": startFilter()
        case "cleanup.sweep": confirmSweep()
        case "github.sync": Task { await syncGitHub() }
        case "items.start": startFromItems()
        case "items.add": addItemsToSession()
        case "items.read": markItemsRead()
        case "items.filter":
            if view == .issues {
                issueFilter = issueFilter.next
                itemCursor[.issues] = 0
            } else {
                inboxFilter = inboxFilter.next
                itemCursor[.inbox] = 0
            }
        case "issues.repo.next": cycleIssueRepo(by: 1)
        case "issues.repo.prev": cycleIssueRepo(by: -1)
        case "issues.visibility": toggleIssueVisibility()
        case "open.reader": openReader()
        case "open.browser": openInBrowser()
        case "overlay.pr": togglePullOverlay()
        case "overlay.item": toggleItemOverlay()
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
        // :q in the tutor leaves the tutor, as its banner says; it never quits the app from there.
        case "app.quit": if tutor != nil { onTutorRequest?(.exit) } else { NSApp.terminate(nil) }
        case "config.edit": NSWorkspace.shared.open(configFile)
        case "tools.detect": Task { await detectTools(force: true) }
        case "settings.open":
            if let name = command.arguments.first {
                guard let section = SettingsView.Section.named(name) else {
                    flash = "no Settings section \(name) (general, agents, colors, cleanup, keys)"
                    return
                }
                settingsSection = section
            }
            openSettings?()
        case "welcome": showFirstRun()
        default:
            flash = "\(command.name): not built yet"
        }
    }

    /// `<Esc>` in NORMAL: the reader, an overlay, then back from a view to Sessions.
    private func closeTopmost() {
        if issueReader != nil {
            issueReader = nil
        } else if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        }
        // Never a view change: views are places of their own, not layers over Sessions.
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

    /// The current list's group of each row, and the cursor: sidebar groups, repos, days.
    private var rowGroups: (keys: [String], cursor: Int) {
        switch view {
        case .sessions: (list.ordered.map { SessionGroup.of($0).rawValue }, cursor)
        case .repos: (worktreeRows.map(\.repo.slug), repoCursor)
        case .inbox: (inboxRows.map(\.repo.slug), cursor(in: .inbox))
        case .issues: (issueRows.map(\.repo.slug), cursor(in: .issues))
        case .prs: (pullRows.map(\.ref.repo.slug), cursor(in: .prs))
        case .history:
            (historyRows.map { Calendar.current.startOfDay(for: $0.closedAt).description }, historyCursor)
        }
    }

    private func moveGroup(forward: Bool) {
        let (keys, from) = rowGroups
        let target = forward ? RowGroups.next(keys, from: from) : RowGroups.previous(keys, from: from)
        if let target { setRow(target) }
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

    // MARK: Confirmation

    /// A destructive action waiting for y (or ↩) / n (or ⎋, q).
    struct Confirmation {
        var title: String
        /// What will happen, one line each.
        var lines: [String]
        /// What will be left alone, and why.
        var kept: [String] = []
        var accept: String
        /// Red accept button for removals; neutral for the rest.
        var destructive = true
        var action: @MainActor () -> Void
    }

    private(set) var confirmation: Confirmation?

    private func ask(_ confirmation: Confirmation) {
        if mode == .insert {
            engine.enter(.normal)
            modeChanged(from: .insert)
        }
        self.confirmation = confirmation
    }

    private func answerConfirmation(_ stroke: KeyStroke) {
        switch stroke {
        case KeyStroke("y"), KeyStroke("CR"):
            let action = confirmation?.action
            confirmation = nil
            action?()
        case KeyStroke("n"), KeyStroke("q"), .escape:
            confirmation = nil
            flash = "cancelled"
        default:
            break
        }
    }

    func acceptConfirmation() { answerConfirmation(KeyStroke("y")) }
    func cancelConfirmation() { answerConfirmation(.escape) }

    /// Set once a quit was confirmed, so the second terminate goes through.
    private(set) var quitConfirmed = false

    /// ⌘Q or Quit in the menu bar with agents running: Heed comes forward and asks. True when it asked (the quit
    /// waits for the answer), false when nothing runs and quitting can go ahead.
    func confirmQuitIfAgentsRun() -> Bool {
        let running = sessions.filter { [.working, .blocked, .asking].contains($0.state.state) }
        guard !running.isEmpty, confirmation == nil else { return confirmation != nil }
        activateHeed()
        ask(Confirmation(
            title: "Quit Heed?",
            lines: ["\(running.count) agent\(running.count == 1 ? " is" : "s are") running and will stop"]
                + running.prefix(5).map { "\($0.title) · \($0.state.state.rawValue)" }
                + (running.count > 5 ? ["and \(running.count - 5) more"] : [])
                + ["Sessions stay and can resume on the next launch"],
            accept: "Quit"
        ) { [weak self] in
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        })
        return true
    }

    private func confirmClose() {
        guard let session = currentSession else { return }
        let running = [.working, .blocked, .asking].contains(session.state.state)
        ask(Confirmation(
            title: "Close \(session.title)?",
            lines: [
                running ? "\(session.agent) is \(session.state.state.rawValue): it stops with the panes" :
                    "Its panes close",
                "The worktree stays; the session moves to History, where R reopens it",
            ],
            accept: "Close"
        ) { [weak self] in self?.closeCurrent() })
    }

    /// `dd` in Sessions: the session and its worktrees. Worktrees with unsaved work are kept (and said so).
    private func confirmDelete() {
        guard let session = currentSession else { return }
        let mine = worktrees.filter { !$0.isMain && $0.branch == session.branch && session.repos.contains($0.repo) }
        let (removals, kept) = planRemoval(mine, sessionsFollow: false)
        ask(Confirmation(
            title: "Delete \(session.title)?",
            lines: ["The agent and its panes stop; the session moves to History"]
                + removals.map { removal in
                    "remove \(removal.worktree.repo.name)/\(removal.worktree.branch ?? "")"
                        + (removal.deleteBranch ? " and its local branch" : "")
                }
                + (mine.isEmpty ? ["No worktree to remove"] : []),
            kept: kept,
            accept: "Delete"
        ) { [weak self] in
            guard let self else { return }
            closeCurrent()
            if !removals.isEmpty { removeWorktrees(removals, kept: kept) }
        })
    }

    private func confirmSweep() {
        guard config.cleanup.enabled else {
            flash = "automatic cleanup is off ([cleanup] enabled, or Settings); dd in Repos removes worktrees by hand"
            return
        }
        let plan = sweepPlan
        guard !plan.removals.isEmpty else {
            flash = plan.summary
            return
        }
        ask(Confirmation(
            title: "Run the cleanup sweep?",
            lines: plan.removals.map {
                "remove \($0.worktree.repo.name)/\($0.worktree.branch ?? "") (\($0.idleText))"
            },
            kept: plan.skips.map { "\($0.worktree.repo.name)/\($0.worktree.branch ?? ""): \($0.reason)" },
            accept: "Sweep"
        ) { [weak self] in Task { await self?.runSweep(explicit: true) } })
    }

    /// Shell panes close at once; an agent pane asks, since its agent stops with it.
    private func confirmClosePane() {
        guard let tab = currentTab, let pane = tab.tree.panes.first(where: { $0.id == tab.focused }) else { return }
        guard pane.role == .agent else {
            closePane()
            return
        }
        ask(Confirmation(
            title: "Close the \(pane.title) pane?",
            lines: ["The agent in it stops; the session and its worktree stay"],
            accept: "Close"
        ) { [weak self] in self?.closePane() })
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
        case let .row(view, index):
            // f moves the cursor there; F also opens it.
            engine.enter(.normal)
            switch view {
            case .repos:
                repoCursor = index
                if thenInsert { openSelected() }
            case .history:
                historyCursor = index
            default:
                itemCursor[view] = index
                if thenInsert { openReader() }
            }
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

    /// `↩` in Repos (`o` in VISUAL): a worktree with a session jumps to it; ones without are imported as sessions,
    /// resuming the agent session kept there when there is one. Asks first, showing what each will resume.
    private func openSelected() {
        let rows = actionRows
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        openOrImport(rows)
    }

    // MARK: Import picker

    /// `I` in Sessions: pick a worktree without a session (main checkouts included) to import.
    private(set) var importPicker: Typeahead<Worktree>?

    // MARK: Import a path

    /// `P` in Sessions: a path typed with directory completion, previewed as it changes, imported with ↩.
    struct PathImport {
        var query: String
        /// Directories completing the query; the cursor picks one for ⇥.
        var candidates: [String] = []
        var cursor = 0
        /// What is at the query: "nullean/curb · fix/x", or why nothing can be imported there.
        var preview: String?
        var importable = false
    }

    private(set) var pathImport: PathImport?
    private var pathPreviewTask: Task<Void, Never>?

    private func openPathImport() {
        pathImport = PathImport(query: "~/")
        refreshPathImport()
    }

    func cancelPathImport() { pathImport = nil }

    private func answerPathImport(_ stroke: KeyStroke) {
        guard var state = pathImport else { return }
        switch stroke {
        case .escape:
            pathImport = nil
            return
        case KeyStroke("CR"):
            pathImport = nil
            importPath(state.query)
            return
        case KeyStroke("Tab"):
            // Complete to the highlighted directory, ready for the next component.
            // The list may still be on its way after fast typing; one folder listing now is cheap.
            let candidates = state.candidates.isEmpty ? PathCompletion.candidates(for: state.query) : state.candidates
            guard candidates.indices.contains(state.cursor) else { return }
            state.query = Paths.abbreviate(candidates[state.cursor]) + "/"
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            state.cursor = min(state.cursor + 1, max(state.candidates.count - 1, 0))
            pathImport = state
            return
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            state.cursor = max(state.cursor - 1, 0)
            pathImport = state
            return
        case KeyStroke("BS"):
            if !state.query.isEmpty { state.query.removeLast() }
        case KeyStroke("w", .control), KeyStroke("BS", .option):
            state.query = PathCompletion.droppingLastComponent(state.query)
        case KeyStroke("u", .control):
            state.query = ""
        case KeyStroke("Space"):
            state.query += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return }
            state.query += stroke.key
        }
        state.cursor = 0
        pathImport = state
        refreshPathImport()
    }

    /// Completions and the preview, off the main actor; a newer keystroke cancels an older lookup.
    private func refreshPathImport() {
        guard let query = pathImport?.query else { return }
        if ShotMode.active {
            // Screenshots never read the real disk: a made-up tree under /Users/you.
            let folders = [
                "/Users/you/code/wt/docs-builder",
                "/Users/you/code/wt/mermaider",
                "/Users/you/Projects/sandbox",
            ]
            updatePathImport(query) {
                let typed = query.replacingOccurrences(of: "~", with: "/Users/you")
                $0.candidates = folders.filter { $0.hasPrefix(typed) && $0 != typed.trimmingCharacters(in: ["/"]) }
                $0.preview = query.contains("toc") ? "elastic/docs-builder · toc-ordering" : nil
                $0.importable = query.contains("toc")
            }
            return
        }
        pathPreviewTask?.cancel()
        pathPreviewTask = Task { [weak self] in
            let candidates = await Task.detached { PathCompletion.candidates(for: query) }.value
            guard !Task.isCancelled else { return }
            self?.updatePathImport(query) { $0.candidates = candidates }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let path = Paths.expand(query)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                self?.updatePathImport(query) {
                    $0.preview = query.isEmpty ? nil : "no such folder"
                    $0.importable = false
                }
                return
            }
            let found = await Git.locate(path)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let found else {
                updatePathImport(query) {
                    $0.preview = "not inside a git worktree"
                    $0.importable = false
                }
                return
            }
            let name = "\(found.record.repo.slug) · \(found.worktree.branch ?? "detached")"
                + (found.worktree.isMain ? " (main checkout)" : "")
            let hasSession = worktrees.first { $0.path == found.worktree.path }.flatMap { session(for: $0) } != nil
            updatePathImport(query) {
                $0.preview = hasSession ? "\(name): has a session, ↩ jumps to it" : name
                $0.importable = true
            }
        }
    }

    private func updatePathImport(_ query: String, _ edit: (inout PathImport) -> Void) {
        guard var state = pathImport, state.query == query else { return }
        edit(&state)
        pathImport = state
    }

    static func looksLikePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// Imports the worktree at `path` (any worktree of any repo): the repo is added if Heed did not know it (and kept
    /// in `[worktrees] repo_paths` when it lies outside the scanned roots), then the worktree imports like any other.
    func importPath(_ raw: String) {
        let path = Paths.expand(raw.trimmingCharacters(in: .whitespaces))
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "looking at \(Paths.abbreviate(path))…"
        Task {
            guard let (worktree, listed) = await adoptRepo(at: path) else { return }
            openOrImport([listed.first { $0.path == worktree.path } ?? worktree])
        }
    }

    /// `:repo.add <path>`: the repo at `path` joins Repos with its worktrees, and is kept in `[worktrees] repo_paths`
    /// when it lies outside the scanned roots.
    private func addRepo(_ raw: String) {
        let path = Paths.expand(raw.trimmingCharacters(in: .whitespaces))
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            flash = ":repo.add <path> adds a repo outside \(settings.repoRoots.joined(separator: ", "))"
            return
        }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "looking at \(Paths.abbreviate(path))…"
        Task {
            guard let (worktree, listed) = await adoptRepo(at: path) else { return }
            view = .repos
            flash = "added \(worktree.repo.slug): \(listed.count) worktree\(listed.count == 1 ? "" : "s")"
        }
    }

    /// The repo and worktrees at `path`, made known: added to the domain (and to repo_paths if outside the roots).
    private func adoptRepo(at path: String) async -> (worktree: Worktree, listed: [Worktree])? {
        guard let found = await Git.locate(path) else {
            flash = "not inside a git worktree: \(Paths.abbreviate(path))"
            return nil
        }
        if !repos.contains(where: { $0.id == found.record.id }) {
            commit(.repoUpserted(found.record))
            let roots = settings.repoRoots.map { Paths.expand($0) }
            if !roots.contains(where: { found.record.path.hasPrefix($0 + "/") }) {
                setConfig(
                    ["worktrees", "repo_paths"],
                    .array((settings.repoPaths + [Paths.abbreviate(found.record.path)]).map { .string($0) })
                )
            }
        }
        var listed = found.all
        for index in listed.indices {
            listed[index].status = try? await Git.status(at: listed[index].path)
        }
        commit(.worktreesListed(repo: found.record.repo, listed))
        return (found.worktree, listed)
    }

    private func openImportPicker() {
        let rank = Dictionary(sortedRepos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let candidates = worktrees.filter { session(for: $0) == nil }.sorted {
            if $0.isMain != $1.isMain { return !$0.isMain }
            return $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        // Open even when every listed worktree has a session: a typed path imports any other.
        importPicker = Typeahead(items: candidates) { [$0.repo.slug, $0.branch ?? "", $0.path] }
    }

    private func answerImportPicker(_ stroke: KeyStroke) {
        guard var picker = importPicker else { return }
        // A typed path imports whatever worktree is there, known or not.
        if stroke == KeyStroke("CR"), Self.looksLikePath(picker.query), picker.matches.isEmpty {
            importPicker = nil
            importPath(picker.query)
            return
        }
        switch picker.handle(stroke) {
        case .handled: importPicker = picker
        case .cancel: importPicker = nil
        case let .picked(worktree):
            importPicker = nil
            openOrImport([worktree])
        }
    }

    func pickImport(_ worktree: Worktree) {
        importPicker = nil
        openOrImport([worktree])
    }

    func cancelImportPicker() { importPicker = nil }

    private func openOrImport(_ rows: [Worktree]) {
        guard !rows.isEmpty else { return }
        let missing = rows.filter { session(for: $0) == nil }
        if missing.isEmpty, let session = session(for: rows[0]) {
            view = .sessions
            select(sessionID: session.id)
            return
        }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        let defaultAgent = settings.agent(settings.defaultAgent)
        flash = "looking for agent sessions…"
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                missing.map { ($0, Import.claudeSessions(directory: $0.path).first) }
            }.value
            flash = nil
            let lines = found.map { worktree, agentSession -> String in
                let name = "\(worktree.repo.name)/\(worktree.branch ?? worktree.head)"
                guard let agentSession else { return "\(name): starts \(defaultAgent?.name ?? "a shell") fresh" }
                let age = agentSession.modified.formatted(.relative(presentation: .named))
                let prompt = agentSession.prompt.map { " · “\($0.prefix(50))”" } ?? ""
                return "\(name): resumes the claude session from \(age)\(prompt)"
            }
            ask(Confirmation(
                title: found
                    .count == 1 ? "Import this worktree as a session?" : "Import \(found.count) worktrees as sessions?",
                lines: lines,
                accept: "Import",
                destructive: false
            ) { [weak self] in self?.importWorktrees(found, defaultAgent: defaultAgent) })
        }
    }

    private func importWorktrees(_ found: [(Worktree, Import.AgentSession?)], defaultAgent: AgentProfile?) {
        var firstID: String?
        for (worktree, agentSession) in found {
            let agent = agentSession.flatMap { settings.agent($0.agent) } ?? defaultAgent
            let changes = Import.session(for: worktree, agent: agent, resume: agentSession, integration: integration)
            for case let .layoutChanged(_, layout) in changes {
                for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                    TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                }
            }
            for case let .sessionUpserted(session) in changes where firstID == nil {
                firstID = session.id
            }
            commit(changes)
        }
        view = .sessions
        if let firstID { select(sessionID: firstID) }
        if let tab = currentTab, let agent = tab.tree.panes.first(where: { $0.role == .agent }) { focusPane(agent.id) }
        enterInsert()
        flash = "imported \(found.count) session\(found.count == 1 ? "" : "s")"
    }

    /// Which of `rows` can go (clean, pushed, not pinned) and why the rest stay.
    private func planRemoval(_ rows: [Worktree], sessionsFollow: Bool = true) -> (
        removals: [SweepPlan.Removal], kept: [String]
    ) {
        var kept: [String] = []
        var removals: [SweepPlan.Removal] = []
        for worktree in rows {
            let users = sessions.filter { $0.branch == worktree.branch && $0.repos.contains(worktree.repo) }
            if sessionsFollow, users.contains(where: \.pinned) {
                kept.append("\(worktree.repo.name)/\(worktree.branch ?? worktree.path): pinned session")
            } else if let reason = Sweep.unsafe(worktree) {
                kept.append("\(worktree.repo.name)/\(worktree.branch ?? worktree.path): \(reason)")
            } else {
                removals.append(SweepPlan.Removal(
                    worktree: worktree, idleDays: 0, sessions: sessionsFollow ? users.map(\.id) : [],
                    deleteBranch: config.cleanup.deleteBranch && worktree.branch != nil
                ))
            }
        }
        return (removals, kept)
    }

    private func confirmRemoveSelected() {
        let rows = actionRows
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        guard !rows.isEmpty else {
            flash = "nothing selected"
            return
        }
        let (removals, kept) = planRemoval(rows)
        guard !removals.isEmpty else {
            flash = "kept: \(kept.joined(separator: "; "))"
            return
        }
        let closing = Set(removals.flatMap(\.sessions)).count
        ask(Confirmation(
            title: removals.count == 1
                ? "Remove \(removals[0].worktree.repo.name)/\(removals[0].worktree.branch ?? "worktree")?"
                : "Remove \(removals.count) worktrees?",
            lines: removals.map { removal in
                "\(removal.worktree.repo.name)/\(removal.worktree.branch ?? removal.worktree.path)"
                    + (removal.deleteBranch ? " · local branch too" : "")
            } +
                (closing > 0 ?
                    ["\(closing) session\(closing == 1 ? "" : "s") on them move\(closing == 1 ? "s" : "") to History"] :
                    []),
            kept: kept,
            accept: "Remove"
        ) { [weak self] in self?.removeWorktrees(removals, kept: kept) })
    }

    private func removeWorktrees(_ removals: [SweepPlan.Removal], kept: [String]) {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        for id in Set(removals.flatMap(\.sessions)) {
            for pane in layouts[id]?.tabs.flatMap(\.tree.panes) ?? [] {
                TerminalSurfaces.shared.close(paneID: pane.id)
            }
        }
        let skipped = kept
        Task {
            let (changes, failures) = await Sweep.execute(
                SweepPlan(removals: removals, skips: [], next: nil), domain: currentDomain
            )
            commit(changes)
            flash = "removed \(removals.count - failures.count)" +
                (skipped.isEmpty ? "" : " · kept \(skipped.count): \(skipped[0])")
                + (failures.isEmpty ? "" : " · failed: \(failures[0])")
        }
    }

    private func rescan() {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "scanning \(settings.repoRoots.joined(separator: ", "))…"
        Task {
            await refreshRepos()
            flash = "\(repos.count) repos · \(worktreeCount) worktrees"
        }
    }

    // MARK: History

    /// History in display order (newest first), filtered by `/` text and the outcome chip.
    var historyRows: [HistoryEntry] {
        let filter = filter(for: .history)
        return history.filter { entry in
            (historyOutcome == nil || entry.outcome == historyOutcome)
                && FilterQuery.matches(
                    filter,
                    [entry.session.title, entry.session.prompt, entry.session.branch, entry.session.agent]
                        + entry.session.repos.map(\.name)
                )
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
        if tutor != nil {
            // The tutor: the session comes back as it would, its agent pane in its worktree, nothing resumed.
            let path = worktrees.first { $0.branch == entry.session.branch }?.path ?? "/Users/you/code"
            let pane = PaneSpec(role: .agent, title: entry.session.agent, directory: path, command: nil)
            commit([
                .historyRemoved(entry.id), .sessionUpserted(entry.session),
                .layoutChanged(session: entry.id, SessionLayout(tabs: [PaneTab(title: "agent", tree: .leaf(pane))])),
            ])
            view = .sessions
            select(sessionID: entry.id)
            return
        }
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

    var inboxRows: [InboxItem] {
        let filter = filter(for: .inbox)
        return github.inbox.filter {
            inboxFilter.matches($0)
                && FilterQuery.matches(
                    filter,
                    [$0.title, $0.kind.rawValue, $0.repo.slug, $0.reason, $0.number.map { "#\($0)" } ?? ""]
                )
        }
    }

    /// Issues the rules show (involving you, or in a repo showing all), narrowed by the chip and the repo column.
    var shownIssues: [Issue] {
        github.issues
            .filter { ($0.involvesYou || config.issues.visibility($0.repo) == .all) && issueFilter.matches($0) }
    }

    /// The Issues repo column: repos with shown issues, most first, then by name.
    var issueRepoCounts: [(repo: Repo, count: Int)] {
        let counts = Dictionary(grouping: shownIssues, by: \.repo).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count
                : $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending
        }
    }

    var issueRows: [Issue] {
        let filter = filter(for: .issues)
        return shownIssues.filter {
            (issueRepo == nil || $0.repo == issueRepo)
                && FilterQuery.matches(filter, [$0.title, $0.repo.slug, "#\($0.number)", $0.author ?? ""] + $0.labels)
        }
    }

    private func cycleIssueRepo(by delta: Int) {
        let options: [Repo?] = [nil] + issueRepoCounts.map(\.repo)
        let index = options.firstIndex(of: issueRepo) ?? 0
        issueRepo = options[((index + delta) % options.count + options.count) % options.count]
        itemCursor[.issues] = 0
    }

    /// `:issues.repo docs-builder`: by name or org/name; none shows every repo.
    private func pickIssueRepo(named name: String?) {
        view = .issues
        guard let name else { return pickIssueRepo(nil) }
        let key = name.lowercased()
        guard let repo = issueRepoCounts.map(\.repo).first(where: {
            $0.slug.lowercased() == key || $0.name.lowercased() == key
        }) else {
            flash = "no issues from a repo named \(name)"
            return
        }
        pickIssueRepo(repo)
    }

    /// `:session.open anchors`: the first session matching every word, as the filter matches.
    private func openSession(matching words: String) {
        guard !words.isEmpty else {
            flash = ":session.open <words> goes to the first session matching them"
            return
        }
        guard let session = list.ordered.first(where: { session in
            FilterQuery.matches(words, [session.title, session.branch, session.agent] + session.repos.map(\.name))
        }) else {
            flash = "no session matches \(words)"
            return
        }
        view = .sessions
        select(sessionID: session.id)
    }

    /// `gU` (`:track <url>`): the current session tracks that PR; with no URL, the one on the clipboard.
    private func trackPull(_ argument: String?) {
        let text = argument ?? NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pull = PullRef(url: text) else {
            flash = argument == nil ? "copy a PR URL first, or :track <url>" : "not a PR URL: \(text)"
            return
        }
        guard currentSession != nil else {
            flash = "no session to track \(pull.repo.name)#\(pull.number)"
            return
        }
        guard currentSession?.trackedPRs.contains(pull) == false else {
            flash = "already tracking \(pull.repo.name)#\(pull.number)"
            return
        }
        updateCurrent { session in
            session.trackedPRs.append(pull)
            session.record("tracking PR \(pull.repo.name)#\(pull.number)")
        }
        flash = "tracking \(pull.repo.name)#\(pull.number)"
        if !isFixture { Task { await syncGitHub(parts: [.pulls]) } }
    }

    /// VISUAL `m` in Repos: pins the sessions on the selected worktrees; when all are pinned already, unpins them.
    private func pinSelected() {
        let targets = actionRows.compactMap(session(for:))
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        guard !targets.isEmpty else {
            flash = "no sessions on the selected worktrees"
            return
        }
        let pin = !targets.allSatisfy(\.pinned)
        let room = SessionGroup.maxPins - list.pins.count
        let changing = targets.filter { $0.pinned != pin }
        guard !pin || changing.count <= room else {
            flash = "only \(room) pin\(room == 1 ? "" : "s") left of \(SessionGroup.maxPins)"
            return
        }
        commit(changing.map { session in
            var session = session
            session.pinned = pin
            return .sessionUpserted(session)
        })
        flash = "\(pin ? "pinned" : "unpinned") \(changing.count) session\(changing.count == 1 ? "" : "s")"
    }

    func pickIssueRepo(_ repo: Repo?) {
        issueRepo = repo
        itemCursor[.issues] = 0
    }

    /// `w` in Issues, `I` in Repos: the repo under the cursor flips between all issues and only yours.
    private func toggleIssueVisibility() {
        let repo: Repo?
        switch view {
        case .issues:
            let rows = issueRows
            let index = cursor(in: .issues)
            repo = rows.indices.contains(index) ? rows[index].repo : issueRepo
        case .repos:
            let rows = worktreeRows
            repo = rows.indices.contains(repoCursor) ? rows[repoCursor].repo : nil
        default: repo = nil
        }
        guard let repo else {
            flash = "no repo under the cursor"
            return
        }
        let next: IssueVisibility = config.issues.visibility(repo) == .all ? .involved : .all
        if isFixture {
            config.issues.repos[repo.slug] = next
        } else {
            setConfig(["repos", repo.slug, "issues"], .string(next.rawValue))
        }
        flash = next == .all ? "\(repo.name): all open issues" : "\(repo.name): only issues involving you"
    }

    var pullRows: [PullRequest] {
        let filter = filter(for: .prs)
        return github.pulls.filter {
            FilterQuery.matches(filter, [$0.title, $0.ref.repo.slug, "#\($0.ref.number)", $0.headBranch])
        }
    }

    func itemIDs(_ view: AppView) -> [String] {
        switch view {
        case .inbox: inboxRows.map(\.id)
        case .issues: issueRows.map(\.id)
        case .prs: pullRows.map(\.id)
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
        issueReader = nil
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
        if let issue = issueReader { return issue.url }
        if let ref = feedbackPull { return pullDetails[ref.description].map { _ in ref.url } ?? ref.url }
        let index = cursor(in: view)
        switch view {
        case .inbox: return inboxRows.indices.contains(index) ? inboxRows[index].url : nil
        case .issues: return issueRows.indices.contains(index) ? issueRows[index].url : nil
        case .prs: return pullRows.indices.contains(index) ? pullRows[index].url : nil
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
            let rows = pullRows
            guard view == .prs, rows.indices.contains(index) else { return }
            ref = rows[index].ref
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
        case .prs: return pullRows.indices.contains(index) ? pullRows[index].ref : nil
        case .inbox:
            guard inboxRows.indices.contains(index), inboxRows[index].kind == .pr,
                  let number = inboxRows[index].number else { return nil }
            return PullRef(repo: inboxRows[index].repo, number: number)
        case .sessions: return currentSession?.trackedPRs.first
        default: return nil
        }
    }

    private func openReader() {
        if let ref = pullUnderCursor {
            reader = ref
            feedbackCursor = 0
            fetchDetail(ref)
        } else if let issue = issueUnderCursor {
            issueReader = issue
        } else {
            openInBrowser()
        }
    }

    /// `go`: the PR or issue under the cursor, or in Sessions the session's PR overlay; again closes it.
    private func toggleItemOverlay() {
        if issueReader != nil || reader != nil {
            closeReaderOrOverlay()
        } else if view == .sessions {
            togglePullOverlay()
        } else {
            openReader()
        }
    }

    /// The issue under the cursor: an Issues row, or an issue in the inbox (with what the inbox knows of it when it
    /// is not one assigned to you).
    private var issueUnderCursor: Issue? {
        let index = cursor(in: view)
        switch view {
        case .issues:
            let rows = issueRows
            return rows.indices.contains(index) ? rows[index] : nil
        case .inbox:
            let rows = inboxRows
            guard rows.indices.contains(index), rows[index].kind == .issue, let number = rows[index].number
            else { return nil }
            let item = rows[index]
            return github.issues.first { $0.repo == item.repo && $0.number == number }
                ?? Issue(
                    repo: item.repo, number: number, title: item.title,
                    url: item.url ?? "https://github.com/\(item.repo.slug)/issues/\(number)", body: "", labels: [],
                    author: nil, updatedAt: item.updatedAt
                )
        default: return nil
        }
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
        if issueReader != nil {
            issueReader = nil
        } else if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        } else {
            goBack()
        }
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

    /// Details for the PRs active sessions track and watch, so auto-feed sees new feedback: the one on screen every
    /// time, the others only when the last sync says their checks or threads moved, or every fifth poll.
    private func refreshWatchedDetails() async {
        let open = [overlay == .pr ? overlayPull : nil, reader].compactMap(\.self)
        let now = Date()
        let refs = Set(sessions.flatMap(\.trackedPRs)).filter { ref in
            guard feedback[ref.description]?.watching ?? true else { return false }
            return open.contains(ref) || syncSchedule.needsDetail(
                pull: github.pull(ref), detail: pullDetails[ref.description], now: now
            )
        }
        for ref in Set(open).union(refs).prefix(10) {
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
                if tutor != nil {
                    updateFeedback { $0.markSent(at: pullDetails[ref.description]?.headSHA) }
                    flash = "sent (tutor: nothing was typed)"
                } else {
                    flash = "fixture: no IO"
                }
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

    /// `/` in any list view: typing goes to the status bar until ↩ (keep) or ⎋ (clear).
    private func startFilter() {
        guard overlay == nil, reader == nil, issueReader == nil else { return }
        filtering = true
    }

    func clearFilter(_ view: AppView) {
        filters[view] = nil
        resetCursor(view)
    }

    private func typeFilter(_ stroke: KeyStroke) {
        var text = filter(for: view)
        switch stroke {
        case .escape:
            text = ""
            filtering = false
        case KeyStroke("CR"):
            filtering = false
        case KeyStroke("BS"):
            if text.isEmpty { filtering = false } else { text.removeLast() }
        case KeyStroke("u", .control):
            text = ""
        case KeyStroke("w", .control):
            text = FilterQuery.droppingLastWord(text)
        case KeyStroke("Space"):
            text += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.isEmpty else { return }
            text += stroke.key
        }
        guard text != filter(for: view) else { return }
        filters[view] = text.isEmpty ? nil : text
        resetCursor(view)
    }

    private func resetCursor(_ view: AppView) {
        switch view {
        case .sessions: cursor = 0
        case .history: historyCursor = 0
        case .repos: repoCursor = 0
        case .inbox, .issues, .prs: itemCursor[view] = 0
        }
    }

    /// How many rows the current view's filter leaves.
    var filterMatches: Int {
        switch view {
        case .sessions: list.ordered.count
        case .history: historyRows.count
        case .repos: worktreeRows.count
        case .inbox, .issues, .prs: itemIDs(view).count
        }
    }

    // MARK: Start work

    /// The global shortcut: Start work in a panel over whatever app is in front. Pressing it again brings the panel
    /// back; a dialog already open in the main window moves to the panel.
    func openStandaloneStartWork() {
        guard confirmation == nil, importPicker == nil else { return }
        if startWork == nil {
            openStartWork(prompt: "")
        }
        startWorkStandalone = true
        StartWorkPanelController.shared.show(model: self)
    }

    /// Clicking away from the panel cancels it, like Spotlight; a start in progress keeps it open.
    func standaloneClickedAway() {
        guard startWorkStandalone, !startingWork else { return }
        startWork = nil
    }

    private func openStartWork(prompt: String) {
        startWorkError = nil
        if view == .history { view = .sessions }
        startWork = StartWorkForm(
            repos: repos, history: sessions, settings: settings, prompt: prompt, integration: integration,
            worktreeCounts: RepoOrder.worktreeCounts(worktrees)
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
        if tutor != nil {
            simulateStart(plan)
            return
        }
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
                // A session starts with its agent pane taking your keys.
                if let tab = currentTab, let agent = tab.tree.panes.first(where: { $0.role == .agent }) {
                    focusPane(agent.id)
                }
                enterInsert()
                flash = "started \(plan.name)"
            } catch {
                flash = "start work failed: \(error)"
                startWorkError = "start failed: \(error)"
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

    /// The key bound to `command` in NORMAL (first binding), as key-cap text: what the title bar shows per view.
    func keyCap(for command: String) -> String? {
        (engine.keymaps[.normal] ?? Keymap()).keys(for: command).first.map(KeyCapText.of)
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }
    func toggleInspector() { inspectorVisible.toggle() }

    func focusPane(_ paneID: String) {
        updateTab { $0.focused = paneID }
    }

    // MARK: Tutor

    /// Start work in the tutor: the session, its worktrees and panes as they would be, with no git and no agent.
    private func simulateStart(_ plan: StartWorkPlan) {
        let made = plan.repos.map { record in
            Worktree(
                repo: record.repo, path: settings.worktreePath(repo: record.repo, name: plan.name), branch: plan.name,
                head: "0000000", isMain: false, status: WorktreeStatus(upstream: nil)
            )
        }
        var session = Session(
            id: plan.sessionID, title: plan.title, prompt: plan.prompt, repos: plan.repos.map(\.repo),
            branch: plan.name, agent: plan.agent?.name ?? "shell", state: ObservedState(.working),
            activity: "starting", lastActivity: Date()
        )
        session.record("started · \(plan.agent?.name ?? "shell")")
        var changes: [DomainChange] = plan.repos.map { record in
            .worktreesListed(repo: record.repo, worktrees.filter { $0.repo == record.repo } + made.filter {
                $0.repo == record.repo
            })
        }
        changes += [
            .sessionUpserted(session),
            .layoutChanged(session: session.id, StartWork.layout(for: plan, session: session, worktrees: made)),
        ]
        commit(changes)
        startWork = nil
        view = .sessions
        select(sessionID: session.id)
        flash = "started \(plan.name) (tutor: nothing real ran)"
    }

    /// What the app is asked to do with the tutor: start a lesson in a sandbox (in a world, or the lesson's own), or
    /// leave it and put the live sessions back.
    enum TutorRequest {
        case start(lesson: String, world: TutorWorld?)
        case exit
    }

    /// `:settings.open agents`: the section the Settings window turns to.
    var settingsSection: SettingsView.Section?

    /// Set on the sandbox model while the tutor runs; nil everywhere else.
    private(set) var tutor: Tutor?
    /// The world the sandbox runs, for the picker's footer.
    private(set) var tutorWorld: TutorWorld?
    /// `:tutor` with no lesson: the picker, on either model.
    private(set) var tutorPicker: TutorPicker?
    /// When the current step began, for the hint that follows a while without the keys.
    private(set) var tutorStepStarted = Date()
    /// The world as each step began, for `:back`.
    private var tutorSnapshots: [Int: (domain: Domain, view: AppView)] = [:]
    var onTutorRequest: ((TutorRequest) -> Void)?

    /// Done lessons and where one was left, kept between launches (not in screenshots).
    var tutorProgress: TutorProgress {
        get {
            guard !ShotMode.active, let data = UserDefaults.standard.data(forKey: "tutorProgress"),
                  let progress = try? JSONDecoder().decode(TutorProgress.self, from: data)
            else { return TutorProgress() }
            return progress
        }
        set {
            guard !ShotMode.active, let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "tutorProgress")
        }
    }

    /// Makes this (fixture) model the tutor's sandbox, on `lesson` at the step it was left on.
    func beginTutor(lesson id: String, world: TutorWorld? = nil, step: Int? = nil, startedAt: Date = Clock.now) {
        guard let lesson = Tutor.lesson(id) else { return }
        tutorWorld = world ?? lesson.world
        // A view's lesson opens in that view.
        view = AppView(rawValue: id) ?? .sessions
        let resume = step ?? tutorProgress.resumeStep(id)
        tutor = Tutor(lesson: lesson, step: resume, state: tutorState, now: startedAt)
        tutorSnapshots = [resume: (currentDomain, view)]
        tutorStepStarted = Date()
        saveTutorProgress()
    }

    /// The view the tutor's "this view" means: the overlay or dialog on top, else the view.
    private var tutorViewName: String {
        if startWork != nil { return "start-work" }
        if overlay == .diff { return "diff" }
        return view.rawValue
    }

    private func openTutor(_ arguments: [String]) {
        if let name = arguments.first {
            guard let id = Tutor.lessonID(named: name) else {
                flash = "no tutor lesson \(name) (tour, \(Tutor.viewLessons.map(\.id).joined(separator: ", ")))"
                return
            }
            onTutorRequest?(.start(lesson: id, world: nil))
            return
        }
        tutorPicker = TutorPicker(view: tutorViewName, progress: tutorProgress)
    }

    private func answerTutorPicker(_ stroke: KeyStroke) {
        guard var picker = tutorPicker else { return }
        switch picker.handle(stroke) {
        case .handled: tutorPicker = picker
        case .cancel: tutorPicker = nil
        case let .start(lesson, world):
            tutorPicker = nil
            onTutorRequest?(.start(lesson: lesson, world: world))
        }
    }

    func pickTutorRow(_ index: Int) {
        guard var picker = tutorPicker else { return }
        picker.select(index)
        tutorPicker = picker
        answerTutorPicker(KeyStroke("CR"))
    }

    func cancelTutorPicker() { tutorPicker = nil }

    /// After every key while the tutor runs: did that do the step? `stroke` is nil for clicks.
    private func observeTutor(_ stroke: KeyStroke?) {
        guard var current = tutor else { return }
        let before = current.step
        let event = current.observe(
            tutorState, key: stroke.map { KeyCapText.of([$0]) }, pending: !engine.pendingDisplay.isEmpty
        )
        if event == .nudged, let step = current.current {
            // Name the key the step wants, as you have it bound.
            let wanted = step.keys.first.map(renderTutorText) ?? ""
            current = current.withNudge(wanted.isEmpty ? nil : "\(wanted) is the one here.")
        }
        tutor = current
        if current.step != before { tutorStepChanged() }
    }

    private func tutorStepChanged() {
        guard let current = tutor else { return }
        tutorStepStarted = Date()
        if tutorSnapshots[current.step] == nil { tutorSnapshots[current.step] = (currentDomain, view) }
        saveTutorProgress()
    }

    private func saveTutorProgress() {
        guard let current = tutor else { return }
        var progress = tutorProgress
        progress.lastLesson = current.lesson.id
        if current.finished {
            progress.done.insert(current.lesson.id)
            progress.lastStep = 0
        } else {
            progress.lastStep = current.step
        }
        tutorProgress = progress
    }

    /// `:back`: the world put back as it was when this step began; on a step not yet touched, the previous step.
    private func tutorBack() {
        guard var current = tutor else { return }
        let untouched = tutorSnapshots[current.step].map { $0.domain == currentDomain && $0.view == view } ?? true
        let target = untouched ? max(current.step - 1, 0) : current.step
        if let snapshot = tutorSnapshots[target] {
            closeEverythingForTutor()
            replace(with: snapshot.domain)
            view = snapshot.view
        }
        if target == current.step { current.restart(at: tutorState) } else { current.back(to: tutorState) }
        tutor = current
        tutorStepChanged()
    }

    private func tutorSkip() {
        guard var current = tutor else { return }
        current.skip(from: tutorState)
        tutor = current
        tutorStepChanged()
    }

    /// The card's keys went unpressed a while: counted for the finish card.
    func noteTutorHint() {
        guard var current = tutor else { return }
        current.noteHint()
        tutor = current
    }

    private func closeEverythingForTutor() {
        startWork = nil
        confirmation = nil
        importPicker = nil
        overlay = nil
        reader = nil
        issueReader = nil
        filtering = false
        if mode != .normal { engine.enter(.normal) }
    }

    /// The lesson after this one: the next not yet done, in the picker's order.
    var nextTutorLesson: TutorLesson? {
        guard let current = tutor else { return nil }
        let order = [Tutor.tour] + Tutor.viewLessons
        let done = tutorProgress.done
        let index = order.firstIndex { $0.id == current.lesson.id } ?? 0
        return (order[(index + 1)...] + order[..<index]).first { !done.contains($0.id) }
    }

    /// The finish card's keys: ↩ the next lesson, r the same again. Anything else goes on as usual.
    private func answerFinishedTutor(_ stroke: KeyStroke) -> Bool {
        guard let current = tutor, current.finished else { return false }
        if stroke == KeyStroke("CR"), let next = nextTutorLesson {
            onTutorRequest?(.start(lesson: next.id, world: nil))
            return true
        }
        if stroke == KeyStroke("r") {
            onTutorRequest?(.start(lesson: current.lesson.id, world: tutorWorld))
            return true
        }
        return false
    }

    /// `{command}` placeholders as the keys you have them on.
    func renderTutorText(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let command = String(rest[rest.index(after: open) ..< close])
            result += keyLabel(for: command) ?? ":\(command)"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// What the tutor's steps check.
    var tutorState: TutorState {
        var state = TutorState()
        state.mode = mode
        state.view = view.rawValue
        switch view {
        case .sessions:
            state.cursor = cursor
            state.rows = list.ordered.count
        case .repos:
            state.cursor = repoCursor
            state.rows = worktreeRows.count
        case .history:
            state.cursor = historyCursor
            state.rows = historyRows.count
        case .inbox, .issues, .prs:
            state.cursor = cursor(in: view)
            state.rows = itemIDs(view).count
        }
        state.overlay = issueReader != nil ? "issue" : reader != nil ? "reader" : overlay.map(\.name)
        state.helpOpen = overlay == .help
        state.filtering = filtering
        state.filter = filter(for: view)
        let panes = currentTab?.tree.panes ?? []
        state.panes = panes.count
        state.focusedPane = panes.firstIndex { $0.id == currentTab?.focused } ?? 0
        state.tab = currentTabIndex
        state.tabs = currentTabs.count
        state.startWorkOpen = startWork != nil
        state.startWorkPrompt = startWork?.prompt ?? ""
        state.startWorkRepo = startWork?.selectedRepos.first
        state.confirmationOpen = confirmation != nil
        state.importOpen = importPicker != nil || pathImport != nil
        state.commandLine = mode == .command
        state.sessions = sessions.count
        let pins = list.ordered.filter(\.pinned)
        state.pins = pins.count
        if view == .sessions, let session = currentSession {
            state.pinned = pins.firstIndex { $0.id == session.id }.map { $0 + 1 }
            state.onParked = SessionGroup.of(session) == .parked
            state.needsYou = [.blocked, .asking].contains(session.state.state)
        }
        state.parked = sessions.count { SessionGroup.of($0) == .parked }
        state.picked = picked[view]?.count ?? 0
        state.unread = github.inbox.count(where: \.unread)
        if let ref = feedbackPull, let pipeline = feedback[ref.description] {
            state.queued = pipeline.count(.queued)
            state.sent = pipeline.count(.sent)
        }
        state.waiting = pendingDelivery.count
        state.diffFile = diffFileIndex
        state.diffRow = diffRow
        state.historyOutcome = historyOutcome.map(\.rawValue) ?? ""
        return state
    }

    /// The key for a command as you have it bound: NORMAL first, then the view bindings (`Iw` lives in Sessions').
    func keyLabel(for command: String) -> String? {
        if let normal = keyCap(for: command) { return normal }
        for (_, keymap) in engine.scopedKeymaps.sorted(by: { $0.key < $1.key }) {
            if let keys = keymap.keys(for: command).first { return KeyCapText.of(keys) }
        }
        return nil
    }

    // MARK: Outside the window

    /// Reopens the main window after it was closed (set by the window from SwiftUI's openWindow).
    var reopenWindow: (() -> Void)?

    /// The Dock badge and the menu bar item, from the sessions that need you.
    private func updateOutsideWindow() {
        // Fixtures stay out of the Dock and menu bar, unless HEED_OUTSIDE asks (to check them against fixture states).
        guard !isFixture || ProcessInfo.processInfo.environment["HEED_OUTSIDE"] != nil else { return }
        let attention = Attention(blocked: blockedCount, asking: askingCount)
        DockState.update(attention, enabled: config.showDockState)
        MenuBarItem.shared.update(model: self, attention: attention, enabled: config.showMenuBarItem)
    }

    /// `[keys] global_activate` and Open Heed: the main window to the front, reopened if it was closed.
    func activateHeed() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier == Self.mainWindowID }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
    }

    /// A session chosen outside the window (the menu bar): Heed in front, on that session.
    func show(sessionID: String) {
        view = .sessions
        select(sessionID: sessionID)
        activateHeed()
    }

    // MARK: Mouse

    /// Clicking into a terminal means typing there: focus that pane and enter INSERT. Without this a click left
    /// NORMAL on, and the next letters ran as commands (x closes the session).
    func clickedPane(_ paneID: String) {
        guard startWork == nil, resume == nil, firstRun == nil, !filtering else { return }
        if currentTab?.focused != paneID { focusPane(paneID) }
        enterInsert()
    }

    /// A click outside any terminal (a list, the sidebar, the title bar) hands the keyboard back to Heed.
    func clickedOutsideTerminal() {
        guard mode == .insert else { return }
        let before = engine.mode
        engine.enter(.normal)
        modeChanged(from: before)
    }

    private func enterInsert() {
        guard mode != .insert else {
            terminalFocusRequest += 1
            return
        }
        let before = engine.mode
        engine.enter(.insert)
        modeChanged(from: before)
    }
}

/// The Issues chips (`t`).
enum IssueFilter: String, CaseIterable {
    case all = "All", assigned = "Assigned", mentioned = "Mentioned", watched = "Watched repos"

    var next: IssueFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ issue: Issue) -> Bool {
        switch self {
        case .all: true
        case .assigned: issue.assigned
        case .mentioned: issue.mentioned
        case .watched: !issue.involvesYou
        }
    }
}

/// The inbox chips (`t`). CI is GitHub Actions telling you a workflow run finished (failed, mostly) on your branch.
enum InboxFilter: String, CaseIterable {
    case unread = "Unread", all = "All", prs = "PRs", issues = "Issues", review = "Review requested",
         assigned = "Assigned", ci = "CI runs"

    var next: InboxFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ item: InboxItem) -> Bool {
        switch self {
        case .unread: item.unread
        case .all: true
        case .prs: item.kind == .pr
        case .issues: item.kind == .issue
        case .review: item.reason == "review_requested"
        case .assigned: item.reason == "assign"
        case .ci: item.kind == .ci || item.reason == "ci_activity"
        }
    }
}

enum HintTarget: Hashable {
    case session(String)
    case pane(String)
    /// A row in a view's list, by position.
    case row(AppView, Int)
}
