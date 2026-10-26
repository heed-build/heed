import AppKit
import HeedCore

/// The one place keys enter the app. A local event monitor sees every key down before any view does, turns it into a
/// `KeyStroke` and asks the mode engine what it means:
///
/// - `.terminal`: the event is returned untouched, so it reaches the focused terminal view (INSERT).
/// - anything else: the event is swallowed and the model acts on it. Outside INSERT a terminal never sees a key.
///
/// Text fields that own the keyboard (the Start work prompt, the filter) set `model.textInputActive`; the router
/// then lets keys through, except Escape, which always returns to the app.
@MainActor
final class KeyRouter {
    private var monitor: Any?
    private var mouseMonitor: Any?
    private let host: ModelHost
    private var model: AppModel? { host.current }

    init(host: ModelHost) {
        self.host = host
    }

    func start() {
        guard monitor == nil else { return }
        // Clicks: one in a terminal enters INSERT there (the terminal view reports it); one anywhere else in the main
        // window leaves INSERT, so keys never keep going to a terminal you clicked away from.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let window = event.window, window.identifier == AppModel.mainWindowID,
                  let frame = window.contentView?.superview
            else { return event }
            let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
            if !Self.isTerminal(hit) {
                MainActor.assumeIsolated { self?.model?.clickedOutsideTerminal() }
            }
            return event
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the main window is Heed's keyboard; Settings and other windows get their keys untouched.
            // ⌘Q ⌘W ⌘H ⌘M and ⌘N (Start work) are the menu bar's, whatever has focus: a focused terminal would
            // otherwise take them.
            if event.window?.identifier == AppModel.mainWindowID, Self.isMenuShortcut(event),
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            {
                return nil
            }
            // The main window, and the standalone Start work panel.
            guard event.window?.identifier == AppModel.mainWindowID
                || event.window?.identifier == StartWorkPanelController.identifier,
                let stroke = KeyStroke(event: event)
            else { return event }
            let used = MainActor.assumeIsolated { self?.route(stroke) ?? false }
            return used ? nil : event
        }
    }

    /// The standard window and app shortcuts every Mac app answers, ⌘N among them, and nothing else (⌘C, ⌘V stay the
    /// terminal's).
    private static func isMenuShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["q", "w", "h", "m", "n"].contains(key)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        monitor = nil
        mouseMonitor = nil
    }

    private static func isTerminal(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if TerminalSurfaces.shared.isTerminalView(candidate) { return true }
            current = candidate.superview
        }
        return false
    }

    /// True when the app used the key; false sends it on to the focused view (the terminal, a text field).
    private func route(_ stroke: KeyStroke) -> Bool {
        guard let model else { return false }
        // ⌘↩ and ⌘S are the dialog's or the editor's: create, save.
        if model.textInputActive, stroke != .escape, stroke != KeyStroke("CR", .command),
           stroke != KeyStroke("s", .command)
        {
            return false
        }
        return model.handle(stroke)
    }
}

extension KeyStroke {
    /// Maps an AppKit key event to vim notation. Characters come out shifted (`G`, `?`); control and command combos
    /// use the unmodified character (`<C-w>`, `<D-1>`).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        if let named = KeyStroke.namedKeyCodes[event.keyCode] {
            self.init(named, modifiers)
            return
        }
        let useUnmodified = modifiers.contains(.control) || modifiers.contains(.command) || modifiers.contains(.option)
        guard let characters = useUnmodified ? event.charactersIgnoringModifiers : event.characters,
              characters.count == 1
        else { return nil }
        self.init(characters, modifiers)
    }

    static let namedKeyCodes: [UInt16: String] = [
        53: "Esc", 36: "CR", 76: "CR", 48: "Tab", 49: "Space", 51: "BS", 117: "Del",
        126: "Up", 125: "Down", 123: "Left", 124: "Right", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]
}
