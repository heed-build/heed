import AppKit
import HeedCore
import SwiftUI
#if HEED_GHOSTTY
    import HeedTerminal
#endif

/// A terminal pane. With GhosttyKit built (`mise run ghostty`) this hosts a libghostty surface; without it, a
/// placeholder that shows the pane's command and echoes INSERT keys, so key routing can be exercised either way.
struct TerminalPane: NSViewRepresentable {
    let pane: PaneSpec
    let sessionID: String
    /// True when this pane should own the keyboard (focused pane, INSERT).
    let isFocused: Bool
    let focusRequest: Int

    func makeNSView(context _: Context) -> NSView {
        TerminalSurfaces.shared.view(for: pane, sessionID: sessionID)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        guard isFocused else { return }
        if let window = view.window {
            if window.firstResponder !== view { window.makeFirstResponder(view) }
        } else {
            // A pane Start work just made is not in the window yet; focus it once it is.
            DispatchQueue.main.async {
                if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
            }
        }
    }
}

/// Owns every pane's terminal view, keyed by pane id, so a pane keeps its process and scrollback when SwiftUI
/// rebuilds the layout (splits, zoom, switching sessions).
@MainActor
final class TerminalSurfaces {
    static let shared = TerminalSurfaces()
    private var views: [String: NSView] = [:]
    /// Panes whose command should be typed when their terminal is created: only those Start work just made. A pane
    /// restored from the cache opens a plain shell, so a relaunch never starts a second agent (resume is step 5).
    var autostartPanes: Set<String> = []
    /// A left click in a pane's terminal (the model focuses it and enters INSERT).
    var onPaneClick: ((String) -> Void)?
    /// A pane's terminal ended: its shell exited (`exit`, ⌃D) or its command finished.
    var onPaneExited: ((String) -> Void)?
    private var exitsWired = false
    /// `[sessions] persist`: with zmx, a pane's terminal attaches to its zmx session instead of starting a shell.
    var persist: PanePersistence = .none
    /// Panes whose zmx session is alive: they reattach as they are, and nothing is typed into them.
    var livePanes: Set<String> = []
    /// Where each pane's terminal runs, for ending the right session when it closes.
    private var paneLocations: [String: Location] = [:]
    /// Where heed keeps its zmx sessions.
    let zmxDirectory = Zmx.socketDirectory()

    /// zmx on this Mac, as tool detection found it on your PATH (heed ships no copy); nil when not installed.
    var zmxPath: String?
    private var zmx: String? { persist == .zmx ? zmxPath : nil }

    /// zmx on each host, as the host checks last found it (remembered, so panes reattach before the next check).
    var hostZmx: [String: String] = UserDefaults.standard
        .dictionary(forKey: "heed.hostZmx") as? [String: String] ?? [:]
    {
        didSet { UserDefaults.standard.set(hostZmx, forKey: "heed.hostZmx") }
    }

    /// PATH for new panes: the detected search path (an app opened from Finder has a minimal one).
    var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func view(for pane: PaneSpec, sessionID: String) -> NSView {
        if let existing = views[pane.id] {
            existing.removeFromSuperview()
            return existing
        }
        let environment = [
            HeedEnvironment.sessionID: sessionID,
            HeedEnvironment.socket: HeedEnvironment.defaultSocketPath(),
            HeedEnvironment.pane: pane.id,
        ]
        var launch = pane
        if autostartPanes.remove(pane.id) == nil { launch.command = nil }
        var withPath = environment
        withPath["PATH"] = searchPath
        var attach: String?
        paneLocations[pane.id] = pane.location
        if let host = pane.location.hostName {
            // On a host: ssh there and attach to the pane's zmx session in its worktree (always zmx: a remote agent
            // must
            // outlive the link). A live session is reattached as it is, with nothing typed again.
            attach = RemotePane.command(
                host: host, pane: pane.id, directory: pane.directory, sessionID: sessionID, zmx: hostZmx[host]
            )
        }
        // Only a pane in a real worktree: fixture and tutor panes, and ones whose worktree is gone, stay plain shells.
        else if let zmx, FileManager.default.fileExists(atPath: pane.directory) {
            withPath.merge(Zmx.environment(socketDirectory: zmxDirectory)) { _, new in new }
            attach = Zmx.attachCommand(zmx: zmx, pane: pane.id)
            // A live session is reattached as it is: whatever runs in it keeps running, and nothing is typed again.
            if livePanes.contains(pane.id) { launch.command = nil }
            livePanes.insert(pane.id)
        }
        let view = makeTerminalView(pane: launch, environment: withPath, command: attach)
        #if HEED_GHOSTTY
            let paneID = pane.id
            (view as? GhosttySurfaceView)?.onClick = { [weak self] in self?.onPaneClick?(paneID) }
        #endif
        views[pane.id] = view
        wireExits()
        return view
    }

