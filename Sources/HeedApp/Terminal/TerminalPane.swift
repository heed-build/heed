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

    func updateNSView(_ host: NSView, context _: Context) {
        guard isFocused else { return }
        let view = (host as? PaneHost)?.terminal ?? host
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

/// Holds a pane's terminal for SwiftUI, so the terminal inside can be replaced (a resumed agent started as the pane's
/// process in place of the plain shell drawn at launch) without SwiftUI knowing.
final class PaneHost: NSView {
    private(set) var terminal: NSView?

    func show(_ view: NSView) {
        let hadFocus = terminal != nil && window?.firstResponder === terminal
        terminal?.removeFromSuperview()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        terminal = view
        if hadFocus { window?.makeFirstResponder(view) }
    }
}

/// Owns every pane's terminal view, keyed by pane id, so a pane keeps its process and scrollback when SwiftUI
/// rebuilds the layout (splits, zoom, switching sessions).
@MainActor
final class TerminalSurfaces {
    static let shared = TerminalSurfaces()
    /// Each pane's terminal.
    private var views: [String: NSView] = [:]
    /// What SwiftUI holds for each pane: the terminal's host.
    private var hosts: [String: PaneHost] = [:]
    /// Panes whose command should start when their terminal is created: only those Start work just made. A pane
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

    /// Each host's login shell, as the host checks last found it: a remote pane's command is written in its syntax.
    var hostShells: [String: String] = UserDefaults.standard
        .dictionary(forKey: "heed.hostShells") as? [String: String] ?? [:]
    {
        didSet { UserDefaults.standard.set(hostShells, forKey: "heed.hostShells") }
    }

    /// PATH for new panes: the detected search path (an app opened from Finder has a minimal one).
    var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func view(for pane: PaneSpec, sessionID: String) -> NSView {
        if let host = hosts[pane.id] {
            host.removeFromSuperview()
            return host
        }
        let host = PaneHost()
        hosts[pane.id] = host
        host.show(makeTerminal(for: pane, sessionID: sessionID))
        wireExits()
        return host
    }

    /// A pane's terminal. A new pane with a command runs it as the terminal's process (`PaneLaunch`): your login
    /// shell runs the line, then becomes the pane's shell. Nothing is typed into a shell that is still starting.
    private func makeTerminal(for pane: PaneSpec, sessionID: String) -> NSView {
        let environment = [
            HeedEnvironment.sessionID: sessionID,
            HeedEnvironment.socket: HeedEnvironment.defaultSocketPath(),
            HeedEnvironment.pane: pane.id,
        ]
        var command = autostartPanes.remove(pane.id) == nil ? nil : pane.command
        var withPath = environment
        withPath["PATH"] = searchPath
        // A zmx session starts `$SHELL`: your login shell, not the one heed was started in.
        let login = PaneShell.loginShellPath() ?? "/bin/zsh"
        if pane.location.isLocal { withPath["SHELL"] = login }
        let exists = FileManager.default.fileExists(atPath: pane.directory)
        // Only a pane in a real worktree starts its command: fixture and tutor panes, and ones whose worktree is gone,
        // open a plain shell instead of starting an agent somewhere unexpected. On a host the worktree is there.
        if pane.location.isLocal, !exists { command = nil }
        var process: String?
        paneLocations[pane.id] = pane.location
        if let host = pane.location.hostName {
            // On a host: ssh there and attach to the pane's zmx session in its worktree (always zmx: a remote agent
            // must outlive the link). A live session is reattached as it is, with nothing started again.
            process = RemotePane.command(
                host: host, pane: pane.id, directory: pane.directory, sessionID: sessionID, zmx: hostZmx[host],
                command: command, shell: PaneShell(name: hostShells[host])
            )
        } else {
            let launch = command.map { PaneLaunch(command: $0, shellPath: login) }
            withPath.merge(launch?.environment ?? [:]) { _, new in new }
            if let zmx, exists {
                withPath.merge(Zmx.environment(socketDirectory: zmxDirectory)) { _, new in new }
                // A live session is reattached as it is: whatever runs in it keeps running, and nothing starts again.
                process = Zmx.attachCommand(zmx: zmx, pane: pane.id, launch: livePanes.contains(pane.id) ? nil : launch)
                livePanes.insert(pane.id)
            } else {
                // Ghostty runs a command through `bash -c 'exec -l …'`: sh words.
                process = launch?.commandLine(quotedFor: .posix)
            }
        }
        let view = makeTerminalView(pane: pane, environment: withPath, command: process, starts: command != nil)
        #if HEED_GHOSTTY
            let paneID = pane.id
            (view as? GhosttySurfaceView)?.onClick = { [weak self] in self?.onPaneClick?(paneID) }
        #endif
        views[pane.id] = view
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
                hosts.removeValue(forKey: id)?.removeFromSuperview()
                onPaneExited?(id)
            }
        #endif
    }

    /// Starts a pane's command now (a resumed agent), whether or not its terminal exists yet. A new terminal runs it
    /// as its process. One that is already open, typically the session on screen at launch (drawn with a plain shell
    /// before resume decided what to start), is replaced by a terminal that runs it: that shell, and its zmx session,
    /// end first, or the new terminal would only reattach to them. Nothing is typed into the shell.
    func prepare(_ pane: PaneSpec, sessionID: String) {
        guard let host = hosts[pane.id], views[pane.id] != nil else {
            _ = view(for: pane, sessionID: sessionID)
            return
        }
        guard autostartPanes.contains(pane.id), pane.command != nil else { return }
        // Out of `views` first: the old terminal ending is not the pane ending.
        views.removeValue(forKey: pane.id)
        let end = endSession(paneID: pane.id, location: pane.location)
        Task { @MainActor in
            await end()
            // Closed meanwhile: nothing to start.
            guard hosts[pane.id] === host else { return }
            host.show(makeTerminal(for: pane, sessionID: sessionID))
        }
    }

    /// Ends a pane's zmx session, here or on its host, if it has one; the returned work does it.
    private func endSession(paneID: String, location: Location) -> @Sendable () async -> Void {
        if let host = location.hostName {
            guard let zmx = hostZmx[host] else { return {} }
            return { await RemotePane.kill(panes: [paneID], host: host, zmx: zmx) }
        }
        guard let zmx, livePanes.remove(paneID) != nil else { return {} }
        let directory = zmxDirectory
        return { await Zmx.kill(panes: [paneID], zmx: zmx, socketDirectory: directory) }
    }

    /// Types a line into a pane's running program (the continue prompt to an agent), never to start one. No-op for
    /// placeholder panes.
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
        hosts.removeValue(forKey: paneID)?.removeFromSuperview()
        guard let location = paneLocations.removeValue(forKey: paneID) else { return }
        let end = endSession(paneID: paneID, location: location)
        Task.detached { await end() }
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

    private func makeTerminalView(
        pane: PaneSpec, environment: [String: String], command: String?, starts: Bool
    ) -> NSView {
        #if HEED_GHOSTTY
            GhosttyTerminalFactory.makeView(pane: pane, environment: environment, command: command)
        #else
            PlaceholderTerminalView(pane: pane, starts: starts)
        #endif
    }
}

/// Stand-in until GhosttyKit is built. Accepts first responder and echoes what INSERT sends it.
final class PlaceholderTerminalView: NSView {
    private let pane: PaneSpec
    /// Whether the pane's command started, rather than a plain shell.
    private let starts: Bool
    private var typed = ""

    init(pane: PaneSpec, starts: Bool) {
        self.pane = pane
        self.starts = starts
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
            (starts ? pane.command.map { "$ \($0)" } ?? "$" : "$", text),
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
