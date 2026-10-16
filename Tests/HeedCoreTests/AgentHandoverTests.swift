import Foundation
@testable import HeedCore
import Testing

struct AgentHandoverTests {
    @Test func theHookSaysWhichAgentSentIt() {
        #expect(HookCommandLine.agent(["hook", "cursor", "stop"]) == "cursor")
        #expect(HookCommandLine.agent(["hook"]) == nil)
        #expect(HookCommandLine.agent(["doctor"]) == nil)
    }

    @Test func theAgentTravelsAndOldMessagesStillDecode() throws {
        let message = HookMessage(session: "s1", pane: "p1", kind: .state(.working, reason: nil), agent: "cursor")
        let decoded = try HookMessage.decode(line: message.encodedLine())
        #expect(decoded.agent == "cursor")
        // A helper from before the field: no agent, still read.
        var old = try JSONSerialization.jsonObject(with: message.encodedLine()) as? [String: Any] ?? [:]
        old["agent"] = nil
        let line = try JSONSerialization.data(withJSONObject: old)
        #expect(try HookMessage.decode(line: line).agent == nil)
    }

    @Test func hostEventsCarryTheAgent() {
        let args = ["hook", "pi", "busy", "sid"].map { Data($0.utf8).base64EncodedString() }.joined(separator: " ")
        let line = "1000000\ts1\tp1\t\(args)\t"
        #expect(HostEvents.messages(fromLine: line).first?.agent == "pi")
    }
}
