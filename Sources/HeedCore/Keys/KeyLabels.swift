/// Key notation as key-cap text: `<C-w>v` reads `⌃w v`.
public enum KeyCapText {
    public static func of(_ notation: String) -> String {
        guard let strokes = try? KeyNotation.parse(notation) else { return notation }
        return of(strokes)
    }

    /// Runs of plain characters share a cap (`gg`, `'1`); a modified or named key stands alone (`⌃w v`).
    public static func of(_ strokes: [KeyStroke]) -> String {
        var parts: [String] = []
        var previousPlain = false
        for stroke in strokes {
            let plain = stroke.modifiers.isEmpty && !stroke.isNamed
            if plain, previousPlain {
                parts[parts.count - 1] += stroke.glyph
            } else {
                parts.append(stroke.glyph)
            }
            previousPlain = plain
        }
        return parts.joined(separator: " ")
    }
}

/// Which key runs a command where you are: what hints, the `?` overlay and menus show next to a command.
public enum KeyLabels {
    public struct Label: Equatable, Sendable {
        /// As key caps: `gb`, `⌃w c`, `'1…'9` for a command bound once per argument.
        public let text: String
        /// Where the key works when that is not where you are: a view (`repos`) or a mode (`VISUAL`).
        public let context: String?
    }

    /// The keys bound to `command` as you have them, the ones valid here first: the current view's, then NORMAL's,
    /// then VISUAL's, then other views', then the other modes'. In VISUAL its own keys come first. A command name
    /// without arguments also finds the bindings that give it one (`pin.jump` finds `'1` to `'9`); a full line
    /// (`pin.jump 3`) finds only its own.
    public static func label(
        for command: String, keymaps: [Mode: Keymap], scoped: [String: Keymap], scope: String?, mode: Mode = .normal
    ) -> Label? {
        typealias Bindings = [(keys: [KeyStroke], command: String)]
        var tables: [(bindings: Bindings, context: String?)] = []
        let view = scope.flatMap { scoped[$0] }
        if mode == .visual { tables.append((keymaps[.visual]?.bindings ?? [], nil)) }
        tables.append((view?.bindings ?? [], nil))
        // NORMAL's keys that the view rebinds (Repos' `o`) do something else here.
        let normal = keymaps[.normal]?.bindings ?? []
        tables.append((view.map { view in normal.filter { view.lookup($0.keys) == .none } } ?? normal, nil))
        if mode != .visual { tables.append((keymaps[.visual]?.bindings ?? [], Mode.visual.label)) }
        for (name, keymap) in scoped.sorted(by: { $0.key < $1.key }) where name != scope {
            tables.append((keymap.bindings, name))
        }
        for other in [Mode.insert, .command, .hint] {
            tables.append((keymaps[other]?.bindings ?? [], other == mode ? nil : other.label))
        }
        for (bindings, context) in tables {
            guard let keys = keys(for: command, in: bindings) else { continue }
            return Label(text: text(keys), context: context)
        }
        return nil
    }

    /// The bindings of `command` in one table: its exact line, else (for a bare name) every line that names it.
    static func keys(for command: String, in bindings: [(keys: [KeyStroke], command: String)]) -> [[KeyStroke]]? {
        if let exact = bindings.first(where: { $0.command == command }) { return [exact.keys] }
        guard !command.contains(" ") else { return nil }
        let family = bindings.filter { CommandInvocation(parsing: $0.command).name == command }.map(\.keys)
        return family.isEmpty ? nil : family
    }

    /// One binding as caps; several (one per argument) as the first and last, `'1…'9`.
    static func text(_ keys: [[KeyStroke]]) -> String {
        guard let first = keys.first else { return "" }
        guard keys.count > 1, let last = keys.last else { return KeyCapText.of(first) }
        return KeyCapText.of(first) + "…" + KeyCapText.of(last)
    }
}
