import Foundation
@testable import HeedCore
import Testing

struct DeliveryRouteTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let claude = AgentInbox.claude(socket: "/tmp/cc-socks/1.sock")
    let codex = AgentInbox.codex(thread: "t1")

    @Test func anInboxTakesItWhileTheAgentWorksOrAsks() {
        for state in [AgentState.working, .blocked, .asking, .limited, .idle, .done] {
            #expect(Delivery.route(
                state: state, lastTyped: nil, inbox: claude, settings: ChannelSettings(), now: now
            ) == .channel(claude))
        }
    }

    @Test func anInboxNeedsNoTypingGraceButALongOneHolds() {
        let typed = now.addingTimeInterval(-5)
        #expect(Delivery.route(
            state: .idle, lastTyped: typed, inbox: claude, settings: ChannelSettings(), now: now
        ) == .channel(claude))
        let held = Delivery.route(
            state: .idle, lastTyped: typed, inbox: claude, settings: ChannelSettings(), now: now, typingGrace: 300
        )
        #expect(held == .wait("you're working in it (sends \(PilotDuration.text(300)) after your last keystroke)"))
    }

    @Test func withoutAChannelTheVerdictDecides() {
        #expect(Delivery.route(state: .idle, lastTyped: nil, inbox: nil, settings: ChannelSettings(), now: now)
            == .type)
        #expect(Delivery.route(state: .working, lastTyped: nil, inbox: nil, settings: ChannelSettings(), now: now)
            == .wait("the agent is working"))
        // An exited agent has no inbox to speak of.
        #expect(Delivery.route(state: .exited, lastTyped: nil, inbox: claude, settings: ChannelSettings(), now: now)
            == .wait("the agent has exited"))
    }

    @Test func settingsChooseTheChannels() {
        // codex's queue is off until you turn it on; Claude's inbox can be turned off.
        #expect(Delivery.route(state: .working, lastTyped: nil, inbox: codex, settings: ChannelSettings(), now: now)
            == .wait("the agent is working"))
        #expect(Delivery.route(
            state: .working, lastTyped: nil, inbox: codex, settings: ChannelSettings(codexQueue: true), now: now
        ) == .channel(codex))
        #expect(Delivery.route(
            state: .idle, lastTyped: nil, inbox: claude, settings: ChannelSettings(claudeInbox: false), now: now
        ) == .type)
    }

    @Test func aRefusedOrDeadChannelFallsBackToTypingWhenItMay() {
        let refused = Delivery.resolve(.refused("no"), via: claude, state: .idle, lastTyped: nil, now: now)
        #expect(refused.outcome == .typed(fallback: "Claude's inbox: no"))
        #expect(refused.typeNow && refused.forget)
        let dead = Delivery.resolve(.unreachable("gone"), via: claude, state: .working, lastTyped: nil, now: now)
        #expect(dead.outcome == .waiting("the agent is working; Claude's inbox: gone"))
        #expect(!dead.typeNow && dead.forget)
        #expect(!dead.outcome.sent)
    }

    @Test func acceptedAndQueuedAreSent() {
        let accepted = Delivery.resolve(.accepted, via: claude, state: .working, lastTyped: nil, now: now)
        #expect(accepted.outcome == .delivered(.claudeInbox) && !accepted.typeNow && !accepted.forget)
        let queued = Delivery.resolve(.queued("held"), via: codex, state: .working, lastTyped: nil, now: now)
        #expect(queued.outcome == .queued(.codexQueue, "held") && queued.outcome.sent)
    }

    @Test func outcomesSayHowItWent() {
        #expect(DeliveryOutcome.typed(fallback: nil).target("claude") == "claude")
        #expect(DeliveryOutcome.delivered(.claudeInbox).target("claude") == "claude, through Claude's inbox")
        #expect(DeliveryOutcome.typed(fallback: "Claude's inbox: no")
            .summary == "typed into its pane (Claude's inbox: no)")
        #expect(DeliveryOutcome.waiting("busy").why == "busy")
        #expect(DeliveryOutcome.delivered(.claudeInbox).why == nil)
    }
}

struct ClaudeInboxWireTests {
    @Test func theLineIsAPeerMessageFromHeedWithAReplyAddress() throws {
        let line = ClaudeInbox.line("fix the tests", replyTo: "/tmp/cc-socks/heed-9.sock")
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(object["type"] as? String == "user")
        #expect(object["from"] as? String == "uds:/tmp/cc-socks/heed-9.sock")
        let message = try #require(object["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["content"] as? String == ClaudeInbox.prefix + "fix the tests")
    }

