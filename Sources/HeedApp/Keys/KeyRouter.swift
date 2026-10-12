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
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let stroke = KeyStroke(event: event) else { return event }
            let used = MainActor.assumeIsolated { self?.route(stroke) ?? false }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the app used the key; false sends it on to the focused view (the terminal, a text field).
    private func route(_ stroke: KeyStroke) -> Bool {
        guard let model else { return false }
        if model.textInputActive, stroke != .escape { return false }
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