    /// libghostty asks to close a surface when its process ends; that is the pane's terminal ending.
    private func wireExits() {
        guard !exitsWired else { return }
        exitsWired = true
        #if HEED_GHOSTTY
            GhosttyRuntime.shared.onSurfaceClosed = { [weak self] view, _ in
                guard let self, let id = views.first(where: { $0.value === view })?.key else { return }
                views.removeValue(forKey: id)?.removeFromSuperview()
                onPaneExited?(id)
            }
        #endif
    }

    /// Starts a pane's command now (a resumed agent), whether or not its terminal exists yet. A new terminal gets it
    /// as its first input. One that is already open, typically the session on screen at launch (drawn with a plain
    /// shell before resume decided what to start), gets it typed into that shell. Before this, that pane was left
    /// alone and its agent never started.
    func prepare(_ pane: PaneSpec, sessionID: String) {
        guard let existing = views[pane.id] else {
            _ = view(for: pane, sessionID: sessionID)
            return
        }
        // As for a new terminal: only into the worktree it belongs to, never a shell that fell back to home.
        guard autostartPanes.remove(pane.id) != nil, let command = pane.command,
              FileManager.default.fileExists(atPath: pane.directory)
        else { return }
        #if HEED_GHOSTTY
            (existing as? GhosttySurfaceView)?.typeLine(ShellLine.typed(command))
        #else
            _ = existing
        #endif
    }

    /// Types a line into a pane's terminal (the continue prompt). No-op for placeholder panes.
    func typeLine(_ text: String, paneID: String) {
        #if HEED_GHOSTTY
            (views[paneID] as? GhosttySurfaceView)?.typeLine(text)
        #endif
    }

    /// The visible screen of a pane's terminal, if it has one (for guessing agent states).
    func visibleText(paneID: String) -> String? {
        #if HEED_GHOSTTY
            (views[paneID] as? GhosttySurfaceView)?.visibleText()
        #else
            nil
        #endif
    }

    /// Types text into a pane without pressing Return.
    func typeText(_ text: String, paneID: String) {
        #if HEED_GHOSTTY
            (views[paneID] as? GhosttySurfaceView)?.typeText(text)
        #endif
    }

    func isTerminalView(_ view: NSView) -> Bool {
        views.values.contains { $0 === view }
    }

    /// A pane closed for good (closed, its session closed or deleted, its worktree swept): its terminal goes, and with
    /// zmx its session too, so nothing is left running.
    func close(paneID: String) {
        views.removeValue(forKey: paneID)?.removeFromSuperview()
        if let host = paneLocations.removeValue(forKey: paneID)?.hostName {
            if let zmx = hostZmx[host] { Task.detached { await RemotePane.kill(panes: [paneID], host: host, zmx: zmx) }
            }
            return
        }
        guard let zmx, livePanes.remove(paneID) != nil else { return }
        let directory = zmxDirectory
        Task.detached { await Zmx.kill(panes: [paneID], zmx: zmx, socketDirectory: directory) }
    }

    /// Reads which panes still have a live zmx session here (at launch, before any pane is drawn).
    func refreshLivePanes() async {
        guard let zmx else { return livePanes = [] }
        livePanes = await Zmx.livePanes(zmx: zmx, socketDirectory: zmxDirectory)
    }

    /// `agents.stop`: ends every pane's zmx session, and everything running in them.
    func stopAll() async -> Int {
        guard let zmx else { return 0 }
        let live = await Zmx.livePanes(zmx: zmx, socketDirectory: zmxDirectory)
        await Zmx.kill(panes: Array(live), zmx: zmx, socketDirectory: zmxDirectory)
        livePanes.subtract(live)
        return live.count
    }

    private func makeTerminalView(pane: PaneSpec, environment: [String: String], command: String?) -> NSView {
        #if HEED_GHOSTTY
            GhosttyTerminalFactory.makeView(pane: pane, environment: environment, command: command)
        #else
            PlaceholderTerminalView(pane: pane)
        #endif
    }
}

/// Stand-in until GhosttyKit is built. Accepts first responder and echoes what INSERT sends it.
final class PlaceholderTerminalView: NSView {
    private let pane: PaneSpec
    private var typed = ""

    init(pane: PaneSpec) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.047, green: 0.051, blue: 0.059, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 {
            if !typed.isEmpty { typed.removeLast() }
        } else if event.keyCode == 36 {
            typed += "\n"
        } else if let characters = event.characters {
            typed += characters
        }
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let font = NSFont(name: "JetBrains Mono", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let dim: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(red: 0.48, green: 0.51, blue: 0.54, alpha: 1),
        ]
        let text: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(red: 0.81, green: 0.83, blue: 0.85, alpha: 1),
        ]
        let lines = [
            ("libghostty not built yet: mise run ghostty", dim),
            ("cwd \(pane.directory)", dim),
            (pane.command.map { "$ \($0)" } ?? "$", text),
            (typed + "▌", text),
        ]
        var y = bounds.height - 26
        for (line, attributes) in lines {
            for part in line.split(separator: "\n", omittingEmptySubsequences: false) {
                NSAttributedString(string: String(part), attributes: attributes).draw(at: NSPoint(x: 14, y: y))
                y -= 20
            }
        }
    }

    override var isFlipped: Bool { false }
}