    @Test func receiptsSayHeldRefusedOrNothing() {
        let held = Data(
            #"{"type":"control","action":"peer_message_status","status":"held","reason":"…","from":"uds:/tmp/cc-socks/7.sock","msgV":1}"#
                .utf8
        )
        #expect(ClaudeInbox.receipt(held)?.socket == "/tmp/cc-socks/7.sock")
        #expect(ClaudeInbox.receipt(held)?.result == .queued("held for your approval in the session"))
        let refused = Data(
            #"{"type":"control","action":"peer_message_status","status":"expired","status_detail":"refused","from":"uds:/tmp/cc-socks/7.sock"}"#
                .utf8
        )
        #expect(ClaudeInbox.receipt(refused)?.result == .refused("the session refuses messages from other sessions"))
        let reply = Data(#"{"type":"user","message":{"role":"user","content":"thanks"}}"#.utf8)
        #expect(ClaudeInbox.receipt(reply) == nil)
    }

    @Test func theReplySocketSitsBesideTheInbox() {
        #expect(ClaudeInbox.replySocket(beside: "/tmp/cc-socks/42.sock", pid: 7) == "/tmp/cc-socks/heed-7.sock")
        let deep = "/" + String(repeating: "d", count: 100) + "/1.sock"
        #expect(ClaudeInbox.replySocket(beside: deep, pid: 7) == nil)
    }

    @Test func theHookSaysWhereTheInboxIs() throws {
        let environment = ["CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/5.sock"]
        #expect(AgentIntegration.claudeInbox(event: "SessionStart", environment: environment)
            == [.inbox(socket: "/tmp/cc-socks/5.sock")])
        #expect(AgentIntegration.claudeInbox(event: "PreToolUse", environment: environment).isEmpty)
        // heed's panes set it empty: an inbox inherited from elsewhere is never taken for the pane's.
        #expect(AgentIntegration.claudeInbox(
            event: "SessionStart", environment: ["CLAUDE_CODE_MESSAGING_SOCKET": ""]
        ).isEmpty)
        let kinds = try HookCommandLine.parse(["hook", "claude", "Stop"], environment: environment) { Data("{}".utf8) }
        #expect(kinds.contains(.inbox(socket: "/tmp/cc-socks/5.sock")))
        // A hook relayed from a host has no environment: no inbox.
        let relayed = try HookCommandLine.parse(["hook", "claude", "Stop"]) { Data("{}".utf8) }
        #expect(!relayed.contains { if case .inbox = $0 { true } else { false } })
    }

    @Test func configTurnsTheChannelsOnAndOff() {
        let (decoded, problems) = ConfigLoader.decode("""
        [sessions]
        claude_inbox = false
        codex_queue = true
        """)
        #expect(problems.isEmpty)
        #expect(decoded?.work.channels == ChannelSettings(claudeInbox: false, codexQueue: true))
        #expect(ConfigLoader.decode("").0?.work.channels == ChannelSettings())
    }
}

/// A transport whose sockets and codex are scripted.
final class FakeTransport: ChannelTransport, @unchecked Sendable {
    let lock = NSLock()
    var written: [(Data, String)] = []
    var writeSucceeds = true
    /// Receipts sent as soon as a line is written (before `write` returns), keyed by inbox socket.
    var receiptOnWrite: [String: Data] = [:]
    var codex: ProcessResult?
    var codexCalls: [(String, String)] = []
    let receipts: AsyncStream<Data>
    let continuation: AsyncStream<Data>.Continuation

    init() { (receipts, continuation) = AsyncStream.makeStream() }

    func write(_ line: Data, to socket: String) async -> Bool {
        let (ok, receipt) = lock.withLock {
            written.append((line, socket))
            return (writeSucceeds, receiptOnWrite[socket])
        }
        if ok, let receipt { continuation.yield(receipt) }
        if receipt != nil { try? await Task.sleep(for: .milliseconds(50)) }
        return ok
    }

    func listen(at _: String) async -> Bool { true }

    func codexQueue(thread: String, text: String) async -> ProcessResult? {
        lock.withLock { codexCalls.append((thread, text)) }
        return codex
    }

    static func held(_ socket: String) -> Data {
        Data(#"{"type":"control","action":"peer_message_status","status":"held","from":"uds:\#(socket)"}"#.utf8)
    }
}

struct AgentChannelsTests {
    let socket = "/tmp/cc-socks/11.sock"

