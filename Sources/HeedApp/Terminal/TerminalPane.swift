import AppKit
import HeedCore
import SwiftUI

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
        guard isFocused, let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
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
        let view = makeTerminalView(pane: launch, environment: environment)
        views[pane.id] = view
        return view
    }

    func close(paneID: String) {
        views.removeValue(forKey: paneID)?.removeFromSuperview()
    }

    private func makeTerminalView(pane: PaneSpec, environment: [String: String]) -> NSView {
        #if HEED_GHOSTTY
            GhosttyTerminalFactory.makeView(pane: pane, environment: environment)
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
