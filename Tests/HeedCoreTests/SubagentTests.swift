import Foundation
@testable import HeedCore
import Testing

struct SubagentHookTests {
    private func parse(_ agent: String, _ event: String, _ json: String) throws -> [HookMessage.Kind] {
        try HookCommandLine.parse(["hook", agent, event]) { Data(json.utf8) }
    }

    @Test func claudeStartAndStop() throws {
        #expect(try parse("claude", "SubagentStart", #"""
        {"session_id":"abc123","hook_event_name":"SubagentStart","agent_id":"subagent_xyz789",
         "agent_type":"Explore","parent_agent_id":null}
        """#) == [.subagent(id: "subagent_xyz789", type: "Explore", started: true)])
        // Its last words are for its parent: a question there is not one to you, and the session's turn is not over.
        #expect(try parse("claude", "SubagentStop", #"""
        {"session_id":"abc123","hook_event_name":"SubagentStop","agent_id":"subagent_xyz789","agent_type":"Explore",
         "agent_transcript_path":"/tmp/s.jsonl","last_assistant_message":"Found three issues. Should I fix them?"}
        """#) == [.subagent(id: "subagent_xyz789", type: "Explore", started: false)])
    }

    @Test func codexStartAndStop() throws {
        #expect(try parse("codex", "SubagentStart", #"""
        {"session_id":"c1","turn_id":"t1","agent_id":"a1","agent_type":"worker","permission_mode":"default"}
        """#) == [.subagent(id: "a1", type: "worker", started: true)])
        #expect(try parse("codex", "SubagentStop", #"""
        {"session_id":"c1","turn_id":"t1","agent_id":"a1","agent_type":"worker","agent_transcript_path":"/tmp/a",
         "stop_hook_active":false,"last_assistant_message":"Want me to continue?"}
        """#) == [.subagent(id: "a1", type: "worker", started: false)])
    }

    @Test func aStartWithoutAnIdIsDropped() throws {
        #expect(try parse("claude", "SubagentStart", #"{"agent_type":"Explore"}"#).isEmpty)
    }

    @Test func hooksInsideASubagentReportItsState() throws {
        #expect(try parse("claude", "PreToolUse", #"""
        {"agent_id":"s1","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"TODO"}}
        """#) == [.subagentState(.working, reason: "Grep(TODO)", id: "s1", type: "Explore")])
        #expect(try parse("claude", "PermissionRequest", #"""
        {"agent_id":"s1","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"rm x"}}
        """#) == [.subagentState(.blocked, reason: "Bash(rm x)", id: "s1", type: "general-purpose")])
        #expect(try parse("codex", "PreToolUse", #"{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
            == [.subagentState(.working, reason: "Bash(ls)", id: "a1", type: nil)])
        // A PR it opened is still the session's.
        let created = try parse("claude", "PostToolUse", #"""
        {"agent_id":"s1","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"},
         "tool_response":{"stdout":"https://github.com/o/r/pull/7"}}
        """#)
        #expect(created == [
            .subagentState(.working, reason: "Bash", id: "s1", type: nil), .prAdd(url: "https://github.com/o/r/pull/7"),
        ])
    }

    @Test func aSessionAgentAloneIsTheMainThread() throws {
        // `--agent` sets agent_type on every hook, with no agent_id: still the session's own.
        #expect(try parse("claude", "PreToolUse", #"{"agent_type":"reviewer","tool_name":"Read"}"#)
            == [.state(.working, reason: "Read")])
    }

    @Test func claudeStopSaysWhenNothingIsLeftInTheBackground() throws {
        #expect(try parse("claude", "Stop", #"{"background_tasks":[]}"#)
            == [.subagentsEnded, .state(.done, reason: nil)])
        #expect(try parse("claude", "Stop", "{}") == [.state(.done, reason: nil)])
        #expect(try parse("claude", "Stop", #"{"background_tasks":[{"id":"x"}]}"#)
            == [.state(.working, reason: "1 background task")])
    }

    @Test func bothAgentsRegisterTheSubagentEvents() throws {
        let events = Set(AgentIntegration.claudeEvents.map(\.event))
        #expect(events.isSuperset(of: ["SubagentStart", "SubagentStop"]))
        let codex = AgentIntegration.codexArguments(heed: "/app/heed").joined(separator: " ")
        #expect(codex.contains("hook codex SubagentStart") && codex.contains("hook codex SubagentStop"))
    }

    @Test func newKindsSurviveTheSocket() throws {
        for kind: HookMessage.Kind in [
            .subagent(id: "a", type: nil, started: true),
            .subagentState(.blocked, reason: "Bash", id: "a", type: "Explore"), .subagentsEnded,
        ] {
            let message = HookMessage(session: "s", kind: kind, sentAt: Date(timeIntervalSince1970: 0))
            #expect(try HookMessage.decode(line: message.encodedLine()) == message)
        }
    }
}

struct SubagentTrackingTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func startsStopsAndKeepsOrder() {
        var subagents = Subagents()
        subagents.start(id: "a", type: "Explore", at: t0)
        subagents.start(id: "b", type: nil, at: t0.addingTimeInterval(5))
        subagents.start(id: "a", type: nil, at: t0.addingTimeInterval(9))
        #expect(subagents.live.map(\.id) == ["a", "b"])
        #expect(subagents.live[0].type == "Explore")
        #expect(subagents.live[0].startedAt == t0)
        subagents.stop(id: "a")
        #expect(subagents.live.map(\.id) == ["b"])
        subagents.stop(id: "unknown")
        #expect(subagents.count == 1)
    }

    @Test func aToolEventMarksAMissedStartAlive() {
        var subagents = Subagents()
        subagents.seen(id: "a", type: "Plan", at: t0)
        #expect(subagents.live == [LiveSubagent(id: "a", type: "Plan", startedAt: t0)])
    }

    @Test func staleOnesAreDropped() {
        var subagents = Subagents()
        subagents.start(id: "old", type: nil, at: t0)
        subagents.start(id: "busy", type: nil, at: t0)
        subagents.seen(id: "busy", type: nil, at: t0.addingTimeInterval(Subagents.staleAfter))
        subagents.dropStale(now: t0.addingTimeInterval(Subagents.staleAfter + 60))
        #expect(subagents.live.map(\.id) == ["busy"])
    }

    @Test func exitingClearsThem() {
        var subagents = Subagents()
        subagents.start(id: "a", type: nil, at: t0)
        #expect(subagents.main(.exited, reason: "exit") == (.exited, "exit"))
        #expect(subagents.isEmpty)
    }
}

struct SubagentStateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func running(_ ids: String...) -> Subagents {
        var subagents = Subagents()
        for id in ids {
            subagents.start(id: id, type: nil, at: t0)
        }
        return subagents
    }

    @Test func aMainStopWhileSubagentsRunKeepsTheSessionWorking() {
        var subagents = running("a", "b")
        #expect(subagents.main(.done, reason: nil) == (.working, "2 subagents running"))
        #expect(subagents.main(.idle, reason: "1 scheduled") == (.working, "2 subagents running"))
        subagents.stop(id: "a")
        #expect(subagents.main(.done, reason: nil) == (.working, "1 subagent running"))
        subagents.stop(id: "b")
        #expect(subagents.main(.done, reason: nil) == (.done, nil))
    }

    @Test func theMainThreadsPromptsPassThrough() {
        var subagents = running("a")
        #expect(subagents.main(.blocked, reason: "Bash") == (.blocked, "Bash"))
        #expect(subagents.main(.limited, reason: "rate limited") == (.limited, "rate limited"))
    }

    @Test func aSubagentsPermissionPromptBlocksTheSession() {
        var subagents = running("a")
        #expect(subagents.fromSubagent(.blocked, reason: "Bash(rm x)", id: "a", current: ObservedState(.working))
            == ObservedState(.blocked, reason: "Bash(rm x)"))
        #expect(subagents.blockedBy == "a")
    }

    @Test func aSubagentsToolDoesNotClearTheMainThreadsPrompt() {
        var subagents = running("a")
        for state in [ObservedState(.blocked, reason: "Bash"), ObservedState(.asking, reason: "2 questions")] {
            #expect(subagents.fromSubagent(.working, reason: "Grep", id: "a", current: state) == nil)
        }
    }

    @Test func onlyTheSubagentThatAskedMovesItsPromptOn() {
        var subagents = running("a", "b")
        let blocked = subagents.fromSubagent(.blocked, reason: "Bash", id: "a", current: ObservedState(.working))!
        #expect(subagents.fromSubagent(.working, reason: "Read", id: "b", current: blocked) == nil)
        #expect(subagents.fromSubagent(.working, reason: "Bash", id: "a", current: blocked)
            == ObservedState(.working, reason: "Bash"))
        #expect(subagents.blockedBy == nil)
    }

    @Test func theMainThreadTakesOverFromASubagentsPrompt() {
        var subagents = running("a")
        _ = subagents.fromSubagent(.blocked, reason: "Bash", id: "a", current: ObservedState(.working))
        _ = subagents.main(.working, reason: "Edit")
        #expect(subagents.blockedBy == nil)
    }

    @Test func aSubagentsTurnEndingIsNotTheSessions() {
        var subagents = running("a")
        for state in [AgentState.done, .idle, .limited, .exited] {
            #expect(subagents.fromSubagent(state, reason: nil, id: "a", current: ObservedState(.working)) == nil)
        }
    }

    @Test func aSubagentWorkingAfterTheMainTurnEndedIsWorking() {
        var subagents = running("a")
        #expect(subagents.fromSubagent(.working, reason: "Read", id: "a", current: ObservedState(.done))
            == ObservedState(.working, reason: "Read"))
        #expect(subagents.fromSubagent(.working, reason: "Read", id: "a", current: ObservedState(.exited)) == nil)
    }
}
