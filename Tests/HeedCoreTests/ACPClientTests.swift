import Foundation
@testable import HeedCore
import Testing

/// A fake agent on the other end of a transport: it answers heed's requests the way `respond` says and can write
/// notifications and requests of its own.
private final class FakeAgent: ACPTransport, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let sink: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var written: [JSONValue] = []
    /// What the agent writes back for one of heed's messages, as JSON lines.
    var respond: @Sendable (JSONValue) -> [String] = { _ in [] }

    init() {
        (lines, sink) = AsyncStream<String>.makeStream()
    }

    var sent: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func send(_ line: String) async throws {
        #expect(!line.contains("\n"), "a message is one line")
        let message = try #require(JSONValue.parse(line))
        lock.withLock { written.append(message) }
        for reply in respond(message) {
            sink.yield(reply)
        }
    }

    func write(_ line: String) { sink.yield(line) }
    func end() { sink.finish() }
    func closedReason() async -> String? { "exit status 1" }
    func close() async { sink.finish() }
}

/// heed's ACP v1 client against a fake agent: requests and answers by id, updates read leniently, permissions asked
/// and answered, requests heed does not serve refused, and an agent that goes away.
struct ACPClientTests {
    private func reply(_ message: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": message["id"] ?? .null, "result": result]).text
    }

