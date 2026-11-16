import Foundation

/// What screen reading keeps between ticks, so a second's guesses cost only what changed: each agent's patterns
/// compiled once (again only when its patterns change), and each pane's last guess with the screen it was made from.
/// A guess depends only on the screen and the patterns, so a pane whose screen and agent did not change is answered
/// from the last guess without matching anything.
public struct ScreenGuesser: Sendable {
    private struct Agent: Sendable {
        var patterns: [String: String]
        var compiled: ScreenGuess.Compiled
    }

    private struct Last: Sendable {
        var text: String
        var agent: String
        var patterns: [String: String]
        var guess: AgentState?
    }

    private var agents: [String: Agent] = [:]
    private var last: [String: Last] = [:]
    /// How many times an agent's patterns were compiled.
    public private(set) var compilations = 0

    public init() {}

    /// The agent's patterns, compiled: from the cache unless its patterns changed since.
    public mutating func compiled(for agent: AgentProfile) -> ScreenGuess.Compiled {
        if let known = agents[agent.name], known.patterns == agent.patterns { return known.compiled }
        let compiled = ScreenGuess.Compiled(ScreenGuess.patterns(for: agent))
        agents[agent.name] = Agent(patterns: agent.patterns, compiled: compiled)
        compilations += 1
        return compiled
    }

    /// The guess made last time `pane` showed exactly `text` under the same agent and patterns; nil when it has to be
    /// made again (the outer optional: a remembered guess of nothing is `.some(nil)`).
    public func remembered(pane: String, text: String, agent: AgentProfile) -> AgentState?? {
        guard let known = last[pane], known.agent == agent.name, known.patterns == agent.patterns,
              known.text == text
        else { return nil }
        return .some(known.guess)
    }

    /// Keeps the guess made for `pane` showing `text`.
    public mutating func remember(pane: String, text: String, agent: AgentProfile, guess: AgentState?) {
        last[pane] = Last(text: text, agent: agent.name, patterns: agent.patterns, guess: guess)
    }

    /// Forgets the panes not in `panes` (closed, or no longer read).
    public mutating func keep(only panes: Set<String>) {
        guard last.keys.contains(where: { !panes.contains($0) }) else { return }
        last = last.filter { panes.contains($0.key) }
    }

    /// The panes with a remembered guess.
    public var rememberedPanes: Set<String> { Set(last.keys) }
}
