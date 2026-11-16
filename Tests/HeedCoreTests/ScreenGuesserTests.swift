import Foundation
@testable import HeedCore
import Testing

struct ScreenGuesserTests {
    private let agent = AgentProfile(name: "x", command: "x")

    static let screens: [(String, AgentState?)] = [
        ("some output\nDo you want to proceed?\n❯ 1. Yes", .blocked),
        ("✻ Thinking… (esc to interrupt)", .working),
        ("Error: rate limit reached, retrying", .limited),
        ("all done\n$ ", nil),
        ("Do you want to proceed?\n" + String(repeating: "line\n", count: 20), nil),
        ("Please answer the questions below\n> ", .asking),
        ("", nil),
    ]

    @Test(arguments: screens) func compiledPatternsGuess(screen: String, state: AgentState?) {
        var guesser = ScreenGuesser()
        #expect(ScreenGuess.guess(screen, compiled: guesser.compiled(for: agent)) == state)
    }

    @Test func anExpressionThatDoesNotCompileIsLeftOut() {
        let compiled = ScreenGuess.Compiled([(.working, ["(unclosed", "Pondering"])])
        #expect(compiled.count == 1)
        #expect(ScreenGuess.guess("Pondering deeply", compiled: compiled) == .working)
    }

    @Test func anAgentsPatternsAreCompiledOnceUntilTheyChange() {
        var guesser = ScreenGuesser()
        for _ in 0 ..< 100 {
            _ = guesser.compiled(for: agent)
        }
        #expect(guesser.compilations == 1)
        var changed = agent
        changed.patterns = ["working": "Pondering"]
        let compiled = guesser.compiled(for: changed)
        #expect(guesser.compilations == 2)
        #expect(ScreenGuess.guess("Pondering deeply", compiled: compiled) == .working)
        _ = guesser.compiled(for: AgentProfile(name: "y", command: "y"))
        #expect(guesser.compilations == 3)
    }

    @Test func aPaneWhoseScreenDidNotChangeKeepsItsGuess() {
        var guesser = ScreenGuesser()
        #expect(guesser.remembered(pane: "p", text: "esc to interrupt", agent: agent) == nil)
        guesser.remember(pane: "p", text: "esc to interrupt", agent: agent, guess: .working)
        #expect(guesser.remembered(pane: "p", text: "esc to interrupt", agent: agent) == .some(.working))
        // A guess of nothing is remembered too.
        guesser.remember(pane: "q", text: "$ ", agent: agent, guess: nil)
        #expect(guesser.remembered(pane: "q", text: "$ ", agent: agent) == .some(nil))
        // A new screen, another agent, or the agent's patterns changed: guessed again.
        #expect(guesser.remembered(pane: "p", text: "esc to interrupt.", agent: agent) == nil)
        #expect(guesser.remembered(pane: "p", text: "esc to interrupt", agent: AgentProfile(name: "y", command: "y"))
            == nil)
        var changed = agent
        changed.patterns = ["working": "Pondering"]
        #expect(guesser.remembered(pane: "p", text: "esc to interrupt", agent: changed) == nil)
    }

    @Test func panesNoLongerReadAreForgotten() {
        var guesser = ScreenGuesser()
        guesser.remember(pane: "p", text: "a", agent: agent, guess: nil)
        guesser.remember(pane: "q", text: "b", agent: agent, guess: nil)
        guesser.keep(only: ["q"])
        #expect(guesser.rememberedPanes == ["q"])
    }
}
