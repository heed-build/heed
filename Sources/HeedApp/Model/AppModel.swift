import AppKit
import HeedCore
import Observation

/// The app's views, switched with `g` keys (`gs`, `gm`, `gi`, `gp`, `gr`, `gh`).
enum AppView: String, CaseIterable, Identifiable {
    case sessions, watch, inbox, issues, prs, repos, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .inbox: "Inbox"
        case .issues: "Issues"
        case .prs: "PRs"
        case .watch: "Watch"
        case .repos: "Repos"
        case .history: "History"
        }
    }

    /// The command that switches to this view; its key comes from the live keymap.
    var command: String { "view.\(rawValue)" }
}

extension Notification.Name {
    /// Tutor progress was saved (a lesson finished, a step done, a reminder hidden).
    static let heedTutorProgress = Notification.Name("heed.tutorProgress")
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
    // What the pilot knows decides Watching and Stalled in the sidebar, so each change rebuilds the list.
    private(set) var github = GitHubState() { didSet { rebuildList() } }
    private(set) var pullDetails: [String: PullDetail] = [:] { didSet { rebuildList() } }
    private(set) var feedback: [String: PullFeedback] = [:] { didSet { rebuildList() } }
    /// What the pilot noticed and did, newest first.
    private(set) var pilotLog: [PilotEvent] = [] { didSet { rebuildList() } }
    private(set) var mergeRuns: [String: [MergeRun]] = [:]
    private(set) var registeredWorktrees: Set<String> = []
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
    private(set) var cursor = 0 {
        // Leaving the session the list held in place lets it settle into its group.
        didSet { if !rebuildingList, let held = heldSession, currentSession?.id != held { rebuildList() } }
    }

