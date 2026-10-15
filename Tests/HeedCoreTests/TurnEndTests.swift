import Foundation
@testable import HeedCore
import Testing

struct TurnEndTests {
    @Test(arguments: [
        "I fixed the parser. Should I also update the docs?",
        "Done with the refactor.\n\nWant me to open a PR?",
        "Two ways to go:\n\n1. Keep the cache\n2. Drop it\n\nWhich do you prefer?",
        "Which approach do you prefer:\n1. Rebase\n2. Merge",
        "Which approach would you like?\n\n1. Rebase onto main\n2. Merge main in",
        "The migration is ready. Shall I run it against staging?",
        "I can split this into two commits. Would you like that?",
        "Should I proceed with option B? (It touches the public API.)",
        "Do you want me to keep the old flag around?**",
        "Ready to apply the change, **should I go ahead?**",
        "Do you want the tests in the same file?\n```swift\nfunc testA() {}\n```",
        "I have a plan for the fix. Let me know if you want me to start on it.",
        "Please confirm the bucket name before I delete anything.",
        "The branch is prepared; awaiting your go-ahead to push.",
        "I've drafted the change but will wait before I proceed with the deletion.",
        "Everything is staged and I'm ready to proceed when you are.",
        "Let me know which you'd prefer and I'll implement it.",
        "There are two candidates, A and B. Your call.",
        "How would you like me to handle the deprecated endpoints",
        "I'm not sure about the naming. Would you prefer `fetchAll` or `loadAll`?",
        "Rename it to “Pipeline”?",
        "Should I squash these into one commit? Let me know if you need anything else.",
        "Which one should we keep? I lean towards the second.",
        "Can you confirm the expected output format.",
    ])
    func asksYou(_ text: String) {
        #expect(TurnEnd.asksYou(text), "\(text)")
    }

    @Test(arguments: [
        "",
        "Done. All 42 tests pass.",
        "I fixed the bug and pushed the branch.",
        "Let me know if you need anything else!",
        "The change is in. Let me know if you have any questions.",
        "Anything else?",
        "Implemented the endpoint. Is there anything else you'd like me to do?",
        "Hope this helps!",
        "Happy to help with anything further.",
        "Updated the handler. Feel free to ask if something is unclear.",
        "What would you like to work on next?",
        "Why did it fail? The cache was stale, so I now clear it on startup.",
        "Fixed the check in `isEmpty?` and the related test.",
        "The docs live at https://example.com/search?q=heed now.",
        "Here is the fix:\n```swift\nlet ok = value ?? fallback\n```",
        "Summary:\n- parser handles tabs\n- lexer emits newline tokens",
        "Let me know if you run into any issues with it.",
        "Asked the user whether to proceed earlier; they said yes, so it is merged.\nAll done.",
    ])
    func doesNotAsk(_ text: String) {
        #expect(!TurnEnd.asksYou(text), "\(text)")
    }

    @Test func onlyTheEndCounts() {
        let early = "Should I use a map here? I tried it and it was slower.\nI kept the array.\nTests pass."
        #expect(!TurnEnd.asksYou(early))
        let long = "Should I keep it? " + String(repeating: "Then I refactored more. ", count: 40) + "All done."
        #expect(!TurnEnd.asksYou(long))
    }

    @Test func trailingCodeBlocksAreDropped() {
        #expect(TurnEnd.withoutTrailingCode("Apply this?\n```\na\n```\n\n~~~\nb\n~~~") == "Apply this?")
        #expect(TurnEnd.withoutTrailingCode("no fence") == "no fence")
    }

    @Test func kindIsAskingGuessedOrDone() {
        #expect(TurnEnd.kind(lastWords: "Should I push?") == .guess(.asking, reason: TurnEnd.question))
        #expect(TurnEnd.kind(lastWords: "Pushed.") == .state(.done, reason: nil))
        #expect(TurnEnd.kind(lastWords: nil) == .state(.done, reason: nil))
    }
}

