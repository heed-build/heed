/// One key press: a key plus the modifiers held with it.
///
/// Keys are written in vim notation everywhere (config, the `?` overlay, the status bar's pending keys), so a binding
/// reads the same wherever it shows up: `gg`, `<C-w>v`, `<D-/>`, `<Esc>`, `<CR>`, `<Space>`.
public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        /// Only kept for named keys (`<S-Tab>`); for characters the shifted character itself is the key (`G`, `?`).
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// A single character (`g`, `G`, `/`, `'`) or a named key (`Esc`, `CR`, `Tab`, `Space`, `BS`, `Up`, ...).
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        // Letters typed with control are case-insensitive in vim notation: <C-W> is <C-w>.
        self.key = modifiers.contains(.control) && key.count == 1 ? key.lowercased() : key
        self.modifiers = key.count == 1 ? modifiers.subtracting(.shift) : modifiers
    }

    public var isNamed: Bool { key.count > 1 }

    public var description: String {
        if modifiers.isEmpty, !isNamed {
            return key == "<" ? "<lt>" : key
        }
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        return "<\(prefix)\(key == "<" ? "lt" : key)>"
    }

    /// The compact glyph form used in the UI's key caps: `⌃w`, `⌘/`, `⎋`, `↩`.
    public var glyph: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case "Esc": out += "⎋"
        case "CR": out += "↩"
        case "Tab": out += "⇥"
        case "Space": out += "␣"
        case "BS": out += "⌫"
        case "Up": out += "↑"
        case "Down": out += "↓"
        case "Left": out += "←"
        case "Right": out += "→"
        default: out += key
        }
        return out
    }

    public static let escape = KeyStroke("Esc")
}

/// Parsing of vim key notation into strokes.
public enum KeyNotation {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let notation: String
        public let reason: String
        public var description: String { "'\(notation)': \(reason)" }
    }

    static let namedKeys: [String: String] = [
        "esc": "Esc", "cr": "CR", "enter": "CR", "return": "CR", "tab": "Tab", "space": "Space", "bs": "BS",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right", "lt": "<", "bslash": "\\", "bar": "|",
        "del": "Del", "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown",
    ]

    /// Parses `"<C-w>v"` into `[<C-w>, v]`. Characters outside `<...>` are one stroke each.
    public static func parse(_ notation: String) throws(ParseError) -> [KeyStroke] {
        var strokes: [KeyStroke] = []
        var index = notation.startIndex
        while index < notation.endIndex {
            let char = notation[index]
            if char == "<", let close = notation[index...].firstIndex(of: ">"), close > notation.index(after: index) {
                let body = String(notation[notation.index(after: index) ..< close])
                try strokes.append(parseBracketed(body, in: notation))
                index = notation.index(after: close)
            } else {
                strokes.append(KeyStroke(String(char)))
                index = notation.index(after: index)
            }
        }
        if strokes.isEmpty { throw ParseError(notation: notation, reason: "empty key sequence") }
        return strokes
    }

    private static func parseBracketed(_ body: String, in notation: String) throws(ParseError) -> KeyStroke {
        var modifiers: KeyStroke.Modifiers = []
        var rest = Substring(body)
        while rest.count > 2, rest[rest.index(after: rest.startIndex)] == "-" {
            switch rest.first!.uppercased() {
            case "C": modifiers.insert(.control)
            case "M", "A": modifiers.insert(.option)
            case "D": modifiers.insert(.command)
            case "S": modifiers.insert(.shift)
            default: throw ParseError(notation: notation, reason: "unknown modifier '\(rest.first!)-'")
            }
            rest = rest.dropFirst(2)
        }
        let key = String(rest)
        if key.count == 1 { return KeyStroke(key, modifiers) }
        guard let named = namedKeys[key.lowercased()] else {
            throw ParseError(notation: notation, reason: "unknown key '<\(body)>'")
        }
        return KeyStroke(named, modifiers)
    }

    public static func format(_ strokes: [KeyStroke]) -> String { strokes.map(\.description).joined() }
}
