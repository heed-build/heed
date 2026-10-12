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

/// Everything the window draws, on the main actor. Nothing here waits on a process, the network or the disk: work
/// like that runs elsewhere and lands here as finished values.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = NSUserInterfaceItemIdentifier("heed.main")

    // Sessions
    private(set) var sessions: [Session]
    private(set) var cursor = 0
    private var previousSessionID: String?
    private(set) var tabs: [String: [PaneTab]] = [:]
    private(set) var activeTab: [String: Int] = [:]

    // Keys and modes
    private(set) var engine: ModeEngine
    private(set) var keyProblems: [Keymaps.Problem]
    var mode: Mode { engine.mode }
    var pendingKeys: String { engine.pendingDisplay }

    // Chrome
    private(set) var view: AppView = .sessions
    private(set) var overlay: Overlay?
    private(set) var inspectorVisible = true
    private(set) var commandText = ""
    private(set) var flash: String?
    private(set) var hintText = ""
    private var hintThenInsert = false
    /// Bumped when the focused terminal should take keyboard focus (entering INSERT, moving panes).
    private(set) var terminalFocusRequest = 0
    /// A text field owns the keyboard; the key router lets keys through to it.
    var textInputActive = false

    init(sessions: [Session] = SampleData.sessions) {
        self.sessions = sessions
        let built = Keymaps.build()
        engine = ModeEngine(keymaps: built.keymaps)
        keyProblems = built.problems
        for session in sessions {
            tabs[session.id] = SampleData.tabs(for: session)
            activeTab[session.id] = 0
        }
    }

    // MARK: Derived

    var list: SessionList { SessionList(sessions) }

    var currentSession: Session? {
        let ordered = list.ordered
        return ordered.indices.contains(cursor) ? ordered[cursor] : nil
    }

    var currentTabs: [PaneTab] { currentSession.flatMap { tabs[$0.id] } ?? [] }

    var currentTabIndex: Int { currentSession.flatMap { activeTab[$0.id] } ?? 0 }

    var currentTab: PaneTab? {
        let all = currentTabs
        return all.indices.contains(currentTabIndex) ? all[currentTabIndex] : nil
    }

    var blockedCount: Int { sessions.count { $0.state.state == .blocked } }
    var askingCount: Int { sessions.count { $0.state.state == .asking } }

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
        case "session.next": moveCursor(by: count)
        case "session.prev": moveCursor(by: -count)
        case "session.first": setCursor(command.count.map { $0 - 1 } ?? 0)
        case "session.last": setCursor(command.count.map { $0 - 1 } ?? list.ordered.count - 1)
        case "session.attention":
            if let next = list.nextNeedingYou(after: cursor) { setCursor(next) } else { flash = "nobody needs you" }
        case "session.pin": togglePin()
        case "session.park": updateCurrent { $0.parked.toggle() }
        case "session.close": closeCurrent()
        case "session.back": goBack()
        case "pin.jump": jumpToPin(Int(command.arguments.first ?? "") ?? 1)
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
        case "overlay.close": overlay = nil
        case "inspector.toggle": inspectorVisible.toggle()
        case "mode.normal", "mode.insert", "mode.visual", "mode.command", "mode.hint":
            if command.name == "mode.insert", currentTab == nil { engine.enter(.normal) }
            hintThenInsert = false
        case "hint.insert":
            engine.enter(.hint)
            hintThenInsert = true
        case "command.submit": submitCommandLine()
        case "command.complete": completeCommandLine()
        case "app.quit": NSApp.terminate(nil)
        default:
            flash = "\(command.name): not built yet"
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

    // MARK: Sessions

    private func moveCursor(by delta: Int) { setCursor(cursor + delta) }

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
        guard let id = currentSession?.id, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        edit(&sessions[index])
        if let newIndex = list.ordered.firstIndex(where: { $0.id == id }) { cursor = newIndex }
    }

    private func closeCurrent() {
        guard let id = currentSession?.id else { return }
        sessions.removeAll { $0.id == id }
        tabs[id] = nil
        activeTab[id] = nil
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

    // MARK: Panes and tabs

    private func updateTab(_ edit: (inout PaneTab) -> Void) {
        guard let id = currentSession?.id, var all = tabs[id], all.indices.contains(currentTabIndex) else { return }
        edit(&all[currentTabIndex])
        tabs[id] = all
    }

    private func split(_ axis: PaneTree.Axis) {
        guard let session = currentSession else { return }
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        updateTab { $0.split(axis, with: PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: directory)) }
    }

    private func closePane() {
        guard let id = currentSession?.id, var all = tabs[id], all.indices.contains(currentTabIndex) else { return }
        if !all[currentTabIndex].closeFocused() {
            all.remove(at: currentTabIndex)
            activeTab[id] = max(0, min(currentTabIndex, all.count - 1))
        }
        tabs[id] = all
        if all.isEmpty, mode == .insert { engine.enter(.normal) }
    }

    private func cycleTab(by delta: Int) {
        guard let id = currentSession?.id, let count = tabs[id]?.count, count > 0 else { return }
        activeTab[id] = ((currentTabIndex + delta) % count + count) % count
    }

    private func newTab() {
        guard let session = currentSession else { return }
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        let tab = PaneTab(title: "shell", tree: .leaf(PaneSpec(role: .shell, title: "zsh", directory: directory)))
        tabs[session.id, default: []].append(tab)
        activeTab[session.id] = (tabs[session.id]?.count ?? 1) - 1
    }

    func selectTab(_ index: Int) {
        guard let id = currentSession?.id else { return }
        activeTab[id] = index
    }

    func focusPane(_ paneID: String) {
        updateTab { $0.focused = paneID }
    }
}

enum HintTarget: Hashable {
    case session(String)
    case pane(String)
}