struct TurnEndHookTests {
    @Test func claudeStopReadsTheLastMessage() {
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["last_assistant_message": "Want me to push?"])
            == [.guess(.asking, reason: TurnEnd.question)])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["last_assistant_message": "Pushed."])
            == [.state(.done, reason: nil)])
    }

    @Test func claudeStopWithBackgroundWorkIsNotDone() {
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["background_tasks": [["id": "1"], ["id": "2"]]])
            == [.state(.working, reason: "2 background tasks")])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["session_crons": [["id": "c"]]])
            == [.state(.idle, reason: "1 scheduled")])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["background_tasks": [], "session_crons": []])
            == [.state(.done, reason: nil)])
        // A question still asks, background work or not.
        let asking: [String: Any] = ["last_assistant_message": "Should I wait?", "background_tasks": [1]]
        #expect(AgentIntegration.claudeHook(event: "Stop", input: asking) == [.guess(
            .asking,
            reason: TurnEnd.question
        )])
    }

    @Test func claudePlanToApprove() {
        #expect(AgentIntegration.claudeHook(event: "PreToolUse", input: ["tool_name": "ExitPlanMode"])
            == [.state(.asking, reason: "plan to approve")])
    }

    @Test func claudeIdlePromptIsSoft() {
        #expect(AgentIntegration.claudeHook(event: "Notification", input: ["notification_type": "idle_prompt"])
            == [.atPrompt])
    }

    @Test func codexStopReadsTheLastMessage() {
        #expect(AgentIntegration.codexHook(event: "Stop", input: ["last_assistant_message": "Shall I commit?"])
            == [.guess(.asking, reason: TurnEnd.question)])
        #expect(AgentIntegration.codexHook(event: "Stop", input: ["last_assistant_message": NSNull()])
            == [.state(.done, reason: nil)])
    }

    @Test func cursorReplyThatAsks() {
        #expect(AgentIntegration.cursorHook(event: "afterAgentResponse", input: ["text": "Should I continue?"])
            == [.guess(.asking, reason: TurnEnd.question)])
        #expect(AgentIntegration.cursorHook(event: "afterAgentResponse", input: ["text": "Done."]).isEmpty)
    }

    @Test func piAndOpencodeSendTheLastTextWithTheirEnd() throws {
        #expect(try HookCommandLine.parse(["hook", "pi", "idle", "p1", "", "Do you want the tests too?"])
            == [.guess(.asking, reason: TurnEnd.question)])
        #expect(try HookCommandLine.parse(["hook", "pi", "idle", "p1", ""]) == [.state(.done, reason: nil)])
        #expect(try HookCommandLine.parse(["hook", "opencode", "session.status", "s", "idle", "Which one?"])
            == [.guess(.asking, reason: TurnEnd.question)])
        #expect(try HookCommandLine.parse(["hook", "opencode", "session.status", "s", "idle", "All green."])
            == [.state(.done, reason: nil)])
    }
}

struct ObservedStateTurnTests {
    @Test func idlePromptNeverDowngradesWhatTheTurnSaid() {
        for state in [AgentState.done, .asking, .blocked, .limited, .exited] {
            #expect(ObservedState(state).atPrompt() == ObservedState(state))
        }
        #expect(ObservedState(.working).atPrompt() == ObservedState(.idle))
        #expect(ObservedState(.idle, reason: "1 scheduled").atPrompt() == ObservedState(.idle, reason: "1 scheduled"))
    }

    @Test func aGuessFromTheTurnReplacesAReportedState() {
        let asking = ObservedState(.working, reason: "Bash").guessing(.asking, reason: TurnEnd.question)
        #expect(asking == ObservedState(.asking, source: .guessed, reason: TurnEnd.question))
        #expect(ObservedState(.exited).guessing(.asking, reason: TurnEnd.question) == ObservedState(.exited))
    }

    @Test func cursorsDoneKeepsTheQuestion() {
        let asking = ObservedState(.asking, source: .guessed, reason: TurnEnd.question)
        #expect(asking.accepting(ObservedState(.done)) == asking)
        #expect(asking.accepting(ObservedState(.working, reason: "prompt")) == ObservedState(
            .working,
            reason: "prompt"
        ))
        let screen = ObservedState(.asking, source: .guessed, reason: "from the screen")
        #expect(screen.accepting(ObservedState(.done)) == ObservedState(.done))
    }
}