    private var rebuildingList = false
    /// The session under the cursor when the list was built; the pilot does not move it until the cursor leaves it.
    private var heldSession: String?
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
        if isFixture {
            config.issues = Fixtures.issueRules
            config.hosts = Fixtures.hosts
            config.pilot = Fixtures.pilotRules
            hostStatuses = Fixtures.hostStatuses
            issueInfo = Fixtures.issueInfo
        }
        replace(with: domain)
        if isFixture { adoptFixtureHelpers() }
        updateScope()
        tutorRecord = tutorProgress
        // The tutor runs in its own window and model; the reminder here follows what it saves.
        NotificationCenter.default
            .addObserver(forName: .heedTutorProgress, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tutorRecord = self?.tutorProgress ?? TutorProgress() }
            }
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
        // Before any pane is drawn: which panes still have a live zmx session to reattach to.
        await TerminalSurfaces.shared.refreshLivePanes()
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
        case .sessions, .prs, .watch, .repos, .history: [.pulls]
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
            await refreshIssueInfo()
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
        let found = await Task.detached(priority: .userInitiated) {
            Resume.candidates(domain: domain, settings: settings, integration: integration) { session in
                let directory = domain.layouts[session.id]?.tabs.first?.tree.panes.first?.directory ?? ""
                return AgentIntegration.hasSession(
                    agent: session.agent,
                    id: session.agentSessionID ?? "",
                    directory: directory
                )
            }
        }.value
        // An agent whose pane's zmx session is alive never stopped: its pane reattaches, there is nothing to resume.
        let live = TerminalSurfaces.shared.livePanes
        // Sessions on hosts are never resumed: with zmx there their agents never stopped, and without it there is
        // nothing to resume into.
        let remote = Set(domain.sessions.filter { $0.host != nil }.map(\.id))
        let candidates = found.filter { candidate in
            guard !remote.contains(candidate.id) else { return false }
            guard let layout = domain.layouts[candidate.id],
                  let (_, paneID) = agentPane(in: layout) else { return true }
            return !live.contains(paneID)
        }
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
        let pilotChanged = decoded.pilot != config.pilot
        config = decoded
        settings = decoded.work
        Remote.setTargets(Dictionary(uniqueKeysWithValues: decoded.hosts.map { ($0.key, $0.value.ssh) }))
        if !isFixture {
            TerminalSurfaces.shared.persist = decoded.work.persist
            Updater.shared.apply(decoded.updates)
        }
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
        // PRs nobody set by hand follow the new pilot settings.
        if pilotChanged { settlePilots() }
    }

    /// Finds git and gh (config, login shell PATH, usual places) and hands the search path to new panes.
    func detectTools(force: Bool = false) async {
        let report = await ToolLocator.shared.configure(config.tools, force: force)
        tools = report
        TerminalSurfaces.shared.searchPath = report.pathVariable
        // zmx is yours to install: found on the search path like any tool, never shipped with heed.
        TerminalSurfaces.shared.zmxPath = report.searchPath.lazy.map { "\($0)/zmx" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if settings.persist == .zmx, TerminalSurfaces.shared.zmxPath == nil {
            flash = "persist = \"zmx\" but zmx is not installed: \(ZmxInstall.mac.joined(separator: "; ")) (panes stay plain shells until then)"
        }
        if force {
            flash = report.problems.first
                ?? report.tools.map { "\($0.name): \(Paths.abbreviate($0.path ?? "?"))" }.joined(separator: "  ")
        }
    }

    /// Settings writes one value into config.toml; the watcher picks the change up like any other edit.
    /// Removes a key from config.toml: an org or repo override going back to what it inherits.
    func unsetConfig(_ path: [String]) {
        do {
            try ConfigWatcher.remove(path, in: configFile)
        } catch {
            flash = "could not write config.toml: \(error)"
        }
    }

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
        // A helper's hooks: its own state, not the session's. Idle may mean its PR is done; asking or blocked shows the
        // session in Needs you (through `sessionPilot`).
        if let pane = message.pane, helpers.values.contains(where: { $0.paneID == pane }) {
            if case let .state(state, _) = message.kind {
                helperStates[pane] = state
                rebuildList()
                if state == .idle || state == .done {
                    closeFinishedHelpers()
                    let waiting = pendingDelivery.filter { session.trackedPRs.contains($0) }
                    for ref in waiting {
                        deliver(ref, explicit: false)
                    }
                }
            }
            return
        }
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
            // Sent by the agent's hooks when it opened a PR (or by `heed pr add`).
            guard let pull = PullRef(url: url), session.track(pull, because: "opened by \(session.agent)") else {
                return
            }
            logPilot(pull, .watch, "opened by \(session.agent) in \(session.title)")
            fetchDetail(pull)
        case let .issueAdd(url):
            guard let issue = IssueRef(url: url), !session.issues.contains(issue) else { return }
            session.issues.append(issue)
            session.hiddenIssues.removeAll { $0 == issue }
            session.record("linked \(issue.repo.name)#\(issue.number)")
            Task { await refreshIssueInfo(force: [issue]) }
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
        // The selection is a session, not a row. A session moving between groups (parked to working, say) reorders
        // the list; the cursor follows the session it was on, so what you look at and type into never changes under
        // you. Read before the rebuild: `currentSession` still indexes the old list here.
        rebuildingList = true
        defer { rebuildingList = false }
        let selected = currentSession?.id
        let hold = currentSession.flatMap { session in
            list.group(of: session.id).map {
                SessionHold(id: session.id, group: $0, pinned: session.pinned, parked: session.parked)
            }
        }
        let filter = sessionFilter
        list = SessionList(filter.isEmpty ? sessions : sessions.filter { session in
            FilterQuery.matches(
                filter,
                [session.title, session.worktreeName, session.branch, session.agent, session.location.label]
                    + session.repos.map(\.name) + session.trackedPRs.map { "#\($0.number)" }
            )
        }, pilot: sessionPilot, hold: hold)
        if let selected, let index = list.ordered.firstIndex(where: { $0.id == selected }) {
            cursor = index
        } else {
            cursor = min(cursor, max(list.ordered.count - 1, 0))
        }
        heldSession = currentSession?.id
    }

    private func replace(with domain: Domain) {
        sessions = domain.sessions
        // Helper tabs do not come back: a PR that still needs work gets a fresh one on its next round.
        layouts = isFixture ? domain.layouts : domain.layouts.mapValues { layout in
            var layout = layout
            let keep = layout.tabs.filter { !$0.tree.panes.allSatisfy { $0.role == .helper } }
            if keep.count != layout.tabs.count, !keep.isEmpty {
                layout.tabs = keep
                layout.activeTab = min(layout.activeTab, keep.count - 1)
            }
            return layout
        }
        repos = domain.repos
        worktrees = domain.worktrees
        history = domain.history
        github = domain.github
        pullDetails = domain.pullDetails
        feedback = domain.feedback
        pilotLog = domain.pilotLog
        mergeRuns = domain.mergeRuns
        registeredWorktrees = domain.registeredWorktrees
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
        if after.pilotLog != before.pilotLog { pilotLog = after.pilotLog }
        if after.mergeRuns != before.mergeRuns { mergeRuns = after.mergeRuns }
        if after.registeredWorktrees != before.registeredWorktrees {
            registeredWorktrees = after.registeredWorktrees
            rebuildWorktreeRows()
        }
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
            pullDetails: pullDetails, feedback: feedback, pilotLog: pilotLog,
            mergeRuns: mergeRuns, registeredWorktrees: registeredWorktrees
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
        let known = repos.filter { $0.location.isLocal && !found.map(\.path).contains($0.path) }
        let clones = Dictionary(grouping: found + known) { $0.repo }
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
        for worktree in worktrees where !worktree.isMain && worktree.location.isLocal {
            if let date = await Git.lastCommitDate(at: worktree.path) { commits[worktree.path] = date }
        }
        lastCommits = commits
        await refreshHosts()
    }

    // MARK: Hosts

    /// How each host's link stands, by name: the checks heed last ran.
    private(set) var hostStatuses: [String: HostStatus] = [:]

    /// `[hosts.<name>]`, by name.
    var hostList: [HostConfig] { config.hosts.values.sorted { $0.name < $1.name } }

    func hostStatus(_ name: String) -> HostStatus { hostStatuses[name] ?? .unknown }

    /// Checks every host, and for each that answers: its repos and their worktrees, with status. Hosts that do not
    /// answer keep what was last seen of them (shown stale).
    func refreshHosts() async {
        guard !isFixture else { return }
        await withTaskGroup(of: (String, HostStatus).self) { group in
            for host in hostList {
                let lastSeen: Date? = if case let .connected(info) = hostStatuses[host.name] { info.checkedAt } else {
                    if case let .offline(_, seen) = hostStatuses[host.name] { seen } else { nil }
                }
                group.addTask { await (host.name, HostProbe.check(host.name, lastSeen: lastSeen)) }
            }
            for await (name, status) in group {
                hostStatuses[name] = status
                if case let .connected(info) = status { TerminalSurfaces.shared.hostZmx[name] = info.zmxPath }
            }
        }
        startHostEvents()
        for host in hostList where hostStatus(host.name).isConnected {
            let records = await RemoteScan.scan(host)
            commit(records.map { .repoUpserted($0) })
            for record in records {
                guard var listed = try? await Git.worktrees(of: record) else { continue }
                for index in listed.indices {
                    listed[index].status = try? await Git.status(at: listed[index].path, on: record.location)
                }
                commit(.worktreesListed(repo: record.repo, listed))
            }
        }
    }

    /// Whether heed manages a worktree, and how it stands.
    func registration(of worktree: Worktree) -> WorktreeRegistration {
        guard let host = worktree.location.hostName else { return .registered }
        if !hostStatus(host).isConnected, !isFixture, hostStatuses[host] != nil { return .stale }
        if case .offline = hostStatus(host) { return .stale }
        return registeredWorktrees.contains(worktree.id) ? .registered : .discovered
    }

    // MARK: Sessions on hosts

    private var hostEvents: [String: HostEventStream] = [:]

    /// One event stream per host that has sessions and answers: its agents' hooks, back into `receive`.
    private func startHostEvents() {
        guard !isFixture else { return }
        for host in Set(sessions.compactMap(\.host)) where hostStatus(host).isConnected {
            let stream = hostEvents[host] ??
                HostEventStream(host: host) { [weak self] message in self?.receive(message) }
            hostEvents[host] = stream
            stream.start()
        }
    }

    /// What heed puts on a host for its agents' hooks, with the paths they are given there.
    private func hostIntegration(home: String) -> (files: [String: String], integration: IntegrationFiles) {
        let integration = IntegrationFiles(
            directory: URL(fileURLWithPath: home).appendingPathComponent(".heed"),
            heedBinary: "\(home)/.heed/bin/heed-hook"
        )
        let files = [
            "~/.heed/claude-hooks.json": AgentIntegration.claudeSettingsJSON(),
            "~/.heed/heed-pi.js": AgentIntegration.piExtensionSource,
            "~/.heed/heed-opencode.js": AgentIntegration.opencodePluginSource,
        ]
        return (files, integration)
    }

    /// `↩` on a registered worktree on a host: heed's files go on the host if they are not there yet, then the worktree
    /// becomes a session there, its agent in a zmx session that outlives the link.
    private func importOnHost(_ rows: [Worktree]) {
        guard let host = rows.first?.location.hostName, rows.allSatisfy({ $0.location == .host(host) }) else {
            return flash = "one host at a time"
        }
        guard case let .connected(info) = hostStatus(host), let home = info.home else {
            return flash = "@\(host) does not answer: gH shows why"
        }
        let rows = rows.filter { session(for: $0) == nil }
        guard !rows.isEmpty else { return }
        guard !isFixture else { return flash = "fixture: no IO" }
        let (files, integration) = hostIntegration(home: home)
        let agent = settings.agent(settings.defaultAgent)
        flash = "setting up @\(host)…"
        Task {
            do {
                try await HostSetup.install(on: host, files: files)
            } catch {
                flash = "could not set up @\(host): \(error)"
                return
            }
            var firstID: String?
            for worktree in rows {
                let changes = Import.session(for: worktree, agent: agent, resume: nil, integration: integration)
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                for case let .sessionUpserted(session) in changes where firstID == nil {
                    firstID = session.id
                }
                commit(changes)
                commit(.worktreeRegistered(worktree.id))
            }
            startHostEvents()
            view = .sessions
            if let firstID { select(sessionID: firstID) }
            flash = info.zmxPath == nil
                ? "started \(agent?.name ?? "a shell") on @\(host), not persistent: install zmx there (gH says how)"
                : "started \(agent?.name ?? "a shell") on @\(host)"
        }
    }

    /// `↩` on a discovered worktree: heed manages it from now on.
    private func register(_ worktrees: [Worktree]) {
        let found = worktrees.filter { registration(of: $0) == .discovered }
        guard !found.isEmpty else { return }
        commit(found.map { .worktreeRegistered($0.id) })
        flash = found.count == 1
            ? "registered \(found[0].repo.name)/\(found[0].branch ?? "worktree") \(found[0].location.label)"
            : "registered \(found.count) worktrees"
    }

    // MARK: Hosts picker (gH)

    /// A host in the picker: one heed has, or one from ~/.ssh/config it could add.
    struct HostRow: Sendable, Identifiable {
        let name: String
        let summary: String
        let configured: Bool
        var id: String { name }
    }

    private(set) var hostsPicker: Typeahead<HostRow>?
    /// `gB` / `gR` with more than one place to go.
    private(set) var linkPicker: LinkPicker?
    /// get it green / get it merged tabs (`[pilot] send_to = "tab"`), by PR. In memory only: they are dropped at
    /// launch.
    struct HelperTab: Equatable {
        let sessionID: String
        let tabID: String
        let paneID: String
        let goal: HelperGoal
        /// Its companion checkout, removed when the tab closes; and the session's worktree it sits beside.
        var companion: String?
        var companionBranch: String?
        var record: RepoRecord?
        var mainPath: String?
    }

    /// PRs whose helper's companion is being made (async), so one is not made twice.
    private var spawningHelpers: Set<String> = []

    private(set) var helpers: [String: HelperTab] = [:]
    /// Each helper pane's own state, from its hooks; never the session's.
    private(set) var helperStates: [String: AgentState] = [:]
    /// Titles and states of the issues sessions link to (fetched, not cached on disk).
    private(set) var issueInfo: [IssueRef: IssueInfo] = [:]
    private var issueInfoFetchedAt: [IssueRef: Date] = [:]

    private func openHostsPicker() {
        let configured = hostList.map { HostRow(name: $0.name, summary: $0.ssh, configured: true) }
        let text = isFixture ? "" : (try? String(contentsOf: SSHConfig.defaultFile(), encoding: .utf8)) ?? ""
        let available = SSHConfig.entries(text).filter { config.hosts[$0.alias] == nil }
            .map { HostRow(name: $0.alias, summary: $0.summary, configured: false) }
        hostsPicker = Typeahead(items: configured + available) { [$0.name, $0.summary] }
        if !isFixture { Task { await refreshHosts() } }
    }

    private func answerHostsPicker(_ stroke: KeyStroke) {
        guard var picker = hostsPicker else { return }
        switch picker.handle(stroke) {
        case .handled: hostsPicker = picker
        case .cancel: hostsPicker = nil
        case let .picked(row): pickHost(row)
        }
    }

    /// ↩ on a host: one from ~/.ssh/config is added (`[hosts.<name>]`) and checked; one heed has is checked again.
    func pickHost(_ row: HostRow) {
        if !row.configured {
            setConfig(["hosts", row.name, "ssh"], .string(row.name))
            flash = "added @\(row.name); checking it…"
        } else {
            flash = "checking @\(row.name)…"
        }
        hostsPicker = nil
        guard !isFixture else { return }
        Task { await refreshHosts() }
    }

    func cancelHostsPicker() { hostsPicker = nil }

    /// `@` (or `:host.filter devbox`): narrows the view you are on to one host, through its filter.
    private func filterByHost(_ name: String?) {
        if let name {
            filters[view] = "@\(name)"
            return
        }
        startFilter()
        filters[view] = "@"
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
                detail: [session.trackedPRs.first.map { "#\($0.number)" }, session.host.map { "@\($0)" }]
                    .compactMap(\.self).joined(separator: " ").nilIfEmpty
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
        case .watch:
            let rows = pilotRows
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
        // One row per repo in the repo list, wherever its clones are: the one on this Mac if there is one.
        var seen: Set<Repo> = []
        let unique = (repos.filter(\.location.isLocal) + repos.filter { !$0.location.isLocal })
            .filter { seen.insert($0.repo).inserted }
        sortedRepos = RepoOrder.sorted(unique, counts: counts)
        worktreeCount = counts.values.reduce(0, +)
        let rank = Dictionary(sortedRepos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let filter = filter(for: .repos)
        // A helper's companion checkout is heed's own, not yours to import or clean up.
        let companions = Set(helpers.values.compactMap(\.companion))
        let added = worktrees.filter { !$0.isMain && !companions.contains($0.path) }
        let roots = settings.pathRoots
        let matching = filter.isEmpty ? added : added.filter { worktree in
            FilterQuery.matches(filter, [
                worktree.repo.slug, worktree.branch ?? "", Paths.split(worktree.path, roots: roots).relative,
                session(for: worktree)?.agent ?? "", worktree.location.label,
            ])
        }
        worktreeRows = matching.sorted {
            $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        worktreeRowCounts = Dictionary(grouping: worktreeRows, by: \.repo.slug).mapValues(\.count)
    }

    func session(for worktree: Worktree) -> Session? {
        sessions.first {
            $0.location == worktree.location && $0.branch == worktree.branch && $0.repos.contains(worktree.repo)
        }
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
        case .inbox, .issues, .prs, .watch: itemIDs(view).indices.map { HintTarget.row(view, $0) }
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
        if hostsPicker != nil {
            answerHostsPicker(stroke)
            return true
        }
        if linkPicker != nil {
            answerLinkPicker(stroke)
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
            case .inbox, .issues, .prs, .watch: itemCursor[view] ?? 0
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
        case "pr.untrack": untrackPull(command.arguments.first)
        case "select.pin": pinSelected()
        case "work.again": openStartWork(prompt: currentSession?.prompt ?? "")
        case "worktree.new":
            openStartWork(prompt: "")
            if worktreeRows.indices.contains(repoCursor) {
                let row = worktreeRows[repoCursor]
                startWork?.choose(repo: StartContext.id(row.repo, row.location))
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
        case "tab.close": closeTab()
        case "tab.next": cycleTab(by: count)
        case "tab.prev": cycleTab(by: -count)
        case "tab.new": newTab()
        case "view": if let target = AppView(rawValue: command.arguments.first ?? "") { view = target }
        case "view.history": view = .history
        case "view.watch": view = .watch
        case "view.repos": view = .repos
        case "view.sessions": view = .sessions
        case "view.inbox": view = .inbox
        case "view.issues": view = .issues
        case "view.prs": view = .prs
        case "overlay.help": overlay = overlay == .help ? nil : .help
        case "tutor": openTutor(command.arguments)
        case "host.open": openHostsPicker()
        case "host.filter": filterByHost(command.arguments.first)
        case "agents.stop": confirmStopAgents()
        case "update.check":
            if Updater.shared.isRunning { Updater.shared.checkForUpdates() } else {
                flash = "updates are off in this build: release builds check GitHub once a day"
            }
        case "tutor.hide": hideTutorReminder(all: command.arguments.first == "all")
        case "tutor.back", "tutor.skip", "tutor.exit":
            guard tutor != nil else {
                flash = "the tutor is not running (:tutor starts it)"
                return
            }
            switch command.name {
            case "tutor.back": tutorBack()
            case "tutor.skip": tutorSkip()
            default: onTutorRequest?(.exit)
            }
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
        case "open.repo": openRepo()
        case "links.pick": pickLinks()
        case "issue.add": addIssue(command.arguments.first)
        case "issue.remove": removeIssue(command.arguments.first)
        case "overlay.pr": togglePullOverlay()
        case "overlay.item": toggleItemOverlay()
        case "pr.next": cyclePull(by: 1)
        case "pr.prev": cyclePull(by: -1)
        case "jump.back": closeReaderOrOverlay()
        case "feedback.queue": toggleQueued()
        case "feedback.send": if let ref = feedbackPull { deliver(ref, explicit: true) }
        // feedback.mode and feedback.watch were their names before the pilot settings; both still work.
        case "pilot.green", "feedback.mode": cyclePilotGreen()
        case "pilot.watch", "feedback.watch": togglePilotWatch()
        case "pilot.pause": pausePilot(command.arguments.first)
        case "pilot.retry": retryPilot()
        case "pilot.helper": showHelper()
        case "pilot.why": showPilotWhy()
        case "pilot.merge": togglePilotMerge()
        case "pilot.copilot":
            let refs = pilotTargets
            if refs.isEmpty { flash = "no PR here" } else { Task { await askCopilot(refs, byHand: true) } }
        case "pilot.reviewers":
            let refs = pilotTargets
            if refs.isEmpty { flash = "no PR here" } else { Task { await requestReviews(refs, byHand: true) } }
        case "merge.run": runMergeCommand(command.arguments.first)
        case "merge.queue": showMergeQueue(command.arguments.first)
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
                    flash = "no Settings section \(name) (general, agents, colors, cleanup, pilot, keys)"
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
        case .inbox, .issues, .prs, .watch: setRow((itemCursor[view] ?? 0) + delta)
        case .sessions: setCursor(cursor + delta)
        }
    }

    /// The current list's group of each row, and the cursor: sidebar groups, repos, days.
    private var rowGroups: (keys: [String], cursor: Int) {
        switch view {
        case .sessions: (list.ordered.map { sessionGroup($0).rawValue }, cursor)
        case .repos: (worktreeRows.map(\.repo.slug), repoCursor)
        case .inbox: (inboxRows.map(\.repo.slug), cursor(in: .inbox))
        case .issues: (issueRows.map(\.repo.slug), cursor(in: .issues))
        case .prs: (pullRows.map(\.ref.repo.slug), cursor(in: .prs))
        case .watch: (pilotRows.map(\.status.group.rawValue), cursor(in: .watch))
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
        if view == .watch { mergeQueueShown = nil }
        if [.inbox, .issues, .prs, .watch].contains(view) {
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
        var cancel = "Cancel"
        /// Red accept button for removals; neutral for the rest.
        var destructive = true
        var action: @MainActor () -> Void
        /// A third answer, between cancel and accept: its label, its key, and what it does.
        /// Other answers besides accept and cancel, each with its own key; `destructive` ones are drawn red.
        var alternatives: [Alternative] = []

        struct Alternative {
            var label: String
            var key: String
            var destructive = false
            var action: @MainActor () -> Void
        }

        /// What cancelling does besides closing the dialog.
        var onCancel: (@MainActor () -> Void)?
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
            let cancel = confirmation?.onCancel
            confirmation = nil
            flash = "cancelled"
            cancel?()
        default:
            if let alternative = confirmation?.alternatives.first(where: { stroke == KeyStroke($0.key) }) {
                confirmation = nil
                alternative.action()
            }
        }
    }

    func acceptConfirmation() { answerConfirmation(KeyStroke("y")) }
    func chooseAlternative(_ key: String) {
        answerConfirmation(KeyStroke(key))
    }

    func cancelConfirmation() { answerConfirmation(.escape) }

    /// `agents.stop`: with zmx, agents outlive heed; this ends every one of them (and every shell in a pane).
    private func confirmStopAgents() {
        guard TerminalSurfaces.shared.persist == .zmx else {
            return flash = "agents stop when heed quits ([sessions] persist = \"none\")"
        }
        let running = sessions.count { [.working, .blocked, .asking].contains($0.state.state) }
        ask(Confirmation(
            title: "Stop every agent?",
            lines: [
                running > 0 ? "\(running) agent\(running == 1 ? " is" : "s are") working and will stop" :
                    "Agents and shells in every pane stop",
                "Sessions stay; their panes reopen as shells, and resume works as after a restart",
            ],
            accept: "Stop all"
        ) { [weak self] in
            Task { @MainActor in
                let count = await TerminalSurfaces.shared.stopAll()
                self?.flash = "stopped \(count) terminal\(count == 1 ? "" : "s")"
            }
        })
    }

    /// Set once a quit was confirmed, so the second terminate goes through.
    private(set) var quitConfirmed = false

    /// ⌘Q or Quit in the menu bar with agents running: Heed comes forward and asks. True when it asked (the quit
    /// waits for the answer), false when nothing runs and quitting can go ahead.
    func confirmQuitIfAgentsRun() -> Bool {
        // With zmx, quitting leaves the agents running: heed reattaches to them on its next launch.
        if TerminalSurfaces.shared.persist == .zmx { return false }
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
        let (removals, kept, lines) = deletion(of: session)
        ask(Confirmation(
            title: "Delete \(session.title)?",
            lines: ["The agent and its panes stop; the session moves to History"] + lines,
            kept: kept,
            accept: "Delete"
        ) { [weak self] in self?.deleteSession(session.id, removals: removals, kept: kept) })
    }

    /// What deleting a session removes: its worktrees, minus those with work not saved anywhere else.
    private func deletion(of session: Session) -> ([SweepPlan.Removal], [String], [String]) {
        let mine = worktrees.filter { !$0.isMain && session.owns($0) }
        let (removals, kept) = planRemoval(mine, sessionsFollow: false)
        let lines = removals.map { removal in
            "remove \(removal.worktree.repo.name)/\(removal.worktree.branch ?? "")"
                + (removal.deleteBranch ? " and its local branch" : "")
        } + (mine.isEmpty ? ["No worktree to remove"] : [])
        return (removals, kept, lines)
    }

    private func deleteSession(_ id: String, removals: [SweepPlan.Removal], kept: [String]) {
        closeSession(id)
        if !removals.isEmpty { removeWorktrees(removals, kept: kept) }
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
        guard let session = currentSession else { return }
        closeSession(session.id)
    }

    /// A session to History, its panes closed; its worktree stays.
    private func closeSession(_ id: String) {
        guard var session = sessions.first(where: { $0.id == id }) else { return }
        let minutes = Int(Date().timeIntervalSince(session.createdAt) / 60)
        session.record("ended after \(minutes / 60)h \(minutes % 60)m")
        // The panes are read before the close drops the layout.
        let panes = layouts[id]?.tabs.flatMap(\.tree.panes) ?? []
        commit(.sessionClosed(HistoryEntry(
            session: session, closedAt: Date(), outcome: HistoryEntry.outcome(closing: session)
        )))
        for pane in panes {
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
        if [.inbox, .issues, .prs, .watch].contains(view) {
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
        let companions = Set(helpers.values.compactMap(\.companion))
        let candidates = worktrees.filter {
            session(for: $0) == nil && $0.location.isLocal && !companions.contains($0.path)
        }.sorted {
            if $0.isMain != $1.isMain { return !$0.isMain }
            return $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        // Open even when every listed worktree has a session: a typed path imports any other.
        // The path below its root, so a root's own words (code, Projects) do not match every worktree.
        let roots = settings.pathRoots
        importPicker = Typeahead(items: candidates) {
            [$0.repo.slug, $0.branch ?? "", Paths.split($0.path, roots: roots).relative]
        }
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
        // On a host: ↩ registers what a scan found. Sessions there are not supported yet.
        if rows.contains(where: { !$0.location.isLocal }) {
            if rows.contains(where: { registration(of: $0) == .discovered }) { return register(rows) }
            if let existing = session(for: rows[0]) {
                view = .sessions
                return select(sessionID: existing.id)
            }
            return importOnHost(rows)
        }
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
                    [
                        entry.session.title, entry.session.prompt, entry.session.branch, entry.session.agent,
                        entry.session.location.label,
                    ] + entry.session.repos.map(\.name)
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
    /// `:pr.untrack [url]`: the session stops following a PR (the one in the overlay, or the session's only one), and
    /// no rule adds it back.
    private func untrackPull(_ argument: String?) {
        guard let session = currentSession else { return flash = "no session here" }
        let pull = argument.flatMap(PullRef.init(url:)) ?? feedbackPull
            ?? (session.trackedPRs.count == 1 ? session.trackedPRs.first : nil)
        guard let pull, session.trackedPRs.contains(pull) else {
            return flash = session.trackedPRs.isEmpty ? "this session tracks no PR"
                : "which PR? :pr.untrack <url>, or open it (go) first"
        }
        updateCurrent { session in
            session.trackedPRs.removeAll { $0 == pull }
            session.untrackedPRs.append(pull)
            session.record("stopped tracking PR \(pull.repo.name)#\(pull.number) (by you)")
        }
        flash = "stopped tracking \(pull.repo.name)#\(pull.number); :pr.track adds it back"
    }

    /// After a PR's detail arrives: the sessions tracking it also take the PRs that link to it and are yours, opened
    /// since the session started (a follow-up, a companion change in another repo).
    private func trackLinked(_ detail: PullDetail) {
        guard let references = detail.references, !references.isEmpty else { return }
        let changes = sessions.filter { $0.trackedPRs.contains(detail.ref) }.compactMap { session -> DomainChange? in
            var updated = session
            let added = PullTracking.linked(references, session: session, viewer: github.viewer).track
                .filter { updated.track($0.ref, because: "links to \(detail.ref.repo.name)#\(detail.ref.number)") }
            return added.isEmpty ? nil : .sessionUpserted(updated)
        }
        commit(changes)
        for case let .sessionUpserted(session) in changes {
            for ref in session.trackedPRs where pullDetails[ref.description] == nil {
                fetchDetail(ref)
            }
        }
    }

    /// PRs that mention this one but are someone else's (or older than the session): shown, not tracked.
    func suggestedLinks(for ref: PullRef) -> [PullDetail.Reference] {
        guard let references = pullDetails[ref.description]?.references,
              let session = sessions.first(where: { $0.trackedPRs.contains(ref) })
        else { return [] }
        return PullTracking.linked(references, session: session, viewer: github.viewer).suggest
    }

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
            session.untrackedPRs.removeAll { $0 == pull }
            session.track(pull, because: "by you")
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
        case .watch: pilotRows.map(\.id)
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

    /// `gB`: what is under the cursor. In Sessions (outside the overlay and reader) the session's links: one opens,
    /// several offer the picker, none opens its repo.
    private func openInBrowser() {
        if view == .sessions, issueReader == nil, feedbackPull == nil, let session = currentSession {
            let links = links(of: session)
            switch links.count {
            case 0: return openRepo()
            case 1: return open(links[0], browser: true)
            default: linkPicker = LinkPicker(title: "Open in the browser", links: links)
            }
            return
        }
        guard let text = urlUnderCursor, let url = URL(string: text) else {
            flash = "nothing to open"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Links

    /// A session's issues: added by hand, closed by its prompt, closed by its PRs.
    func issues(of session: Session) -> [IssueRef] {
        let closedByPulls = session.trackedPRs.flatMap { ref in
            (pullDetails[ref.description]?.closes ?? []).map { IssueRef(repo: $0.repo, number: $0.number) }
        }
        return IssueLinks.issues(
            added: session.issues, prompt: session.prompt, defaultRepo: session.repos.first,
            closedByPulls: closedByPulls, hidden: session.hiddenIssues
        )
    }

    /// Everything a session links to on GitHub, in the inspector's order: open PRs, merged, closed, then issues.
    func links(of session: Session) -> [SessionLink] {
        IssueLinks.ordered(
            pulls: session.trackedPRs, state: { self.github.pull($0)?.state }, issues: issues(of: session),
            closed: { self.issueInfo[$0]?.closed ?? false }
        )
    }

    /// An issue as the reader shows it: from the issue sync when it has it, else from what was fetched for the link.
    func issue(for ref: IssueRef) -> Issue? {
        if let known = github.issues.first(where: { $0.repo == ref.repo && $0.number == ref.number }) { return known }
        guard let info = issueInfo[ref] else { return nil }
        return Issue(
            repo: ref.repo, number: ref.number, title: info.title, url: ref.url, body: info.body, labels: info.labels,
            author: info.author, updatedAt: info.updatedAt
        )
    }

    /// A link clicked or picked: a PR opens the overlay on it, an issue the reader; `browser` (⌘-click, `gB`) opens it
    /// on GitHub instead.
    func open(_ link: SessionLink, browser: Bool = false) {
        linkPicker = nil
        if browser {
            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            return
        }
        switch link {
        case let .pull(ref):
            if let index = list.ordered.firstIndex(where: { $0.trackedPRs.contains(ref) }), view == .sessions {
                setCursor(index)
            }
            overlayPull = ref
            overlay = .pr
            feedbackCursor = 0
            fetchDetail(ref)
        case let .issue(ref):
            if let issue = issue(for: ref) {
                issueReader = issue
            } else {
                flash = "fetching \(ref.repo.name)#\(ref.number)…"
                Task {
                    await refreshIssueInfo(force: [ref])
                    if let issue = issue(for: ref) { issueReader = issue } else { open(link, browser: true) }
                }
            }
        case .repo:
            open(link, browser: true)
        }
    }

    /// The repos under the cursor, for `gR`: a session's (all of them), a Repos row's, an item's.
    private var reposUnderCursor: [Repo] {
        if let issue = issueReader { return [issue.repo] }
        if let ref = feedbackPull, overlay == .pr || reader != nil { return [ref.repo] }
        let index = cursor(in: view)
        switch view {
        case .sessions: return currentSession?.involvedRepos ?? []
        case .repos: return worktreeRows.indices.contains(repoCursor) ? [worktreeRows[repoCursor].repo] : []
        case .inbox: return inboxRows.indices.contains(index) ? [inboxRows[index].repo] : []
        case .issues: return issueRows.indices.contains(index) ? [issueRows[index].repo] : []
        case .prs: return pullRows.indices.contains(index) ? [pullRows[index].ref.repo] : []
        case .watch: return pilotRows.indices.contains(index) ? [pilotRows[index].ref.repo] : []
        case .history: return selectedHistory?.session.repos ?? []
        }
    }

    /// `gR`: the repo under the cursor on GitHub; a session in several repos offers the picker.
    private func openRepo() {
        let repos = reposUnderCursor.filter { $0.org != "local" }
        switch repos.count {
        case 0: flash = "no repo here"
        case 1: open(.repo(repos[0]), browser: true)
        default: linkPicker = LinkPicker(title: "Open a repo", links: repos.map(SessionLink.repo))
        }
    }

    /// `:links.pick`: the picker over the session's links (and its repos when it has none).
    private func pickLinks() {
        guard let session = currentSession else { return flash = "no session here" }
        let links = links(of: session)
        linkPicker = LinkPicker(
            title: "Open in the browser", links: links.isEmpty ? session.involvedRepos.map(SessionLink.repo) : links
        )
    }

    private func answerLinkPicker(_ stroke: KeyStroke) {
        guard var picker = linkPicker else { return }
        switch picker.handle(stroke) {
        case .handled: linkPicker = picker
        case .cancel: linkPicker = nil
        case let .open(links):
            linkPicker = nil
            for link in links {
                open(link, browser: true)
            }
        }
    }

    func cancelLinkPicker() { linkPicker = nil }

    /// `:issue.add <url>` (or the copied URL): links an issue to the session.
    private func addIssue(_ argument: String?) {
        let text = argument ?? NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let ref = IssueRef(url: text) else {
            return flash = argument == nil ? "copy an issue URL first, or :issue.add <url>" : "not an issue URL: \(text)"
        }
        guard currentSession != nil else { return flash = "no session to link \(ref.repo.name)#\(ref.number) to" }
        updateCurrent { session in
            session.hiddenIssues.removeAll { $0 == ref }
            if !session.issues.contains(ref) { session.issues.append(ref) }
        }
        flash = "linked \(ref.repo.name)#\(ref.number)"
        Task { await refreshIssueInfo(force: [ref]) }
    }

    /// `:issue.remove [url]`: takes an issue off the session (the given one, else its first).
    private func removeIssue(_ argument: String?) {
        guard let session = currentSession else { return }
        guard let ref = argument.flatMap(IssueRef.init(url:)) ?? issues(of: session).first else {
            return flash = "no issue on this session"
        }
        updateCurrent { session in
            session.issues.removeAll { $0 == ref }
            if !session.hiddenIssues.contains(ref) { session.hiddenIssues.append(ref) }
        }
        flash = "unlinked \(ref.repo.name)#\(ref.number)"
    }

    /// Fetches titles and states for the issues sessions link to: those not seen in ten minutes, and `force`.
    func refreshIssueInfo(force: [IssueRef] = []) async {
        guard !isFixture else { return }
        let now = Date()
        let wanted = Set(sessions.flatMap(issues(of:))).filter { ref in
            now.timeIntervalSince(issueInfoFetchedAt[ref] ?? .distantPast) > 600
        }.union(force)
        guard !wanted.isEmpty, let fetched = try? await GitHub.issueInfo(Array(wanted)) else { return }
        for ref in wanted {
            issueInfoFetchedAt[ref] = now
        }
        issueInfo.merge(fetched) { _, new in new }
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
        case .watch:
            let rows = pilotRows
            return rows.indices.contains(index) ? rows[index].ref : nil
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
            let wasOpen = pullDetails[ref.description].map { $0.state != "MERGED" } ?? false
            let before = feedback[ref.description]?.items.filter { $0.status != .resolved }.map(\.id) ?? []
            // The pipeline carries what the settings say before the fetch merges in, so new items arrive as the
            // PR's green mode wants (queued when auto).
            var pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
            if pipeline.settle(pilotSettings(for: ref)) || feedback[ref.description] == nil {
                commit(.feedbackChanged(pipeline))
            }
            commit(.pullDetailFetched(detail))
            trackLinked(detail)
            let fixed = feedback[ref.description]?.items
                .filter { before.contains($0.id) && $0.status == .resolved } ?? []
            let checks = fixed.compactMap { if case let .check(name) = $0.kind { name } else { nil } }
            if !checks.isEmpty { flash = "\(checks.joined(separator: ", ")) passing now on #\(ref.number)" }
            // A merge is what leaves the queue's other PRs behind.
            if wasOpen, detail.state == "MERGED", pilot(for: ref).merge != .off,
               pilotSettings(for: ref).updateBranches
            {
                runMergeQueue(ref.repo.slug, why: "#\(ref.number) merged")
            }
            // Before delivery, so a conflict Copilot takes does not also go to the agent.
            await askCopilot([ref], byHand: false)
            await requestReviews([ref], byHand: false)
            fetchFailedLogs(ref, detail)
            if feedback[ref.description]?.autoFeed == .auto { deliver(ref, explicit: false) }
            mergeIfTurnedGreen(ref, detail)
        }
    }

    /// Jobs whose failed log was asked for already, so a log that cannot be had is not asked for on every fetch.
    private var askedLogs: Set<String> = []

    /// For each open failed-check item without a log: the job's failed steps, saved under the caches folder, so the
    /// prompt can point the agent at the actual error instead of "build failed".
    private func fetchFailedLogs(_ ref: PullRef, _ detail: PullDetail) {
        guard !isFixture, let pipeline = feedback[ref.description] else { return }
        let wanted = pipeline.items.compactMap { item -> (id: String, check: String, job: String)? in
            guard case let .check(name) = item.kind, item.status != .resolved, item.logPath == nil,
                  let job = GitHub.jobID(fromDetailsURL: detail.failingChecks.first { $0.name == name }?.url),
                  !askedLogs.contains(job)
            else { return nil }
            return (item.id, name, job)
        }
        guard !wanted.isEmpty else { return }
        askedLogs.formUnion(wanted.map(\.job))
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/logs")
        Task {
            var saved: [String: String] = [:]
            for item in wanted {
                guard let log = try? await GitHub.failedLog(repo: ref.repo, job: item.job),
                      !log.isEmpty else { continue }
                let name = "\(ref.repo.org)-\(ref.repo.name)-\(ref.number)-\(item.check)"
                    .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                let file = folder.appendingPathComponent("\(name).log")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard (try? log.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
                saved[item.id] = file.path
            }
            guard !saved.isEmpty, var pipeline = feedback[ref.description] else { return }
            for index in pipeline.items.indices {
                if let path = saved[pipeline.items[index].id] { pipeline.items[index].logPath = path }
            }
            commit(.feedbackChanged(pipeline))
        }
    }

    /// Details for the PRs active sessions track and watch, so auto-feed sees new feedback: the one on screen every
    /// time, the others only when the last sync says their checks or threads moved, or every fifth poll.
    private func refreshWatchedDetails() async {
        resumeExpiredPauses()
        closeFinishedHelpers()
        // Held because you were working in the session: try again, now that time has passed.
        for ref in pendingDelivery {
            deliver(ref, explicit: false)
        }
        runDueMergeQueues()
        let open = [overlay == .pr ? overlayPull : nil, reader].compactMap(\.self)
        let now = Date()
        let refs = Set(sessions.flatMap(\.trackedPRs)).filter { ref in
            // Unwatched PRs keep only their summary from the sync; opening one still fetches it (`open`).
            guard pilot(for: ref).watching else { return false }
            return open.contains(ref) || syncSchedule.needsDetail(
                pull: github.pull(ref), detail: pullDetails[ref.description], now: now
            )
        }
        for ref in Set(open).union(refs).prefix(10) {
            fetchDetail(ref)
        }
    }

    // MARK: Pilot

    /// A PR as the Watch view lists it.
    struct PilotRow: Identifiable {
        let ref: PullRef
        let pull: PullRequest?
        let status: PilotStatus
        let effective: PullFeedback.Effective
        let session: Session?
        var id: String { ref.description }
        var title: String { pull?.title ?? session?.title ?? "#\(ref.number)" }
    }

    func pilotSettings(for ref: PullRef) -> PilotSettings { config.pilot.resolve(ref.repo) }

    /// What applies to a PR now: a choice made on it by hand, else its org or repo settings, else `[pilot]`.
    func pilot(for ref: PullRef) -> PullFeedback.Effective {
        PullFeedback.effective(feedback[ref.description], pilotSettings(for: ref))
    }

    func pilotStatus(for ref: PullRef) -> PilotStatus {
        PilotStatus.of(
            pull: github.pull(ref), pipeline: feedback[ref.description], settings: pilotSettings(for: ref),
            hasSession: sessions.contains { $0.trackedPRs.contains(ref) }, detail: pullDetails[ref.description],
            now: Clock.now
        )
    }

    /// Every PR a session tracks, most urgent group first, then most recently updated; narrowed by `/`.
    var pilotRows: [PilotRow] {
        let order = PilotStatus.Group.allCases
        let filter = filter(for: .watch)
        let refs = Set(sessions.flatMap(\.trackedPRs))
        return refs.map { ref in
            PilotRow(
                ref: ref, pull: github.pull(ref), status: pilotStatus(for: ref), effective: pilot(for: ref),
                session: sessions.first { $0.trackedPRs.contains(ref) }
            )
        }
        .filter { row in
            filter.isEmpty || FilterQuery.matches(
                filter, [row.title, row.ref.repo.slug, "#\(row.ref.number)", row.status.group.rawValue]
            )
        }
        .sorted {
            let (left, right) = (order.firstIndex(of: $0.status.group)!, order.firstIndex(of: $1.status.group)!)
            if left != right { return left < right }
            return ($0.pull?.updatedAt ?? .distantPast) > ($1.pull?.updatedAt ?? .distantPast)
        }
    }

    /// The one line that says what the pilot is doing for a PR: the inspector's PR card, the Watch view's detail.
    func pilotLine(for ref: PullRef) -> String {
        let effective = pilot(for: ref)
        let pipeline = feedback[ref.description]
        // Merged or closed, nothing is left to watch: saying "watching" made it look still running.
        switch github.pull(ref)?.state {
        case .merged: return "merged · done"
        case .closed: return "closed · done"
        case .open, nil: break
        }
        guard effective.watching else { return "not watched · \(keyText(for: "pilot.watch")) to watch" }
        var parts = ["watching", "green \(effective.green.configName)"]
        if let pipeline {
            if pipeline.isPaused(Clock.now) {
                parts
                    .append(pipeline
                        .pausedForever ? "paused" :
                        "paused \(PilotDuration.text((pipeline.pausedUntil ?? Clock.now).timeIntervalSince(Clock.now)))")
            }
            let queued = pipeline.count(.queued), new = pipeline.count(.new), sent = pipeline.count(.sent)
            if new > 0 { parts.append("\(new) new") }
            if queued > 0 { parts.append("\(queued) queued") }
            if sent > 0 { parts.append("\(sent) sent") }
            if pipeline
                .rounds >
                0 { parts.append("round \(min(pipeline.rounds, effective.maxRounds)) of \(effective.maxRounds)") }
        }
        if case let .stuck(reason) = pilotStatus(for: ref) { parts.append("stuck: \(reason)") }
        if pendingDelivery.contains(ref),
           let reason = pilotLog.first(where: { $0.ref == ref && $0.kind == .waiting })?.text
        {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    /// What decides a session's Watching or Stalled: its most urgent PR state, whether heed acts on any of its PRs, and
    /// whether you typed in it since heed last did something there.
    func sessionPilot(_ session: Session) -> SessionPilot {
        let refs = session.trackedPRs
        guard !refs.isEmpty else { return SessionPilot() }
        let acting = refs.contains { pilotStatus(for: $0).heedActing(pilot(for: $0)) }
        // The log is newest first.
        let lastAction = pilotLog.first { refs.contains($0.ref) && PilotEvent.actions.contains($0.kind) }?.at
        let helperNeedsYou = refs.compactMap { helpers[$0.description] }.contains { helper in
            helperStates[helper.paneID].map { $0 == .asking || $0 == .blocked } ?? false
        }
        return SessionPilot(
            status: pilotStatus(of: session), acting: acting,
            yours: SessionPilot.yours(lastTyped: lastTyped[session.id], lastAction: lastAction),
            helperNeedsYou: helperNeedsYou
        )
    }

    /// What a session row in Watching or Stalled says instead of the agent's line, from its most urgent acting PR.
    func watchLabel(of session: Session) -> String? {
        let refs = session.trackedPRs
        let order = PilotStatus.Group.allCases
        let candidates = refs.map { (ref: $0, status: pilotStatus(for: $0)) }.filter {
            if case .stalled = $0.status { return true }
            return $0.status.heedActing(pilot(for: $0.ref))
        }
        guard let pick = candidates.min(by: {
            order.firstIndex(of: $0.status.group)! < order.firstIndex(of: $1.status.group)!
        }) else { return nil }
        if let helper = helpers[pick.ref.description] {
            return "\(helper.goal == .green ? "getting it green" : "getting it merged") · in its own tab"
        }
        if pendingDelivery.contains(pick.ref), let typed = lastTyped[session.id],
           Date().timeIntervalSince(typed) < pilotSettings(for: pick.ref).sendAfterIdle
        {
            return "getting it green · waiting for you to step away"
        }
        return WatchLabel.text(
            status: pick.status, effective: pilot(for: pick.ref), agent: session.agent, agentState: session.state.state
        )
    }

    /// The group a session is shown in (the sidebar's, so Watching and Stalled count).
    func sessionGroup(_ session: Session) -> SessionGroup {
        list.group(of: session.id) ?? SessionGroup.of(session, pilot: sessionPilot(session))
    }

    /// The most urgent pilot state among a session's PRs (the Watch view's group order), for its sidebar row.
    func pilotStatus(of session: Session) -> PilotStatus? {
        let order = PilotStatus.Group.allCases
        return session.trackedPRs.map(pilotStatus(for:)).min {
            order.firstIndex(of: $0.group)! < order.firstIndex(of: $1.group)!
        }
    }

    /// The pilot's events for one PR, newest first.
    func pilotTimeline(_ ref: PullRef) -> [PilotEvent] { pilotLog.filter { $0.ref == ref } }

    /// What the pilot commands act on: the PR overlay's or reader's PR; in the Pilot and PRs views the picked rows
    /// (VISUAL) or the one under the cursor; in Sessions the session's PRs.
    private var pilotTargets: [PullRef] {
        if let ref = feedbackPull { return [ref] }
        switch view {
        case .watch:
            let byID = Dictionary(pilotRows.map { ($0.id, $0.ref) }) { first, _ in first }
            return actionIDs(.watch).compactMap { byID[$0] }
        case .prs:
            let byID = Dictionary(pullRows.map { ($0.id, $0.ref) }) { first, _ in first }
            return actionIDs(.prs).compactMap { byID[$0] }
        case .sessions:
            return currentSession?.trackedPRs ?? []
        default:
            return []
        }
    }

    private func editPilot(_ refs: [PullRef], _ edit: (inout PullFeedback) -> Void) {
        let changes = refs.map { ref -> DomainChange in
            var pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
            pipeline.settle(pilotSettings(for: ref))
            edit(&pipeline)
            return .feedbackChanged(pipeline)
        }
        // Rows regroup when their state changes; the cursor stays on the PR it was on.
        let current = view == .watch ? pilotRows.indices.contains(cursor(in: .watch))
            ? pilotRows[cursor(in: .watch)].ref : nil : nil
        commit(changes)
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        clearPicks()
        if let current, let index = pilotRows.firstIndex(where: { $0.ref == current }) { itemCursor[.watch] = index }
    }

    func logPilot(_ ref: PullRef, _ kind: PilotEvent.Kind, _ text: String) {
        // A held delivery is logged once per reason, not on every sync.
        if kind == .waiting, let last = pilotLog.first(where: { $0.ref == ref }), last.kind == .waiting,
           last.text == text
        {
            return
        }
        commit(.pilotLogged([PilotEvent(at: Clock.now, ref: ref, kind: kind, text: text)]))
    }

    /// `w`: watch or stop watching (all of them, when some are and some are not: watch).
    private func togglePilotWatch() {
        let refs = pilotTargets
        guard !refs.isEmpty else { return flash = "no PR here" }
        let watch = !refs.allSatisfy { pilot(for: $0).watching }
        editPilot(refs) { pipeline in
            pipeline.watching = watch
            pipeline.watchSet = true
        }
        for ref in refs {
            logPilot(ref, .watch, watch ? "watching (by you)" : "stopped watching (by you)")
        }
        flash = watch ? "watching \(refs.count) PR\(refs.count == 1 ? "" : "s")"
            : "stopped watching \(refs.count) PR\(refs.count == 1 ? "" : "s")"
        if watch { refs.forEach(fetchDetail) }
    }

    /// `m`: the green mode, cycled from the first target's (off → ask → auto).
    private func cyclePilotGreen() {
        let refs = pilotTargets
        guard let first = refs.first else { return flash = "no PR here" }
        let next = pilot(for: first).green.next
        editPilot(refs) { pipeline in
            pipeline.autoFeed = next
            pipeline.greenSet = true
            // Green needs watching.
            if next != .off, !pipeline.watching {
                pipeline.watching = true
                pipeline.watchSet = true
            }
        }
        for ref in refs {
            logPilot(ref, .green, "green: \(next.configName) (by you)")
            if next == .auto { deliver(ref, explicit: false) }
        }
        flash = "green \(next.configName) on \(refs.count) PR\(refs.count == 1 ? "" : "s")"
    }

    /// `zz` / VISUAL `z` / `:pilot.pause [1h|forever|off]`: silence PRs for a while. Without an argument it toggles:
    /// resume when every target is paused, else pause for `[pilot] pause`.
    /// `zr`: one more round of get it green for a stalled PR (or the picked PRs, or the session's), sent at once when
    /// it is on auto.
    private func retryPilot() {
        let refs = pilotTargets.filter { if case .stalled = pilotStatus(for: $0) { true } else { false } }
        guard !refs.isEmpty else { return flash = "nothing stalled here" }
        for ref in refs {
            let rounds = pilot(for: ref).maxRounds
            editPilot([ref]) { pipeline in pipeline.rounds = max(0, rounds - 1) }
            logPilot(ref, .retry, "another round (by you)")
            if pilot(for: ref).green == .auto { deliver(ref, explicit: false) }
        }
        flash = "another round: \(refs.count) PR\(refs.count == 1 ? "" : "s")"
    }

    private func pausePilot(_ argument: String?) {
        let refs = pilotTargets
        guard !refs.isEmpty else { return flash = "no PR here" }
        let now = Clock.now
        let choice: PilotDuration.Parsed
        if let argument {
            guard let parsed = PilotDuration.parse(argument) else {
                return flash = "pause for how long? 30m, 1h, 4h, 1d, forever or off"
            }
            choice = parsed
        } else if refs.allSatisfy({ feedback[$0.description]?.isPaused(now) == true }) {
            choice = .off
        } else {
            choice = config.pilot.defaults.pause.map(PilotDuration.Parsed.seconds) ?? .forever
        }
        editPilot(refs) { pipeline in
            switch choice {
            case .off:
                pipeline.pausedUntil = nil
                pipeline.pausedForever = false
            case .forever:
                pipeline.pausedUntil = nil
                pipeline.pausedForever = true
            case let .seconds(seconds):
                pipeline.pausedUntil = now.addingTimeInterval(seconds)
                pipeline.pausedForever = false
            }
        }
        let text = switch choice {
        case .off: "resumed (by you)"
        case .forever: "paused until resumed (by you)"
        case let .seconds(seconds): "paused for \(PilotDuration.text(seconds)) (by you)"
        }
        for ref in refs {
            logPilot(ref, .pause, text)
        }
        flash = "\(text.replacingOccurrences(of: " (by you)", with: "")): \(refs.count) PR\(refs.count == 1 ? "" : "s")"
        if case .off = choice {
            for ref in refs where pilot(for: ref).green == .auto {
                deliver(ref, explicit: false)
            }
        }
    }

    /// `pilot.why`: the PR in the Watch view, where its verdict is listed rule by rule.
    private func showPilotWhy() {
        guard let ref = pilotTargets.first else { return flash = "no PR here" }
        reader = nil
        overlay = nil
        view = .watch
        filters[.watch] = nil
        if let index = pilotRows.firstIndex(where: { $0.ref == ref }) { itemCursor[.watch] = index }
        if let blocker = pullDetails[ref.description].flatMap({ GreenVerdict.of($0).blocker }) {
            flash = "#\(ref.number): \(blocker.name.lowercased()): \(blocker.detail)"
        } else if pullDetails[ref.description] != nil {
            flash = "#\(ref.number) is green"
        } else {
            flash = "#\(ref.number): not fetched yet"
        }
    }

    /// Pauses whose time is up end on the next sync, said in the log.
    private func resumeExpiredPauses() {
        let now = Clock.now
        let expired = feedback.values.filter { !$0.pausedForever && ($0.pausedUntil.map { $0 <= now } ?? false) }
        guard !expired.isEmpty else { return }
        commit(expired.map { pipeline in
            var pipeline = pipeline
            pipeline.pausedUntil = nil
            return .feedbackChanged(pipeline)
        })
        commit(.pilotLogged(expired.map { PilotEvent(at: now, ref: $0.ref, kind: .pause, text: "pause ended") }))
    }

    /// After the settings change: PRs nobody set by hand follow them.
    private func settlePilots() {
        let changes = feedback.values.compactMap { pipeline -> DomainChange? in
            var pipeline = pipeline
            return pipeline.settle(pilotSettings(for: pipeline.ref)) ? .feedbackChanged(pipeline) : nil
        }
        commit(changes)
    }

    // MARK: Helper tabs

    /// A PR's helper, while its tab is still there.
    private func liveHelper(_ ref: PullRef) -> HelperTab? {
        guard let helper = helpers[ref.description],
              layouts[helper.sessionID]?.tabs.contains(where: { $0.id == helper.tabID }) == true
        else { return nil }
        return helper
    }

    /// The next round, typed into the PR's helper once it is idle. False while it works.
    private func typeIntoHelper(_ ref: PullRef, prompt: String) -> Bool {
        guard let helper = liveHelper(ref), HelperTabs.canClose(helperStates[helper.paneID]) else { return false }
        TerminalSurfaces.shared.typeLine(prompt, paneID: helper.paneID)
        helperStates[helper.paneID] = .working
        return true
    }

    /// A helper for a PR while you work in its session: a companion checkout of its branch beside the session's
    /// worktree, and a tab ("get it green", "get it merged") running the session's agent there on the prompt. The tab
    /// is appended without being selected: nothing takes your focus. False when the companion could not be made.
    private func spawnCompanionHelper(_ ref: PullRef, prompt: String, sessionID: String) async -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let agent = settings.agent(session.agent),
              let main = worktrees.first(where: { session.owns($0) && $0.repo == ref.repo }),
              let record = repos.first(where: { $0.repo == ref.repo && $0.location == main.location }),
              let branch = github.pull(ref)?.headBranch ?? main.branch
        else {
            logPilot(ref, .waiting, "no worktree of \(ref.repo.name) to put a helper beside")
            return false
        }
        let goal = HelperTabs.goal(for: pilotStatus(for: ref)) ?? .green
        let companion: String
        do {
            companion = try await Git.addCompanion(
                record, path: HelperTabs.companionPath(worktree: main.path, goal: goal), branch: branch,
                companionBranch: HelperTabs.companionBranch(branch, goal: goal)
            )
        } catch {
            logPilot(ref, .waiting, "could not make a companion worktree: \(error)")
            return false
        }
        guard var layout = layouts[session.id] else { return false }
        let files: IntegrationFiles? = if let host = session.host {
            if case let .connected(info) = hostStatus(host), let home = info.home {
                hostIntegration(home: home).integration
            } else {
                nil
            }
        } else {
            integration
        }
        let agentSession = UUID().uuidString.lowercased()
        let command = agent.launchCommand(
            prompt: HelperTabs.companionPrompt(prompt, branch: branch, goal: goal),
            extraArguments: files.map { AgentIntegration.launchArguments(
                agent: agent,
                sessionID: agentSession,
                files: $0
            ) }
                ?? [],
            environment: files.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
        )
        let pane = PaneSpec(
            role: .helper, title: goal.rawValue, directory: companion, command: command, location: session.location
        )
        let tab = PaneTab(
            title: HelperTabs.title(goal, ref: ref, pullCount: session.trackedPRs.count),
            tree: .leaf(pane)
        )
        layout.tabs.append(tab)
        commit(.layoutChanged(session: session.id, layout))
        helpers[ref.description] = HelperTab(
            sessionID: session.id, tabID: tab.id, paneID: pane.id, goal: goal, companion: companion,
            companionBranch: HelperTabs.companionBranch(branch, goal: goal), record: record, mainPath: main.path
        )
        helperStates[pane.id] = .working
        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
        TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
        logPilot(ref, .watch, "\(goal.rawValue): a tab with \(session.agent) in its own worktree")
        return true
    }

    /// Closes helper tabs whose PR is done (green, or merged), once their agent is not mid-turn; forgets ones you
    /// closed yourself.
    func closeFinishedHelpers() {
        for (key, helper) in helpers {
            guard var layout = layouts[helper.sessionID],
                  let index = layout.tabs.firstIndex(where: { $0.id == helper.tabID }),
                  let ref = sessions.first(where: { $0.id == helper.sessionID })?.trackedPRs
                  .first(where: { $0.description == key })
            else {
                helpers[key] = nil
                continue
            }
            guard HelperTabs.done(helper.goal, status: pilotStatus(for: ref)),
                  HelperTabs.canClose(helperStates[helper.paneID])
            else { continue }
            TerminalSurfaces.shared.close(paneID: helper.paneID)
            if let companion = helper.companion, let record = helper.record {
                // The companion goes; the session's worktree catches up with what the helper pushed, when it can.
                Task {
                    await Git.removeWorktree(record, path: companion, branch: helper.companionBranch)
                    if let main = helper.mainPath, await Git.fastForwardIfClean(at: main, on: record.location) {
                        logPilot(
                            ref,
                            .updated,
                            "\(main.split(separator: "/").last ?? ""): brought up to date with the helper's push"
                        )
                    }
                }
            }
            layout.removeTab(at: index)
            commit(.layoutChanged(session: helper.sessionID, layout))
            helpers[key] = nil
            helperStates[helper.paneID] = nil
            logPilot(ref, .helperDone, "\(helper.goal.rawValue) done: closed its tab")
        }
    }

    /// A fixture's helper tabs, as if heed had opened them: working on their session's first PR.
    private func adoptFixtureHelpers() {
        for (sessionID, layout) in layouts {
            guard let ref = sessions.first(where: { $0.id == sessionID })?.trackedPRs.first else { continue }
            for tab in layout.tabs {
                guard let pane = tab.tree.panes.first(where: { $0.role == .helper }) else { continue }
                helpers[ref.description] = HelperTab(
                    sessionID: sessionID, tabID: tab.id, paneID: pane.id,
                    goal: tab.title.hasPrefix(HelperGoal.merged.rawValue) ? .merged : .green
                )
                helperStates[pane.id] = .working
            }
        }
    }

    /// `:pilot.helper`: the PR's helper tab, if it has one.
    private func showHelper() {
        guard let session = currentSession,
              let helper = session.trackedPRs.compactMap({ helpers[$0.description] }).first,
              let index = layouts[session.id]?.tabs.firstIndex(where: { $0.id == helper.tabID })
        else { return flash = "no helper tab here" }
        selectTab(index)
    }

    /// Sends a PR's queued feedback to the session tracking it (or its helper tab), as one prompt, when delivery
    /// allows.
    func deliver(_ ref: PullRef, explicit: Bool) {
        guard var pipeline = feedback[ref.description], let prompt = pipeline.prompt() else {
            if explicit { flash = "nothing queued (space queues an item)" }
            return
        }
        let effective = pilot(for: ref)
        guard explicit || (effective.green == .auto && effective.watching && !pipeline.roundsExhausted
            && !pipeline.isPaused(Clock.now))
        else {
            if pipeline.roundsExhausted, effective.green == .auto {
                flash = "auto-feed stopped on #\(ref.number): \(pipeline.maxRounds) rounds without a new approval"
                logPilot(ref, .stuck, "\(pipeline.maxRounds) rounds without a new approval: stopped sending")
            }
            return
        }
        guard var session = sessions.first(where: { $0.trackedPRs.contains(ref) }), let layout = layouts[session.id],
              let (_, paneID) = agentPane(in: layout)
        else {
            if explicit { flash = "no session tracks #\(ref.number)" }
            return
        }
        // Asked for (zg): the short grace. On its own: not until you have left the session for `send_after_idle`.
        let grace = explicit ? 20 : effective.watching ? pilotSettings(for: ref).sendAfterIdle : 20
        // `send_to = "tab"`: its helper keeps it; while you work in the session, a helper in a companion worktree, at
        // once (it touches nothing of yours); once you have stepped away, the session's own agent, as below.
        if pilotSettings(for: ref).sendTo == .tab {
            let youAreThere = lastTyped[session.id].map { Date().timeIntervalSince($0) < max(grace, 20) } ?? false
            switch HelperTabs.route(hasHelper: liveHelper(ref) != nil, youAreThere: youAreThere) {
            case .existingHelper:
                guard !isFixture else { return flash = "fixture: no IO" }
                guard typeIntoHelper(ref, prompt: prompt) else {
                    pendingDelivery.insert(ref)
                    logPilot(ref, .waiting, "\(pipeline.queued.count) queued, held: its helper tab is working")
                    return
                }
                markSent(ref, pipeline: &pipeline, session: &session, to: "its helper tab")
                return
            case .companionHelper:
                guard !isFixture else { return flash = "fixture: no IO" }
                guard !spawningHelpers.contains(ref.description) else { return }
                spawningHelpers.insert(ref.description)
                Task {
                    defer { spawningHelpers.remove(ref.description) }
                    guard await spawnCompanionHelper(ref, prompt: prompt, sessionID: session.id),
                          var pipeline = feedback[ref.description],
                          var session = sessions.first(where: { $0.id == session.id })
                    else {
                        pendingDelivery.insert(ref)
                        return
                    }
                    markSent(ref, pipeline: &pipeline, session: &session, to: "a helper in its own worktree")
                }
                return
            case .sessionAgent:
                break
            }
        }
        switch Delivery.verdict(state: session.state.state, lastTyped: lastTyped[session.id], typingGrace: grace) {
        case let .wait(reason):
            pendingDelivery.insert(ref)
            if explicit { flash = "waiting: \(reason); it goes once the agent is idle" }
            logPilot(ref, .waiting, "\(pipeline.queued.count) queued, held: \(reason)")
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
            TerminalSurfaces.shared.typeLine(prompt, paneID: paneID)
            markSent(ref, pipeline: &pipeline, session: &session, to: session.agent)
        }
    }

    /// The queued items went out: the pipeline counts a round, the session and the pilot log say where to.
    private func markSent(_ ref: PullRef, pipeline: inout PullFeedback, session: inout Session, to target: String) {
        pendingDelivery.remove(ref)
        let count = pipeline.queued.count
        pipeline.markSent(at: pullDetails[ref.description]?.headSHA)
        session.record("sent \(count) feedback item\(count == 1 ? "" : "s") for #\(ref.number) to \(target)")
        commit([.feedbackChanged(pipeline), .sessionUpserted(session)])
        logPilot(ref, .sent, "sent \(count) item\(count == 1 ? "" : "s") to \(target) (round \(pipeline.rounds))")
        flash = "sent \(count) item\(count == 1 ? "" : "s") to \(target)"
    }

    // MARK: Copilot resolves conflicts

    /// Whether GitHub's Copilot coding agent can work in a repo, by slug, as last asked (`suggestedActors`).
    private(set) var copilotRepos: [String: Bool] = [:]
    private var copilotAskedRepos: [String: Date] = [:]

    func copilotAvailable(_ repo: Repo) -> Bool? { isFixture ? true : copilotRepos[repo.slug] }

    /// Asks GitHub (at most every six hours per repo) whether Copilot can be assigned there.
    private func checkCopilot(_ repo: Repo) async -> Bool {
        if isFixture { return true }
        if let known = copilotRepos[repo.slug], let at = copilotAskedRepos[repo.slug],
           Clock.now.timeIntervalSince(at) < 6 * 3600
        {
            return known
        }
        copilotAskedRepos[repo.slug] = Clock.now
        let available = await (try? GitHub.copilotAvailable(repo)) ?? false
        copilotRepos[repo.slug] = available
        return available
    }

    /// Asks Copilot, in one comment on the PR, to resolve its merge conflicts and address its review comments. On its
    /// own (after a fetch) for what `copilot_conflicts` and `copilot_comments` hand it, when the PR is watched, not
    /// paused and get it green is not off; by hand (`C`) for both, whatever the settings say.
    private func askCopilot(_ refs: [PullRef], byHand: Bool) async {
        var asked = 0
        var problem: String?
        for ref in refs {
            guard let pipeline = feedback[ref.description], let detail = pullDetails[ref.description] else { continue }
            let effective = pilot(for: ref)
            if !byHand {
                guard effective.watching, effective.green != .off, !pipeline.isPaused(Clock.now) else { continue }
            }
            // Cheap checks first: only something to ask about costs a GitHub call.
            let settings = pilotSettings(for: ref)
            guard !CopilotAsk.items(pipeline, settings: settings, everything: byHand).isEmpty else { continue }
            guard await checkCopilot(ref.repo) else {
                problem = "Copilot coding agent is not enabled for \(ref.repo.slug)"
                continue
            }
            var current = feedback[ref.description] ?? pipeline
            let items = CopilotAsk.items(current, settings: settings, everything: byHand)
            guard !items.isEmpty else { continue }
            if !isFixture {
                do {
                    try await GitHub.comment(ref, body: CopilotAsk.comment(base: detail.baseBranch, items: items))
                } catch {
                    problem = "could not ask Copilot on #\(ref.number): \(error)"
                    continue
                }
            }
            current = feedback[ref.description] ?? current
            CopilotAsk.asked(&current, items: items.map(\.id), at: Clock.now)
            commit(.feedbackChanged(current))
            let conflict = items.contains { if case .conflict = $0.kind { true } else { false } }
            let comments = items.count - (conflict ? 1 : 0)
            let what = [
                conflict ? "merge in \(detail.baseBranch) and resolve the conflicts" : nil,
                comments > 0 ? "address \(comments) review comment\(comments == 1 ? "" : "s")" : nil,
            ].compactMap(\.self).joined(separator: " and ")
            logPilot(ref, .copilot, "asked Copilot to \(what)" + (byHand ? " (by you)" : ""))
            asked += 1
        }
        if asked > 0, byHand {
            flash = "asked Copilot on \(asked) PR\(asked == 1 ? "" : "s")"
        } else if let problem, byHand || problem.hasPrefix("could not") {
            flash = problem
        } else if byHand {
            flash = "nothing for Copilot: no merge conflict or new review comment it was not asked about"
        }
    }

    /// Asks the configured reviewers (`[pilot] reviewers`) to review a PR, once each, when it is open and ready. By
    /// hand (`:pilot.reviewers`) whatever watching and pausing say.
    private func requestReviews(_ refs: [PullRef], byHand: Bool) async {
        var asked = 0
        for ref in refs {
            guard let detail = pullDetails[ref.description] else { continue }
            let pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
            if !byHand {
                guard pilot(for: ref).watching, !pipeline.isPaused(Clock.now) else { continue }
            }
            let wanted = ReviewRequests.wanted(
                pilotSettings(for: ref), detail: detail, asked: pipeline.reviewersRequested
            )
            guard !wanted.isEmpty else { continue }
            let who = wanted.joined(separator: ", ")
            var failure: String?
            if !isFixture {
                do {
                    try await GitHub.requestReviews(ref, from: wanted)
                } catch {
                    failure = "\(error)"
                }
            }
            // Asked once either way: a reviewer GitHub refuses is not asked again on every fetch.
            var current = feedback[ref.description] ?? pipeline
            current.reviewersRequested += wanted
            commit(.feedbackChanged(current))
            if let failure {
                logPilot(ref, .review, "could not ask \(who) to review: \(failure)")
            } else {
                logPilot(ref, .review, "asked \(who) to review" + (byHand ? " (by you)" : ""))
                asked += 1
            }
        }
        if byHand {
            flash = asked > 0 ? "asked for reviews on \(asked) PR\(asked == 1 ? "" : "s")"
                : "no one to ask: [pilot] reviewers names who, and each is asked once"
        }
    }

    // MARK: Get it merged

    /// The repo whose merge queue the Watch view shows in its center (`gM`); nil shows the PR under the cursor.
    var mergeQueueShown: String?
    /// Queues running now, so a schedule tick or a second `:merge.run` does not start another.
    private(set) var mergeRunning: Set<String> = []

    /// The tracked PRs with get it merged on, by repo slug: the merge queues.
    var mergeQueues: [String: [PullRef]] {
        Dictionary(grouping: Set(sessions.flatMap(\.trackedPRs)).filter { pilot(for: $0).merge != .off }) {
            $0.repo.slug
        }
    }

    func nextMergeRun(_ repo: String) -> Date? {
        guard let first = mergeQueues[repo]?.first else { return nil }
        return MergeRun.nextRun(
            last: mergeRuns[repo]?.first?.at, every: pilotSettings(for: first).mergeSchedule, now: Clock.now
        )
    }

    /// What the next run would do with a PR, from what heed knows now.
    func mergePlan(_ ref: PullRef) -> MergeQueue.Action? {
        guard pilot(for: ref).merge != .off, let detail = pullDetails[ref.description] else { return nil }
        return MergeQueue.action(for: mergeEntry(ref, detail))
    }

    private func mergeEntry(_ ref: PullRef, _ detail: PullDetail) -> MergeQueue.Entry {
        MergeQueue.Entry(
            ref: ref, detail: detail, settings: pilotSettings(for: ref),
            paused: feedback[ref.description]?.isPaused(Clock.now) == true, mode: pilot(for: ref).merge,
            selfReview: feedback[ref.description]?.selfReview, now: Clock.now
        )
    }

    /// `M`: get it merged, cycled from the first target's (off → auto → heed). On also turns watching on, and runs
    /// the repo's queue; off turns GitHub's auto-merge off again where it is on.
    private func togglePilotMerge() {
        let refs = pilotTargets
        guard let first = refs.first else { return flash = "no PR here" }
        let mode = pilot(for: first).merge.next
        editPilot(refs) { pipeline in
            pipeline.merge = mode
            pipeline.mergeSet = true
            if mode != .off, !pipeline.watching {
                pipeline.watching = true
                pipeline.watchSet = true
            }
        }
        for ref in refs {
            logPilot(ref, .merge, "merge: \(mode.configName) (by you)")
        }
        flash = "merge \(mode.configName) on \(refs.count) PR\(refs.count == 1 ? "" : "s")"
        if mode == .off {
            let enabled = refs.filter { pullDetails[$0.description]?.autoMergeEnabled == true }
            guard !enabled.isEmpty, !isFixture else { return }
            Task {
                for ref in enabled {
                    if await (try? GitHub.disableAutoMerge(ref)) != nil {
                        logPilot(ref, .autoMerge, "auto-merge off (merge turned off)")
                    }
                    fetchDetail(ref)
                }
            }
        } else {
            for repo in Set(refs.map(\.repo.slug)) {
                runMergeQueue(repo, why: "merge turned on")
            }
        }
    }

    /// `:merge.run [repo|all]`, `R` in the Watch view.
    private func runMergeCommand(_ argument: String?) {
        let queues = mergeQueues
        let repos: [String] = switch argument {
        case "all": queues.keys.sorted()
        case let name?:
            queues.keys.filter { $0 == name || $0.hasSuffix("/\(name)") }
        case nil:
            (mergeQueueShown ?? pilotTargets.first?.repo.slug).map { [$0] } ?? []
        }
        guard !repos.isEmpty else {
            return flash = queues.isEmpty ? "no merge queues: \(keyText(for: "pilot.merge")) turns get it merged on for a PR"
                : "no merge queue for \(argument ?? "this PR's repo")"
        }
        for repo in repos {
            runMergeQueue(repo, why: "asked")
        }
        flash = "running \(repos.count == 1 ? repos[0] : "\(repos.count) merge queues")"
    }

    /// `gM` / `:merge.queue [repo]`: the Watch view with a repo's queue in the center; again to go back to the PR.
    private func showMergeQueue(_ argument: String?) {
        let queues = mergeQueues
        let repo = argument.flatMap { name in queues.keys.first { $0 == name || $0.hasSuffix("/\(name)") } }
            ?? pilotTargets.first?.repo.slug ?? queues.keys.sorted().first
        reader = nil
        overlay = nil
        if view == .watch, argument == nil, mergeQueueShown != nil {
            mergeQueueShown = nil
            return
        }
        view = .watch
        guard let repo
        else { return flash = "no merge queues: \(keyText(for: "pilot.merge")) turns get it merged on for a PR" }
        mergeQueueShown = repo
        if queues[repo] == nil { flash = "\(repo) has no PRs with merge on" }
    }

    /// Queues whose time has come, on the sync tick.
    private func runDueMergeQueues() {
        let now = Clock.now
        for repo in mergeQueues.keys where (nextMergeRun(repo).map { $0 <= now } ?? false) {
            runMergeQueue(repo, why: "schedule")
        }
    }

    /// A PR that just turned green runs its queue, unless the queue ran in the last few minutes.
    private func mergeIfTurnedGreen(_ ref: PullRef, _ detail: PullDetail) {
        guard pilot(for: ref).merge != .off, detail.autoMergeEnabled != true, GreenVerdict.of(detail).isGreen,
              mergeRuns[ref.repo.slug]?.first.map({ Clock.now.timeIntervalSince($0.at) > 300 }) ?? true
        else { return }
        runMergeQueue(ref.repo.slug, why: "#\(ref.number) turned green")
    }

    /// One run of a repo's queue: fresh details for its PRs, the plan, the `gh` calls, a run log entry, and the
    /// pilot's log for each PR something happened to.
    func runMergeQueue(_ repo: String, why: String) {
        guard let refs = mergeQueues[repo], !mergeRunning.contains(repo) else { return }
        mergeRunning.insert(repo)
        Task {
            defer { mergeRunning.remove(repo) }
            var details: [PullRef: PullDetail] = [:]
            for ref in refs {
                if !isFixture, let detail = try? await GitHub.pullDetail(ref) {
                    commit(.pullDetailFetched(detail))
                    details[ref] = detail
                } else if let detail = pullDetails[ref.description] {
                    details[ref] = detail
                }
            }
            let steps = MergeQueue.plan(details.map { mergeEntry($0.key, $0.value) })
            var lines: [MergeRun.Line] = []
            var events: [PilotEvent] = []
            func record(_ ref: PullRef, _ kind: PilotEvent.Kind?, _ action: String, _ detail: String, ok: Bool = true) {
                lines.append(MergeRun.Line(ref: ref, action: action, detail: detail, ok: ok))
                if let kind { events.append(PilotEvent(
                    at: Clock.now,
                    ref: ref,
                    kind: kind,
                    text: "\(action): \(detail)"
                )) }
            }
            for step in steps {
                let ref = step.ref
                switch step.action {
                case let .enableAutoMerge(method):
                    do {
                        if !isFixture { try await GitHub.enableAutoMerge(ref, method: method) }
                        record(
                            ref,
                            .autoMerge,
                            "auto-merge on",
                            "\(method); GitHub merges once its requirements are met"
                        )
                    } catch {
                        record(ref, .held, "could not turn auto-merge on", "\(error)", ok: false)
                    }
                case let .disableAutoMerge(reason):
                    do {
                        if !isFixture { try await GitHub.disableAutoMerge(ref) }
                        record(ref, .autoMerge, "auto-merge off", reason)
                    } catch {
                        record(ref, .held, "could not turn auto-merge off", "\(error)", ok: false)
                    }
                case .updateBranch:
                    do {
                        if !isFixture { try await GitHub.updateBranch(ref) }
                        record(
                            ref,
                            .updated,
                            "brought up to date",
                            "merged \(details[ref]?.baseBranch ?? "the base") in"
                        )
                    } catch {
                        record(ref, .held, "could not update the branch", "\(error)", ok: false)
                    }
                case let .merge(method, admin):
                    await heedMerge(ref, method: method, admin: admin, details: details, record: record)
                case .selfReview:
                    guard let detail = details[ref] else { break }
                    let review = await runSelfReview(ref, detail)
                    guard review.approved else {
                        record(ref, .held, "self-review asked for changes", review.summary)
                        break
                    }
                    record(ref, nil, "self-review approved", String(detail.headSHA.prefix(7)))
                    // Approved: the rules hold now, unless something else moved meanwhile.
                    if case let .merge(method, admin) = MergeQueue.action(for: mergeEntry(ref, detail)) {
                        await heedMerge(ref, method: method, admin: admin, details: details, record: record)
                    }
                case let .waiting(text):
                    record(ref, nil, "waiting", text)
                case let .hold(reason):
                    // Held for the same reason as last run: in the run log, not again in the activity.
                    let last = pilotLog.first { $0.ref == ref && $0.kind == .held }
                    record(ref, last?.text == "held: \(reason)" ? nil : .held, "held", reason)
                }
            }
            commit(.mergeRan(MergeRun(repo: repo, at: Clock.now, why: why, lines: lines)))
            if !events.isEmpty { commit(.pilotLogged(events)) }
            // What GitHub did with it shows on the next look.
            for ref in steps.map(\.ref) where !isFixture {
                fetchDetail(ref)
            }
        }
    }

    /// Merges a PR the heed rules hold for, on the head commit they were checked on, and says why on the PR.
    private func heedMerge(
        _ ref: PullRef, method: String, admin: Bool, details: [PullRef: PullDetail],
        record: (PullRef, PilotEvent.Kind?, String, String, Bool) -> Void
    ) async {
        guard let detail = details[ref] else { return }
        let verdict = HeedMerge.verdict(
            detail, settings: pilotSettings(for: ref), selfReview: feedback[ref.description]?.selfReview, now: Clock.now
        )
        if isFixture { return record(ref, .merged, "merged", "\(method) (fixture: nothing merged)", true) }
        var used = method
        do {
            try await GitHub.merge(ref, method: method, head: detail.headSHA)
        } catch {
            guard admin else { return record(ref, .held, "merge refused", "\(error)", false) }
            do {
                try await GitHub.merge(ref, method: method, head: detail.headSHA, admin: true)
                used = "\(method), --admin"
            } catch {
                return record(ref, .held, "merge refused, even with --admin", "\(error)", false)
            }
        }
        record(ref, .merged, "merged", "\(used): every merge rule held", true)
        try? await GitHub.comment(ref, body: HeedMerge.comment(verdict, method: used))
    }

    /// The `self_review` command's verdict on the PR's diff at its head commit, kept on the pipeline.
    private func runSelfReview(_ ref: PullRef, _ detail: PullDetail) async -> SelfReview {
        guard let command = pilotSettings(for: ref).selfReview else {
            return SelfReview(sha: detail.headSHA, approved: false, summary: "no self_review command", at: Clock.now)
        }
        let review: SelfReview
        if isFixture {
            review = SelfReview(sha: detail.headSHA, approved: true, summary: "approved", at: Clock.now)
        } else {
            do {
                let diff = try await GitHub.diff(ref)
                let output = try await SelfReview.run(command, prompt: SelfReview.prompt(detail, diff: diff))
                review = SelfReview.parse(output, sha: detail.headSHA, at: Clock.now)
            } catch {
                review = SelfReview(
                    sha: detail.headSHA, approved: false, summary: "the self-review failed: \(error)", at: Clock.now
                )
            }
        }
        if var pipeline = feedback[ref.description] {
            pipeline.selfReview = review
            commit(.feedbackChanged(pipeline))
        }
        return review
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
        let targets = worktrees.filter { session.owns($0) }
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
        return worktrees.first { session.owns($0) && $0.repo == (file.repo ?? session.repos.first) }?.path
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
        case .inbox, .issues, .prs, .watch: itemCursor[view] = 0
        }
    }

    /// How many rows the current view's filter leaves.
    var filterMatches: Int {
        switch view {
        case .sessions: list.ordered.count
        case .history: historyRows.count
        case .repos: worktreeRows.count
        case .inbox, .issues, .prs, .watch: itemIDs(view).count
        }
    }

    // MARK: Start work

    /// The global shortcut: Start work in a panel over whatever app is in front. Pressing it again brings the panel
    /// back; a dialog already open in the main window moves to the panel.
    func openStandaloneStartWork() {
        guard confirmation == nil, importPicker == nil else { return }
        if startWork == nil {
            // Called from another app: what heed's cursor is on says nothing about this work.
            openStartWork(prompt: "", fromCursor: false)
        }
        startWorkStandalone = true
        StartWorkPanelController.shared.show(model: self)
    }

    /// Clicking away from the panel cancels it, like Spotlight; a start in progress keeps it open.
    func standaloneClickedAway() {
        guard startWorkStandalone, !startingWork else { return }
        startWork = nil
    }

    private func openStartWork(prompt: String, fromCursor: Bool = true) {
        startWorkError = nil
        let context = fromCursor ? startContext : nil
        if view == .history { view = .sessions }
        startWork = StartWorkForm(
            repos: repos, lastWorked: StartWork.lastWorked(sessions: sessions, closed: history), context: context,
            settings: settings, prompt: prompt, integration: integration, hostIntegrations: hostIntegrations()
        )
    }

    /// What the cursor is on, as a hint for Start work's repo: the session, worktree, history entry, or the items
    /// `s` would start from (else the one under the cursor).
    private var startContext: StartContext? {
        func items(_ found: [(repo: Repo, label: String)]) -> StartContext? {
            guard let first = found.first else { return nil }
            var ids: [String] = []
            for item in found where !ids.contains(item.repo.slug) {
                ids.append(item.repo.slug)
            }
            return StartContext(repos: ids, label: found.count == 1 ? first.label : "\(found.count) items")
        }
        switch view {
        case .sessions:
            return currentSession.map { session in
                StartContext(
                    repos: session.repos.map { StartContext.id($0, session.location) }, label: session.worktreeName
                )
            }
        case .repos:
            guard worktreeRows.indices.contains(repoCursor) else { return nil }
            let row = worktreeRows[repoCursor]
            return StartContext(
                repos: [StartContext.id(row.repo, row.location)], label: row.branch ?? row.repo.name
            )
        case .history:
            return selectedHistory.map { entry in
                StartContext(
                    repos: entry.session.repos.map { StartContext.id($0, entry.session.location) },
                    label: entry.session.worktreeName
                )
            }
        case .inbox:
            let ids = Set(actionIDs(.inbox))
            return items(inboxRows.filter { ids.contains($0.id) }.map { item in
                (item.repo, item.number.map { "\(item.repo.name)#\($0)" } ?? item.repo.name)
            })
        case .issues:
            let ids = Set(actionIDs(.issues))
            return items(issueRows.filter { ids.contains($0.id) }.map { ($0.repo, "\($0.repo.name)#\($0.number)") })
        case .prs:
            let ids = Set(actionIDs(.prs))
            return items(pullRows.filter { ids.contains($0.id) }.map {
                ($0.ref.repo, "\($0.ref.repo.name)#\($0.ref.number)")
            })
        case .watch:
            let ids = Set(actionIDs(.watch))
            return items(pilotRows.filter { ids.contains($0.id) }.map {
                ($0.ref.repo, "\($0.ref.repo.name)#\($0.ref.number)")
            })
        }
    }

    /// Hook file paths on each host that answers, so work started there points its agents at them.
    private func hostIntegrations() -> [String: IntegrationFiles] {
        var result: [String: IntegrationFiles] = [:]
        for host in config.hosts.keys {
            if case let .connected(info) = hostStatus(host), let home = info.home {
                result[host] = hostIntegration(home: home).integration
            }
        }
        return result
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
        let host = plan.location.hostName
        var hostFiles: [String: String] = [:]
        if let host {
            guard case let .connected(info) = hostStatus(host), let home = info.home else {
                startWorkError = "@\(host) does not answer: gH shows why"
                return
            }
            hostFiles = hostIntegration(home: home).files
        }
        startingWork = true
        let settings = settings
        let hosts = config.hosts
        Task {
            defer { startingWork = false }
            do {
                if let host {
                    flash = "setting up @\(host)…"
                    try await HostSetup.install(on: host, files: hostFiles)
                }
                let changes = try await StartWork.execute(plan, settings: settings, hosts: hosts)
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                if host != nil { startHostEvents() }
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
        guard let session = currentSession, let closing = currentTab?.focused else { return }
        removePane(closing, in: session.id)
    }

    /// Takes a pane out of a session's layout (and its tab, when it was the tab's last). A session left with no
    /// terminal at all asks what to do with it.
    private func removePane(_ paneID: String, in sessionID: String) {
        guard var layout = layouts[sessionID], layout.removePane(paneID) else { return }
        commit(.layoutChanged(session: sessionID, layout))
        TerminalSurfaces.shared.close(paneID: paneID)
        if layout.tabs.isEmpty { sessionEmptied(sessionID) }
    }

    /// A pane's terminal ended (its shell exited): the pane closes, as in any terminal.
    ///
    /// Only one at a time, though. Exits arrive in a short batch first: when terminals in more than one session end
    /// together, they were lost (heed quitting or being replaced, the terminal runtime failing), not closed, and no
    /// session is touched; they come back on the next launch. And none count while heed quits.
    func paneExited(_ paneID: String) {
        guard !terminating else { return }
        exitedPanes.insert(paneID)
        guard exitedPanes.count == 1 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            let batch = exitedPanes
            exitedPanes = []
            panesEnded(batch)
        }
    }

    /// A batch of ended terminals: closed when they are all one session's, left alone when they span sessions.
    func panesEnded(_ batch: Set<String>) {
        guard !terminating else { return }
        let owners = batch.compactMap { pane in
            layouts.first { $0.value.tabs.contains { $0.tree.panes.contains { $0.id == pane } } }
                .map { (pane: pane, session: $0.key) }
        }
        guard Set(owners.map(\.session)).count <= 1 else {
            NSLog(
                "heed: \(owners.count) terminals in \(Set(owners.map(\.session)).count) sessions ended at once; sessions left as they were"
            )
            flash = "\(owners.count) terminals ended at once; sessions kept, they reopen on the next launch"
            return
        }
        for owner in owners {
            removePane(owner.pane, in: owner.session)
        }
    }

    /// Panes whose terminal ended in the last moment, gathered so a mass exit is seen as one.
    private var exitedPanes: Set<String> = []
    /// Set when heed starts quitting: terminals ending then are the quit, not someone typing exit.
    private(set) var terminating = false
    func beginTerminating() { terminating = true }

    /// `tab.close`, or a tab's ×: every pane in it. A tab with the agent in it asks first.
    func closeTab(_ index: Int? = nil) {
        guard let session = currentSession, var layout = layouts[session.id] else { return }
        let index = index ?? layout.activeTab
        guard layout.tabs.indices.contains(index) else { return }
        let panes = layout.tabs[index].tree.panes
        let close: @MainActor () -> Void = { [weak self] in
            guard let self, var layout = layouts[session.id], layout.tabs.indices.contains(index) else { return }
            layout.removeTab(at: index)
            commit(.layoutChanged(session: session.id, layout))
            for pane in panes {
                TerminalSurfaces.shared.close(paneID: pane.id)
            }
            if layout.tabs.isEmpty { sessionEmptied(session.id) }
        }
        guard panes.contains(where: { $0.role == .agent }) else { return close() }
        layout.activeTab = index
        ask(Confirmation(
            title: "Close the \(layout.tabs[index].title) tab?",
            lines: ["The agent in it stops; the session and its worktree stay"],
            accept: "Close"
        ) { close() })
    }

    /// Every terminal of a session has gone. Delete it and its worktree, close it (worktree kept), or keep it with a
    /// fresh shell.
    private func sessionEmptied(_ id: String) {
        if mode == .insert, currentSession?.id == id { engine.enter(.normal) }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let (removals, kept, lines) = deletion(of: session)
        // ↩ keeps the session: this dialog follows an exit, not a choice, so the safe answer is the default one.
        // Deleting takes its own key.
        ask(Confirmation(
            title: "Every terminal in \(session.title) has closed.",
            lines: ["Keep opens a new shell in it; Close and Delete move it to History"]
                + lines.map { "Delete would \($0.prefix(1).lowercased())\($0.dropFirst())" },
            kept: kept,
            accept: "Keep",
            cancel: "Keep",
            destructive: false,
            action: { [weak self] in self?.reopenShell(in: id) },
            alternatives: [
                .init(label: "Close, keep the worktree", key: "c") { [weak self] in self?.closeSession(id) },
                .init(label: "Delete", key: "d", destructive: true) { [weak self] in
                    self?.deleteSession(id, removals: removals, kept: kept)
                },
            ],
            onCancel: { [weak self] in self?.reopenShell(in: id) }
        ))
    }

    /// Keep: the session gets a shell tab again, in its worktree.
    private func reopenShell(in id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let directory = worktrees.first { session.owns($0) }?.path
            ?? NSHomeDirectory()
        var layout = layouts[id] ?? SessionLayout(tabs: [])
        layout.tabs.append(PaneTab(title: "shell", tree: .leaf(PaneSpec(
            role: .shell, title: "zsh \(session.branch)", directory: directory
        ))))
        layout.activeTab = layout.tabs.count - 1
        commit(.layoutChanged(session: id, layout))
        flash = "kept \(session.title), with a new shell"
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
                repo: record.repo,
                path: StartWork.worktreePath(for: record, name: plan.name, settings: settings, hosts: config.hosts),
                branch: plan.name, head: "0000000", isMain: false, status: WorktreeStatus(upstream: nil),
                location: record.location
            )
        }
        var session = Session(
            id: plan.sessionID, title: plan.title, prompt: plan.prompt, repos: plan.repos.map(\.repo),
            branch: plan.name, agent: plan.agent?.name ?? "shell", state: ObservedState(.working),
            activity: "starting", lastActivity: Date()
        )
        session.host = plan.location.hostName
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
            NotificationCenter.default.post(name: .heedTutorProgress, object: nil)
        }
    }

    /// The saved progress, observed, for the title bar's reminder.
    private(set) var tutorRecord = TutorProgress()
    /// Screenshots show the reminder only where a shot asks for it.
    var tutorReminderInShots = false

    /// The title bar's reminder: not while a lesson runs, not in the tutor's own sandbox, not in screenshots unless
    /// asked.
    var tutorReminder: TutorReminder? {
        guard tutor == nil, tutorPicker == nil, !ShotMode.active || tutorReminderInShots else { return nil }
        return tutorRecord.reminder(view: tutorViewName)
    }

    /// Clicking the reminder starts its lesson (where it was left, for one left halfway).
    func startRemindedLesson() {
        guard let reminder = tutorReminder else { return }
        onTutorRequest?(.start(lesson: reminder.lesson, world: nil))
    }

    /// `tutor.hide [all]`, or the reminder's ×.
    func hideTutorReminder(all: Bool = false) {
        guard all || tutorReminder != nil else { return flash = "no tutor reminder here" }
        var progress = tutorProgress
        progress.hidden.insert(all ? "all" : tutorReminder!.lesson)
        tutorProgress = progress
        tutorRecord = progress
        flash = all ? "tutor reminders hidden; :tutor still opens the tutor"
            : "reminder hidden; :tutor still has the lesson"
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
    var tutorViewName: String {
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
        case .inbox, .issues, .prs, .watch:
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
        state.hostsOpen = hostsPicker != nil
        state.hostSessions = sessions.count { $0.host != nil }
        state.commandLine = mode == .command
        state.sessions = sessions.count
        let pins = list.ordered.filter(\.pinned)
        state.pins = pins.count
        if view == .sessions, let session = currentSession {
            state.pinned = pins.firstIndex { $0.id == session.id }.map { $0 + 1 }
            state.onParked = sessionGroup(session) == .parked
            state.needsYou = [.blocked, .asking].contains(session.state.state)
        }
        state.parked = sessions.count { sessionGroup($0) == .parked }
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
        let tracked = Set(sessions.flatMap(\.trackedPRs))
        state.paused = tracked.count { feedback[$0.description]?.isPaused(Clock.now) == true }
        state.merging = tracked.count { pilot(for: $0).merge != .off }
        state.mergeQueue = view == .watch && mergeQueueShown != nil
        return state
    }

    /// A command's key as text for hints: as bound, else `:command` (what still runs it).
    func keyText(for command: String) -> String { keyLabel(for: command) ?? ":\(command)" }

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

    /// Whether a click on a list may act: not while a dialog or form has the keyboard.
    private var clicksReachLists: Bool {
        startWork == nil && confirmation == nil && resume == nil && firstRun == nil && importPicker == nil
            && pathImport == nil && tutorPicker == nil
    }

    /// A click on a session in the sidebar or the rail selects it; a double-click also types into its agent pane.
    func clickSession(_ id: String, insert: Bool = false) {
        guard clicksReachLists else { return }
        clickedOutsideTerminal()
        select(sessionID: id)
        guard insert, let layout = layouts[id], let (tabIndex, paneID) = agentPane(in: layout) else { return }
        selectTab(tabIndex)
        clickedPane(paneID)
    }

    /// A click on a list row (Inbox, Issues, PRs, Watch, Repos, History) moves the cursor there; a double-click opens
    /// it, as ↩ does.
    func clickRow(_ list: AppView, _ index: Int, open: Bool = false) {
        guard clicksReachLists, view == list else { return }
        clickedOutsideTerminal()
        setRow(index)
        if open { openSelected() }
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

extension String {
    /// Nil for "", so an optional detail stays out.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