    private func update(_ body: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"# + body + "}}"
    }

    @Test func aSessionIsInitializedOpenedAndPrompted() async throws {
        let agent = FakeAgent()
        let update = update
        agent.respond = { [reply] message in
            switch message["method"]?.string {
            case "initialize":
                [reply(message, [
                    "protocolVersion": 1, "agentInfo": ["name": "fake", "title": "Fake Agent", "version": "1.0"],
                    "agentCapabilities": ["loadSession": false],
                ])]
            case "session/new": [reply(message, ["sessionId": "s1"])]
            case "session/prompt":
                [
                    update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixed "}}"#),
                    update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"it."}}"#),
                    reply(message, ["stopReason": "end_turn"]),
                ]
            default: []
            }
        }
        let client = ACPClient(transport: agent)
        await client.start()
        let info = try await client.initialize(clientVersion: "0.42.0")
        #expect(info == ACPAgentInfo(protocolVersion: 1, name: "Fake Agent", version: "1.0"))
        let session = try await client.newSession(cwd: "/tmp/wt")
        #expect(session == "s1")
        var events = client.events.makeAsyncIterator()
        let stop = try await client.prompt(sessionID: session, text: "Fix lint")
        #expect(stop == .endTurn)
        #expect(await events.next() == .update(sessionID: "s1", .agentMessage("Fixed ")))
        #expect(await events.next() == .update(sessionID: "s1", .agentMessage("it.")))

        let sent = agent.sent
        #expect(sent.map { $0["method"]?.string } == ["initialize", "session/new", "session/prompt"])
        #expect(sent.map { $0["id"]?.int } == [0, 1, 2])
        #expect(sent.allSatisfy { $0["jsonrpc"]?.string == "2.0" })
        #expect(sent[0]["params"]?["protocolVersion"]?.int == 1)
        #expect(sent[0]["params"]?["clientCapabilities"]?["fs"]?["writeTextFile"]?.bool == false)
        #expect(sent[0]["params"]?["clientCapabilities"]?["terminal"]?.bool == false)
        #expect(sent[1]["params"] == ["cwd": "/tmp/wt", "mcpServers": []])
        #expect(sent[2]["params"]?["prompt"] == [["type": "text", "text": "Fix lint"]])
    }

    @Test func anotherProtocolVersionIsRefused() async throws {
        let agent = FakeAgent()
        agent.respond = { [reply] message in [reply(message, ["protocolVersion": 2])] }
        let client = ACPClient(transport: agent)
        await client.start()
        await #expect(throws: ACPError.protocolVersion(2)) { try await client.initialize(clientVersion: "x") }
    }

    @Test func anErrorAnswerIsThrownWithItsMessage() async throws {
        let agent = FakeAgent()
        agent.respond = { message in
            [JSONValue.object([
                "jsonrpc": "2.0", "id": message["id"]!, "error": ["code": -32000, "message": "Authentication required"],
            ]).text]
        }
        let client = ACPClient(transport: agent)
        await client.start()
        await #expect(throws: ACPError.rpc(code: -32000, message: "Authentication required")) {
            try await client.newSession(cwd: "/tmp")
        }
    }

    @Test func updatesAreReadLeniently() throws {
        let plan = try #require(JSONValue.parse(#"""
        {"sessionUpdate":"plan","entries":[
          {"content":"Read the failing lint log","priority":"high","status":"completed"},
          {"content":"Add a test","priority":"medium","status":"in_progress"},
          {"content":"Push","priority":"low","status":"unheard-of"},
          {"priority":"low","status":"pending"}]}
        """#))
        #expect(ACPUpdate(plan) == .plan([
            ACPPlanEntry(content: "Read the failing lint log", status: .completed),
            ACPPlanEntry(content: "Add a test", status: .inProgress),
            ACPPlanEntry(content: "Push", status: .pending),
        ]))
        let call = try #require(JSONValue.parse(#"""
        {"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit Redirects.cs","kind":"edit","status":"pending",
         "locations":[{"path":"src/Redirects.cs","line":88}],
         "content":[{"type":"diff","path":"src/Redirects.cs","oldText":"a\nb","newText":"a\nc"},
                    {"type":"content","content":{"type":"text","text":"ok"}},{"type":"terminal","terminalId":"x"},
                    {"type":"unknown"}],
         "rawInput":{"command":"dotnet test"}}
        """#))
        #expect(ACPUpdate(call) == .toolCall(ACPToolCall(
            id: "t1", title: "Edit Redirects.cs", kind: .edit, status: .pending,
            content: [.diff(path: "src/Redirects.cs", oldText: "a\nb", newText: "a\nc"), .text("ok"), .terminal("x")],
            paths: ["src/Redirects.cs"], command: "dotnet test"
        )))
        let progress = try #require(JSONValue.parse(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","kind":7}"#
        ))
        #expect(ACPUpdate(progress) == .toolCallUpdate(ACPToolCall(id: "t1", status: .completed)))
        let usage = try #require(JSONValue.parse(
            #"{"sessionUpdate":"usage_update","used":12400,"size":200000,"cost":{"amount":0.04,"currency":"USD"}}"#
        ))
        #expect(ACPUpdate(usage) == .usage(used: 12400, size: 200_000, cost: 0.04, currency: "USD"))
        let mode = try #require(JSONValue.parse(#"{"sessionUpdate":"current_mode_update","currentModeId":"x"}"#))
        #expect(ACPUpdate(mode) == .other("current_mode_update"))
        #expect(ACPUpdate(["content": "x"]) == nil)
    }

    @Test func aPermissionIsAskedAndAnswered() async throws {
        let agent = FakeAgent()
        let client = ACPClient(transport: agent)
        await client.start()
        var events = client.events.makeAsyncIterator()
        agent.write(#"""
        {"jsonrpc":"2.0","id":"p-7","method":"session/request_permission","params":{"sessionId":"s1",
        "toolCall":{"toolCallId":"t2","title":"Run dotnet test","kind":"execute","rawInput":{"command":"dotnet test"}},
        "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},
                   {"optionId":"always","name":"Always","kind":"allow_always"},
                   {"optionId":"no","name":"Deny","kind":"reject_once"}]}}
        """#.replacingOccurrences(of: "\n", with: ""))
        guard case let .permission(id, session, request) = await events.next() else {
            Issue.record("no permission event")
            return
        }
        #expect(id == "p-7" && session == "s1")
        #expect(request.toolCall.command == "dotnet test")
        #expect(request.option(.allowAlways)?.id == "always")
        await client.answerPermission(id, optionID: "allow")
        await client.answerPermission(id, optionID: nil)
        let answers = agent.sent
        #expect(answers.count == 2)
        #expect(answers[0]["id"] == "p-7")
        #expect(answers[0]["result"] == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        #expect(answers[1]["result"] == ["outcome": ["outcome": "cancelled"]])
    }

    @Test func requestsHeedDoesNotServeAreRefusedAndCancelIsANotification() async throws {
        let agent = FakeAgent()
        let client = ACPClient(transport: agent)
        await client.start()
        agent.write(#"{"jsonrpc":"2.0","id":3,"method":"fs/read_text_file","params":{"path":"/etc/hosts"}}"#)
        await client.cancel(sessionID: "s1")
        try await Task.sleep(for: .milliseconds(50))
        let sent = agent.sent
        let refusal = try #require(sent.first { $0["error"] != nil })
        #expect(refusal["id"]?.int == 3 && refusal["error"]?["code"]?.int == -32601)
        let cancel = try #require(sent.first { $0["method"]?.string == "session/cancel" })
        #expect(cancel["id"] == nil && cancel["params"] == ["sessionId": "s1"])
    }

    @Test func anAgentThatGoesAwayFailsWhatWaitsAndSaysWhy() async throws {
        let agent = FakeAgent()
        let client = ACPClient(transport: agent)
        await client.start()
        var events = client.events.makeAsyncIterator()
        let answer = Task { try await client.newSession(cwd: "/tmp") }
        try await Task.sleep(for: .milliseconds(30))
        agent.end()
        await #expect(throws: ACPError.closed("exit status 1")) { try await answer.value }
        #expect(await events.next() == .closed("exit status 1"))
        #expect(await events.next() == nil)
        await #expect(throws: ACPError.closed("exit status 1")) { try await client.newSession(cwd: "/tmp") }
    }

    @Test func aRequestTimesOut() async throws {
        let client = ACPClient(transport: FakeAgent())
        await client.start()
        await #expect(throws: ACPError.timedOut("initialize")) {
            try await client.initialize(clientVersion: "x", timeout: .milliseconds(50))
        }
    }

    @Test func jsonIsWrittenOnOneLineAndReadBack() throws {
        let value: JSONValue = ["text": "a \"quoted\"\nline\twith\u{1} control", "n": 3, "f": .number(0.5), "b": true]
        #expect(!value.text.contains("\n"))
        #expect(JSONValue.parse(value.text) == value)
        #expect(JSONValue.parse("not json") == nil)
    }
}

/// The same client over a real process: a shell script that speaks just enough ACP, answering in order.
struct ACPProcessTests {
    @Test func aRealProcessIsSpokenToOverItsStdio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heed-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-agent")
        // Reads a line per request and answers it by its known id (heed numbers requests from 0); notes on stderr.
        try """
        #!/bin/sh
        read -r line
        echo "starting" >&2
        echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-sh"}}}'
        read -r line
        echo '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"sh-1"}}'
        read -r line
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sh-1","update":{"sessionUpdate":"plan","entries":[{"content":"Look","priority":"high","status":"in_progress"}]}}}'
        printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
        echo
        echo "bye" >&2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let transport = try ACPProcessTransport(
            executable: script.path, arguments: [], directory: directory.path, environment: ["PATH": "/usr/bin:/bin"]
        )
        let client = ACPClient(transport: transport)
        await client.start()
        var events = client.events.makeAsyncIterator()
        #expect(try await client.initialize(clientVersion: "t").name == "fake-sh")
        let session = try await client.newSession(cwd: directory.path)
        #expect(try await client.prompt(sessionID: session, text: "go") == .endTurn)
        #expect(await events.next() == .update(
            sessionID: "sh-1", .plan([ACPPlanEntry(content: "Look", status: .inProgress)])
        ))
        // The script ends: the stream closes, saying what it last wrote on stderr.
        guard case let .closed(reason) = await events.next() else {
            Issue.record("not closed")
            return
        }
        #expect(reason?.contains("bye") == true)
    }
}
