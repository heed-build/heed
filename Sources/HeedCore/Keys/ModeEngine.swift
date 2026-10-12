/// Turns key strokes into commands, one mode at a time. Pure state: no UI, no AppKit, so all of key routing except the
/// last hop into the terminal is unit-tested.
///
/// - NORMAL and VISUAL: digits build a count (`3j`), keys build a sequence until it is bound (`gg`, `<C-w>v`) or
///   cannot be (`gq` clears and reports itself unbound). `<Esc>` clears what is pending.
/// - INSERT: every key goes to the terminal except single-key bindings (the escape chord, `<D-/>`).
/// - COMMAND and HINT: keys feed the command line or the hint field, except their own bindings (`<Esc>`, `<CR>`).
///
/// Commands named `mode.<name>` switch mode here as well as being reported, so the caller only has to redraw.
public struct ModeEngine: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Send the key to the focused terminal (INSERT).
        case terminal
        /// Feed the key to the command line or hint field (COMMAND, HINT).
        case text(KeyStroke)
        /// Waiting for more keys; show `pendingDisplay` in the status bar.
        case pending
        /// Run a command.
        case run(CommandInvocation)
        /// The sequence matched nothing; it has been cleared.
        case unbound([KeyStroke])
        /// `<Esc>` with something pending: the count and keys were dropped.
        case cleared
    }

    public private(set) var mode: Mode = .normal
    public private(set) var pending: [KeyStroke] = []
    public private(set) var count: Int?
    public private(set) var keymaps: [Mode: Keymap]

    public init(keymaps: [Mode: Keymap]) {
        self.keymaps = keymaps
    }

    /// What the status bar shows while keys are pending: `3`, `g`, `2<C-w>`.
    public var pendingDisplay: String {
        (count.map(String.init) ?? "") + KeyNotation.format(pending)
    }

    public mutating func setKeymaps(_ keymaps: [Mode: Keymap]) {
        self.keymaps = keymaps
        reset()
    }

    public mutating func enter(_ mode: Mode) {
        self.mode = mode
        reset()
    }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        let keymap = keymaps[mode] ?? Keymap()
        switch mode {
        case .insert:
            if case let .command(line) = keymap.lookup([stroke]) { return run(line, count: nil) }
            return .terminal
        case .command, .hint:
            if case let .command(line) = keymap.lookup([stroke]) { return run(line, count: nil) }
            return .text(stroke)
        case .normal, .visual:
            return handleSequence(stroke, keymap: keymap)
        }
    }

    private mutating func handleSequence(_ stroke: KeyStroke, keymap: Keymap) -> Outcome {
        if stroke == .escape, !pending.isEmpty || count != nil {
            reset()
            return .cleared
        }
        // Digits are counts, as in vim; `0` only continues one, so it stays free to bind.
        if pending.isEmpty, stroke.modifiers.isEmpty, let digit = Int(stroke.key), digit > 0 || count != nil {
            count = min((count ?? 0) * 10 + digit, 9999)
            return .pending
        }
        let keys = pending + [stroke]
        switch keymap.lookup(keys) {
        case let .command(line):
            let count = count
            reset()
            return run(line, count: count)
        case .prefix:
            pending = keys
            return .pending
        case .none:
            reset()
            return .unbound(keys)
        }
    }

    private mutating func run(_ line: String, count: Int?) -> Outcome {
        let invocation = CommandInvocation(parsing: line, count: count)
        if invocation.name.hasPrefix("mode."), let target = Mode(rawValue: String(invocation.name.dropFirst(5))) {
            enter(target)
        }
        return .run(invocation)
    }

    private mutating func reset() {
        pending = []
        count = nil
    }
}

/// A command with its arguments, as bound to a key or typed after `:`. `"pin.jump 3"` is `pin.jump` with `["3"]`.
public struct CommandInvocation: Equatable, Sendable {
    public let name: String
    public let arguments: [String]
    /// The count typed before the keys (`3j`), if any.
    public let count: Int?

    public init(name: String, arguments: [String] = [], count: Int? = nil) {
        self.name = name
        self.arguments = arguments
        self.count = count
    }

    public init(parsing line: String, count: Int? = nil) {
        let words = CommandInvocation.split(line)
        self.init(name: words.first ?? "", arguments: Array(words.dropFirst()), count: count)
    }

    /// Splits on spaces, keeping `"double quoted"` words together.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for char in line {
            if char == "\"" {
                quoted.toggle()
            } else if char == " ", !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
