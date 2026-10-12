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
