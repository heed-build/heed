import AppKit
import Carbon.HIToolbox
import HeedCore

/// A system-wide shortcut, registered with Carbon's hotkey API: it works whichever app is in front and needs no
/// Accessibility permission. One at a time is all Heed uses (`[keys] global_start_work`).
@MainActor
enum GlobalHotKey {
    private static var reference: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var action: (() -> Void)?
    private static var registered: String?

    /// Registers `notation` (vim notation with at least one of ⌃ ⌥ ⌘, e.g. `<C-M-Space>`); "" unregisters. Returns
    /// a problem to report, or nil.
    @discardableResult
    static func register(_ notation: String, action: @escaping () -> Void) -> String? {
        self.action = action
        guard notation != registered else { return nil }
        unregister()
        guard !notation.isEmpty else { return nil }
        guard let strokes = try? KeyNotation.parse(notation), strokes.count == 1, let stroke = strokes.first else {
            return "keys.global_start_work: \(notation) is not one key"
        }
        guard !stroke.modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return "keys.global_start_work: \(notation) needs ⌃, ⌥ or ⌘ so it does not swallow typing everywhere"
        }
        guard let code = keyCode(stroke.key) else { return "keys.global_start_work: no key code for \(stroke.key)" }
        installHandler()
        var modifiers: UInt32 = 0
        if stroke.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if stroke.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if stroke.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if stroke.modifiers.contains(.shift) || (stroke.key.count == 1 && stroke.key != stroke.key.lowercased()) {
            modifiers |= UInt32(shiftKey)
        }
        let id = EventHotKeyID(signature: OSType(0x4845_4544), id: 1) // "HEED"
        let status = RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            return "keys.global_start_work: \(notation) is taken by another app (\(status))"
        }
        registered = notation
        return nil
    }

    static func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        registered = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// US-layout virtual key codes for what a shortcut is likely to use.
    private static func keyCode(_ key: String) -> UInt32? {
        let named: [String: Int] = [
            "Space": kVK_Space, "CR": kVK_Return, "Tab": kVK_Tab, "Esc": kVK_Escape, "BS": kVK_Delete,
            "Up": kVK_UpArrow, "Down": kVK_DownArrow, "Left": kVK_LeftArrow, "Right": kVK_RightArrow,
        ]
        if let code = named[key] { return UInt32(code) }
        let characters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
        ]
        guard key.count == 1, let character = key.lowercased().first, let code = characters[character] else {
            return nil
        }
        return UInt32(code)
    }
}
