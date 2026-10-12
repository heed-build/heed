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
    // Domain
    private(set) var sessions: [Session] = [] { didSet { list = SessionList(sessions) } }
    private(set) var layouts: [String: SessionLayout] = [:]
    private(set) var repos: [RepoRecord] = []
    private(set) var worktrees: [Worktree] = []
    private(set) var list = SessionList([])
    let settings: WorkSettings
    /// Nil for fixtures: nothing is persisted and no adapter runs.
    private var store: DomainStore?
    let isFixture: Bool
    private var hookServer: HookServer?
    let integration = IntegrationFiles.default()
    /// The latest hook events per session, newest first: shown in the inspector, not persisted (agents own history).
    private(set) var events: [String: [AgentEvent]] = [:]

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
        didSet { engine.scope = view == .sessions ? nil : view.rawValue }
    }

    private(set) var overlay: Overlay?
    private(set) var inspectorVisible = true
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
        startHooks()
        let integration = integration
        Task.detached(priority: .utility) {
            do { try integration.write() } catch { NSLog("heed: could not write hook files: \(error)") }
        }
        let cached = await DomainStore.load(from: file)
        replace(with: cached)
        store = DomainStore(domain: cached, file: file)
        await refreshRepos()
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
        case let .title(title):
            session.title = title
        case let .prAdd(url):
            guard let pull = PullRef(url: url), !session.trackedPRs.contains(pull) else { return }
            session.trackedPRs.append(pull)
        case let .agentSession(id, _):
            session.agentSessionID = id
        case let .notify(text):
            flash = "\(session.title): \(text)"
            return
        }
        commit(.sessionUpserted(session))
    }

    func flush() async { await store?.flush() }

    private func replace(with domain: Domain) {
        sessions = domain.sessions
        layouts = domain.layouts
        repos = domain.repos
        worktrees = domain.worktrees
        cursor = min(cursor, max(list.ordered.count - 1, 0))
    }

    /// The one way the domain changes. Only properties that actually changed are written, so only their readers redraw.
    func commit(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        let before = Domain(repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts)
        let after = before.applying(changes)
        if after.sessions != before.sessions { sessions = after.sessions }
        if after.layouts != before.layouts { layouts = after.layouts }
        if after.repos != before.repos { repos = after.repos }
        if after.worktrees != before.worktrees { worktrees = after.worktrees }
        if let store { Task { await store.apply(changes) } }
    }

    func commit(_ change: DomainChange) { commit([change]) }

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
        if startWork != nil {
            handleStartWork(stroke)
            return true
        }
        let before = engine.mode
        let outcome = engine.handle(stroke)
        switch outcome {
        case .terminal:
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
        if mode == .visual { visualAnchor = view == .repos ? repoCursor : nil }
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
        case "overlay.pr": overlay = overlay == .pr ? nil : .pr
        case "overlay.diff": overlay = overlay == .diff ? nil : .diff
        case "overlay.close": closeTopmost()
        case "inspector.toggle": inspectorVisible.toggle()
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
        case "app.quit": NSApp.terminate(nil)
        default:
            flash = "\(command.name): not built yet"
        }
    }

    /// `<Esc>` in NORMAL: an overlay first, then back from a view to Sessions.
    private func closeTopmost() {
        if overlay != nil {
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
        if view == .repos { setRow(repoCursor + delta) } else { setCursor(cursor + delta) }
    }

    private func setRow(_ index: Int) {
        if view == .repos {
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
        guard let id = currentSession?.id else { return }
        commit(.sessionRemoved(id))
        for pane in layouts[id]?.tabs.flatMap(\.tree.panes) ?? [] {
            TerminalSurfaces.shared.close(paneID: pane.id)
        }
        cursor = min(cursor, max(list.ordered.count - 1, 0))
        flash = "closed; worktree kept"
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

    // MARK: Start work

    private func openStartWork(prompt: String) {
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

enum HintTarget: Hashable {
    case session(String)
    case pane(String)
}
