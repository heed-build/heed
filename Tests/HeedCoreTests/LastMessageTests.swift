import Foundation
@testable import HeedCore
import Testing

/// The agent's last message reaches heed with its turn's end (for summaries), capped, from every agent that sends it.
struct LastMessageTests {
    @Test func claudeAndCodexSendItWithTheirStop() {
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["last_assistant_message": "Pushed."])
            == [.lastMessage("Pushed."), .state(.done, reason: nil)])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["last_assistant_message": "Want me to push?"])
            == [.lastMessage("Want me to push?"), .guess(.asking, reason: TurnEnd.question)])
        let background: [String: Any] = ["last_assistant_message": "Started the build.", "background_tasks": [1]]
        #expect(AgentIntegration.claudeHook(event: "Stop", input: background)
            == [.lastMessage("Started the build."), .state(.working, reason: "1 background task")])
        #expect(AgentIntegration.codexHook(event: "Stop", input: ["last_assistant_message": "Tests pass."])
            == [.lastMessage("Tests pass."), .state(.done, reason: nil)])
        // Nothing said, nothing sent.
        #expect(AgentIntegration.codexHook(event: "Stop", input: ["last_assistant_message": NSNull()])
            == [.state(.done, reason: nil)])
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["last_assistant_message": "  "])
            == [.state(.done, reason: nil)])
    }

    @Test func aSubagentsLastWordsAreNotTheSessions() throws {
        let kinds = try HookCommandLine.parse(["hook", "claude", "Stop"]) {
            Data(#"{"agent_id":"s1","agent_type":"Explore","last_assistant_message":"Found it."}"#.utf8)
        }
        #expect(!kinds.contains { if case .lastMessage = $0 { true } else { false } })
    }

    @Test func cursorPiAndOpencodeSendTheirReply() throws {
        #expect(AgentIntegration.cursorHook(event: "afterAgentResponse", input: ["text": "Done."])
            == [.lastMessage("Done.")])
        #expect(AgentIntegration.cursorHook(event: "afterAgentResponse", input: ["text": "Should I continue?"])
            == [.lastMessage("Should I continue?"), .guess(.asking, reason: TurnEnd.question)])
        #expect(try HookCommandLine.parse(["hook", "pi", "idle", "p1", "", "All green."])
            == [.lastMessage("All green."), .state(.done, reason: nil)])
        #expect(try HookCommandLine.parse(["hook", "opencode", "session.status", "s", "idle", "Which one?"])
            == [.lastMessage("Which one?"), .guess(.asking, reason: TurnEnd.question)])
        #expect(try HookCommandLine.parse(["hook", "pi", "idle", "p1", ""]) == [.state(.done, reason: nil)])
    }

    @Test func itIsCappedKeepingItsEnd() {
        let long = String(repeating: "a", count: LastMessage.limit) + "THE END"
        guard case let .lastMessage(text) = AgentIntegration.codexHook(
            event: "Stop", input: ["last_assistant_message": long]
        ).first else {
            Issue.record("no last message")
            return
        }
        #expect(text.count == LastMessage.limit)
        #expect(text.hasPrefix("…") && text.hasSuffix("THE END"))
    }

    @Test func sessionsKeepTheNewestAndOldCachesLoad() throws {
        var session = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.done))
        session.lastMessage = "Done: tests pass."
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data).lastMessage == "Done: tests pass.")
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["lastMessage"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.lastMessage == nil)
    }
}
