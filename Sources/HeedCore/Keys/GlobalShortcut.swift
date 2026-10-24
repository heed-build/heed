/// `[keys] global_start_work` and `global_activate`: what a system-wide shortcut may be. One key with ⌃, ⌥ or ⌘ held,
/// on a key the hotkey API can name, and not the other shortcut. Settings checks a value before writing it; the app
/// checks it again when it registers one.
public enum GlobalShortcut {
    /// Named keys a system-wide shortcut can use.
    public static let namedKeys: Set<String> = ["Space", "CR", "Tab", "Esc", "BS", "Up", "Down", "Left", "Right"]
    /// Characters a system-wide shortcut can use (US layout, lowercase).
    public static let characters = Set("abcdefghijklmnopqrstuvwxyz0123456789,./;'[]-=`\\")

    /// Why `notation` cannot be a system-wide shortcut, or nil when it can. `""` (off) always can. `other` is the
    /// other shortcut's notation, which this one may not repeat.
    public static func problem(_ notation: String, other: String? = nil) -> String? {
        guard !notation.isEmpty else { return nil }
        guard let strokes = try? KeyNotation.parse(notation), strokes.count == 1, let stroke = strokes.first else {
            return "\(notation) is not one key"
        }
        guard !stroke.modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return "\(notation) needs ⌃, ⌥ or ⌘ so it does not swallow typing everywhere"
        }
        let known = stroke.isNamed ? namedKeys.contains(stroke.key)
            : stroke.key.lowercased().first.map(characters.contains) ?? false
        guard known else { return "no key code for \(stroke.key)" }
        if let other, !other.isEmpty, (try? KeyNotation.parse(other)) == strokes {
            return "\(notation) is already the other global shortcut"
        }
        return nil
    }
}
