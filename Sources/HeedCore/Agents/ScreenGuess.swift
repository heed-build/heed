import Foundation

/// Guesses an agent's state from its terminal's visible text, for states it has no hook for. Guesses are marked
/// `.guessed` (a dotted ring) and never override a reported state (`ObservedState.accepting`).
public enum ScreenGuess {
    /// State → regular expressions, checked against the last lines of the screen, first match wins in this order.
    public typealias Patterns = [(AgentState, [String])]

    public static let order: [AgentState] = [.limited, .blocked, .asking, .working, .idle]

    /// Patterns most agent TUIs share. Agents add or replace them per state with `[agents.<name>.patterns]`.
    public static let common: [AgentState: [String]] = [
        .limited: [#"(?i)rate.?limit"#, #"(?i)usage limit"#, #"(?i)\b429\b"#, #"(?i)quota exceeded"#],
        .blocked: [
            #"(?i)do you want to (proceed|allow|run|make this edit|create)"#, #"(?i)allow (this|command|once|always)"#,
            #"(?i)approve\b.*\?"#, #"(?i)\[y/n\]"#, #"(?i)permission (required|needed|requested)"#,
        ],
        .asking: [#"(?i)(answer|reply to) (the|these|my) questions?"#, #"(?i)\bselect an option\b"#],
        .working: [#"(?i)esc to (interrupt|cancel)"#, #"(?i)ctrl\+c to (interrupt|cancel)"#],
    ]

    /// Built-in patterns merged with an agent's own (`agent.patterns` replaces a state's list when present).
    public static func patterns(for agent: AgentProfile) -> Patterns {
        order.compactMap { state in
            let own = agent.patterns[state.rawValue].map { [$0] }
            let list = own ?? common[state] ?? []
            return list.isEmpty ? nil : (state, list)
        }
    }

    /// The guessed state, or nil when nothing matches. Only the last `lines` lines count: older output may
    /// mention a prompt that is long gone.
    public static func guess(_ screen: String, patterns: Patterns, lines: Int = 12) -> AgentState? {
        let tail = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        let range = NSRange(tail.startIndex..., in: tail)
        for (state, expressions) in patterns {
            for expression in expressions {
                guard let regex = try? NSRegularExpression(pattern: expression) else { continue }
                if regex.firstMatch(in: tail, range: range) != nil { return state }
            }
        }
        return nil
    }

    /// Whether answering yes to the agent's permission prompt is one Return, and the screen shows exactly that prompt:
    /// a notification's Allow presses it only then. Claude's prompt asks "Do you want to …?" over a list whose cursor
    /// starts on `1. Yes`; anything else (another agent, the cursor moved, the prompt gone) is left to you.
    public static func allowsWithReturn(agent: String, screen: String) -> Bool {
        guard agent == "claude" else { return false }
        // Rows below the prompt are blank on a screen that is not full yet.
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.reversed().drop { $0.allSatisfy(\.isWhitespace) }.prefix(16).reversed().joined(separator: "\n")
        return tail.range(
            of: #"(?i)do you want to (proceed|make this edit|create|run|allow)"#,
            options: .regularExpression
        )
            != nil && tail.range(of: #"(?m)^[\s│|]*❯\s*1\.\s*Yes\b"#, options: .regularExpression) != nil
    }

    /// Which states an agent's integration reports itself; the rest are worth guessing from the screen.
    public static func reported(by agent: String) -> Set<AgentState> {
        switch agent {
        case "claude": [.working, .idle, .blocked, .asking, .done, .exited, .limited]
        case "opencode": [.working, .idle, .blocked, .asking, .done, .limited]
        case "codex": [.working, .idle, .blocked, .done]
        case "cursor": [.working, .done]
        case "pi": [.working, .idle, .done]
        default: []
        }
    }
}

/// For agents whose turn-end hook does not always arrive (cursor, and codex when a turn ends without `Stop` or
/// `Interrupt`): a turn that went quiet, with no hook and a screen
/// that has not changed for `after`, is taken as over. A working agent's screen moves (its spinner, its output).
public struct QuietTurn: Sendable {
    /// A session's turn: a wrong guess is put right by the agent's next hook.
    public static let after: TimeInterval = 20
    /// A run's: ending one is final, so a long silent build should not look like the end.
    public static let runAfter: TimeInterval = 60

    /// The agents this applies to.
    public static func applies(to agent: String) -> Bool { agent == "cursor" || agent == "codex" }

    private var lastText: [String: String] = [:]
    private var changedAt: [String: Date] = [:]

    public init() {}

    /// Records what a pane shows now; true when it has been still, and its hooks silent, for `after`.
    public mutating func isQuiet(
        pane: String, text: String, lastHook: Date?, now: Date, after: TimeInterval = QuietTurn.after
    ) -> Bool {
        if lastText[pane] != text {
            lastText[pane] = text
            changedAt[pane] = now
            return false
        }
        let still = changedAt[pane].map { now.timeIntervalSince($0) >= after } ?? false
        let silent = lastHook.map { now.timeIntervalSince($0) >= after } ?? true
        return still && silent
    }

    public mutating func forget(pane: String) {
        lastText[pane] = nil
        changedAt[pane] = nil
    }
}