    @Test func silenceMeansClaudeTookIt() async {
        let fake = FakeTransport()
        let channels = AgentChannels(transport: fake, receiptWindow: .milliseconds(50))
        #expect(await channels.send("hi", to: .claude(socket: socket)) == .accepted)
        #expect(fake.written.count == 1 && fake.written[0].1 == socket)
    }

    @Test func aHeldReceiptMeansQueuedEvenWhenItBeatsTheWrite() async {
        let fake = FakeTransport()
        fake.receiptOnWrite[socket] = FakeTransport.held(socket)
        let channels = AgentChannels(transport: fake, receiptWindow: .seconds(2))
        #expect(await channels.send("hi", to: .claude(socket: socket))
            == .queued("held for your approval in the session"))
    }

    @Test func noInboxListeningIsUnreachable() async {
        let fake = FakeTransport()
        fake.writeSucceeds = false
        let channels = AgentChannels(transport: fake, receiptWindow: .milliseconds(50))
        #expect(await channels.send("hi", to: .claude(socket: socket)) == .unreachable("nothing answers at its inbox"))
    }

    @Test func aReceiptWithNothingWaitingIsLate() async {
        let fake = FakeTransport()
        let channels = AgentChannels(transport: fake, receiptWindow: .milliseconds(20))
        #expect(await channels.send("hi", to: .claude(socket: socket)) == .accepted)
        fake.continuation.yield(FakeTransport.held(socket))
        var late = channels.lateResults.makeAsyncIterator()
        let next = await late.next()
        #expect(next?.socket == socket)
        #expect(next?.result == .queued("held for your approval in the session"))
    }

    @Test func codexQueuesOrSaysWhyNot() async {
        let fake = FakeTransport()
        let channels = AgentChannels(transport: fake)
        fake.codex = ProcessResult(status: 0, stdout: "queued", stderr: "")
        #expect(await channels.send("go", to: .codex(thread: "t1")) == .queued("waiting in its thread's queue"))
        #expect(fake.codexCalls.first?.0 == "t1" && fake.codexCalls.first?.1 == "go")
        fake.codex = ProcessResult(status: 1, stdout: "", stderr: "no such thread\nmore")
        #expect(await channels.send("go", to: .codex(thread: "t1")) == .unreachable("no such thread"))
        fake.codex = nil
        #expect(await channels.send("go", to: .codex(thread: "t1")) == .unreachable("codex could not be run"))
    }
}

/// The real sockets against a fake Claude inbox: it reads heed's line and, when told to, sends a receipt back to the
/// line's reply address, as Claude Code does.
struct ClaudeInboxSocketTests {
    final class FakeInbox: @unchecked Sendable {
        let path: String
        let lock = NSLock()
        var lines: [Data] = []
        var listener: LineListener?

        init(directory: String, hold: Bool) throws {
            path = (directory as NSString).appendingPathComponent("1.sock")
            let path = path
            let listener = LineListener(path: path) { [weak self] line in
                self?.lock.withLock { self?.lines.append(line) }
                guard hold, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let from = object["from"] as? String, from.hasPrefix("uds:")
                else { return }
                var receipt = FakeTransport.held(path)
                receipt.append(0x0A)
                _ = UnixLine.write(receipt, to: String(from.dropFirst(4)))
            }
            try listener.start()
            self.listener = listener
        }
    }

    static func directory() throws -> String {
        let path = "/tmp/heed-inbox-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func aRealInboxGetsTheLineAndItsReceiptComesBack() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let inbox = try FakeInbox(directory: directory, hold: true)
        let channels = AgentChannels(transport: LiveChannelTransport(), receiptWindow: .seconds(2))
        let result = await channels.send("rebase on main", to: .claude(socket: inbox.path))
        #expect(result == .queued("held for your approval in the session"))
        let line = try #require(inbox.lock.withLock { inbox.lines.first })
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect((object["message"] as? [String: Any])?["content"] as? String == ClaudeInbox.prefix + "rebase on main")
        #expect(object["from"] as? String == "uds:" + (ClaudeInbox.replySocket(beside: inbox.path) ?? ""))
        inbox.listener?.stop()
    }

    @Test func aQuietInboxTookItAndAMissingOneIsUnreachable() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let inbox = try FakeInbox(directory: directory, hold: false)
        let channels = AgentChannels(transport: LiveChannelTransport(), receiptWindow: .milliseconds(200))
        #expect(await channels.send("hello", to: .claude(socket: inbox.path)) == .accepted)
        inbox.listener?.stop()
        #expect(await channels.send("hello", to: .claude(socket: inbox.path))
            == .unreachable("nothing answers at its inbox"))
    }
}
