import AppKit
import SwiftUI

/// The Start work dialog on its own, over whatever app is in front (`[keys] global_start_work`). A floating,
/// non-activating panel: it takes the keyboard without bringing Heed forward, and closing it leaves you where you
/// were. Its title and identifier are fixed so window managers can match it:
///
///     yabai -m rule --add app="^Heed$" title="^Heed Start Work$" manage=off
///
/// and in OmniWM a floating rule for app "Heed" with title "Heed Start Work".
@MainActor
final class StartWorkPanelController: NSObject, NSWindowDelegate {
    static let shared = StartWorkPanelController()
    static let identifier = NSUserInterfaceItemIdentifier("heed.startwork")
    static let title = "Heed Start Work"

    private var panel: StartWorkPanel?
    private var shownAt = Date.distantPast
    private var reclaims = 0
    private var clickMonitors: [Any] = []

    func show(model: AppModel) {
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        shownAt = Date()
        reclaims = 0
        // Key without activating Heed: the app you were in stays the active app underneath.
        panel.makeKeyAndOrderFront(nil)
        watchClicks(model: model)
    }

    func close() {
        panel?.orderOut(nil)
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors = []
    }

    /// A click outside the panel, in any app or in Heed's own window, cancels it (like Spotlight). Losing key status
    /// alone does not: a tiling window manager may focus something else the moment the panel appears.
    private func watchClicks(model: AppModel) {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak model] _ in
            MainActor.assumeIsolated { model?.standaloneClickedAway() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self, weak model] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { model?.standaloneClickedAway() }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    var isKey: Bool { panel?.isKeyWindow == true }

    private func makePanel(model: AppModel) -> StartWorkPanel {
        let panel = StartWorkPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = Self.title
        panel.identifier = Self.identifier
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the dialog draws its own
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: StartWorkView(standalone: true).environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    /// Centred on the screen with the pointer, a little above the middle (where Spotlight sits).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.18 - size.height))
    }

    /// Focus taken away right after opening (a window manager reacting to the new window) is taken back, a few times.
    func windowDidResignKey(_: Notification) {
        guard let panel, panel.isVisible, Date().timeIntervalSince(shownAt) < 1.5, reclaims < 3 else { return }
        reclaims += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    /// Keeps the panel's top edge where it was while the dialog grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, let screen = panel.screen else { return }
        let top = min(panel.frame.maxY, screen.visibleFrame.maxY)
        if panel.frame.minY < screen.visibleFrame.minY || panel.frame.maxY > screen.visibleFrame.maxY {
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
    }
}

/// A borderless panel still has to accept key status to take typing.
final class StartWorkPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
