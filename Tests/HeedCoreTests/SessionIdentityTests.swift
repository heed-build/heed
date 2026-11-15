import Foundation
@testable import HeedCore
import Testing

/// A process speaks for the pane heed started it in, and no other: the pane's token says which session and pane it is,
/// and every hook message and control request is taken from that, not from what it claims.
struct SessionTokenTests {
    let keys = SessionKeys.ephemeral()

    @Test func aTokenNamesItsSessionAndPane() {
        let token = keys.token(session: "s1", pane: "p1")
        #expect(keys.caller(token) == SessionCaller(session: "s1", pane: "p1"))
        #expect(keys.verifies(token, session: "s1", pane: "p1"))
        // Any other session or pane, or none, is not this token's.
        #expect(!keys.verifies(token, session: "s2", pane: "p1"))
        #expect(!keys.verifies(token, session: "s1", pane: "p2"))
        #expect(!keys.verifies(token, session: "s1", pane: nil))
        #expect(!keys.verifies(nil, session: "s1", pane: "p1"))
        // Session ids with dots and odd characters still round-trip.
        let odd = keys.token(session: "a.b/c+d", pane: nil)
        #expect(keys.caller(odd) == SessionCaller(session: "a.b/c+d", pane: nil))
    }

    @Test func onlyHeedsKeyMakesATokenHeedTakes() {
        let token = keys.token(session: "s1", pane: "p1")
        #expect(SessionKeys.ephemeral().caller(token) == nil)
        // Its names changed, its signature kept: not heed's.
        let parts = token.split(separator: ".").map(String.init)
        let other = keys.token(session: "s2", pane: "p1").split(separator: ".").map(String.init)
        #expect(keys.caller([other[0], parts[1], parts[2]].joined(separator: ".")) == nil)
        #expect(keys.caller(parts[0] + "." + parts[1] + ".AAAA") == nil)
        #expect(keys.caller("") == nil)
        #expect(keys.caller("s1") == nil)
    }

    @Test func theKeyIsKeptAndReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.key")
        let first = try SessionKeys.load(from: file)
        let token = first.token(session: "s1", pane: "p1")
        // A heed started again knows the panes it started before.
        #expect(try SessionKeys.load(from: file).verifies(token, session: "s1", pane: "p1"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try Data(contentsOf: file).count == 32)
    }
}

struct ControlCallerTests {
    let keys = SessionKeys.ephemeral()

    private func goal(session: String?, pane: String?, token: String?) -> ControlRequest {
        ControlRequest(method: .goal, session: session, goal: GoalCommand(.show), pane: pane, token: token)
    }

    @Test func aPaneIsWhoItsTokenSays() throws {
        let token = keys.token(session: "lead", pane: "worker-pane")
        let (caller, request) = try #require(ControlCaller.of(
            goal(session: "lead", pane: "worker-pane", token: token), keys: keys
        ))
        #expect(caller == .pane(SessionCaller(session: "lead", pane: "worker-pane")))
        #expect(request.session == "lead" && request.pane == "worker-pane")
        // A worker that leaves out its pane is still the worker, not the lead.
        let (_, bare) = try #require(ControlCaller.of(goal(session: "lead", pane: nil, token: token), keys: keys))
        #expect(bare.pane == "worker-pane")
    }

    @Test func aClaimTheTokenDoesNotBackIsRefused() {
        let token = keys.token(session: "s1", pane: "p1")
        #expect(ControlCaller.of(goal(session: "s2", pane: "p1", token: token), keys: keys) == nil)
        #expect(ControlCaller.of(goal(session: "s1", pane: "p9", token: token), keys: keys) == nil)
        // A session named without any token: someone setting HEED_SESSION_ID by hand.
        #expect(ControlCaller.of(goal(session: "s1", pane: "p1", token: nil), keys: keys) == nil)
        #expect(ControlCaller.of(goal(session: "s1", pane: "p1", token: "made.up.token"), keys: keys) == nil)
        let memory = ControlRequest(method: .memory, session: "s1", arguments: ["note", "x"])
        #expect(ControlCaller.of(memory, keys: keys) == nil)
        let ask = PermissionAsk(id: "a1", session: "s1", agent: "claude", tool: "Bash", askedAt: Date())
        #expect(ControlCaller
            .of(ControlRequest(method: .permission, session: "s1", permission: ask), keys: keys) == nil)
    }

    @Test func noTokenAndNoSessionIsOutside() throws {
        let (caller, request) = try #require(ControlCaller.of(goal(session: nil, pane: "p1", token: nil), keys: keys))
        #expect(caller == .outside)
        #expect(request.pane == nil)
        let send = ControlRequest(method: .send, session: "target", text: "hi")
        #expect(ControlCaller.of(send, keys: keys)?.0 == .outside)
    }

    @Test func aSendsSessionIsItsTargetAndTheTokenItsSender() throws {
        let token = keys.token(session: "s1", pane: "p1")
        let send = ControlRequest(method: .send, session: "s2", text: "hi", token: token)
        let (caller, request) = try #require(ControlCaller.of(send, keys: keys))
        #expect(caller.session == "s1")
        #expect(request.session == "s2")
        #expect(ControlCaller.of(ControlRequest(method: .send, session: "s2", token: "x.y.z"), keys: keys) == nil)
    }
}

struct ControlSendTests {
    let at = Date(timeIntervalSince1970: 0)

    private func pane(_ session: String) -> ControlCaller {
        .pane(SessionCaller(session: session, pane: "p-\(session)"))
    }

    @Test func aPaneReachesItsOwnSessionItsGoalsAndWhatItStarted() {
        let links = [
            GoalLink(goal: "g1", kind: .session, target: "lead", at: at),
            GoalLink(goal: "g1", kind: .chat, target: "helper", at: at),
            GoalLink(goal: "g2", kind: .session, target: "elsewhere", at: at),
            GoalLink(goal: "g1", kind: .pr, target: "o/r#1", at: at),
        ]
        let starters: [String: ControlCaller] = ["started": pane("lead")]
        func allows(_ caller: ControlCaller, _ target: String) -> Bool {
            ControlSend.allows(caller, target: target, links: links, starters: starters)
        }
        #expect(allows(pane("lead"), "lead"))
        #expect(allows(pane("lead"), "helper"))
        #expect(allows(pane("helper"), "lead"))
        #expect(allows(pane("lead"), "started"))
        #expect(!allows(pane("lead"), "elsewhere"))
        #expect(!allows(pane("loner"), "lead"))
        #expect(!allows(pane("loner"), "started"))
        #expect(!allows(pane("lead"), "o/r#1"))
    }

    @Test func fromOutsideOnlyWhatWasStartedFromOutside() {
        let starters: [String: ControlCaller] = ["editor": .outside, "byPane": pane("s1")]
        #expect(ControlSend.allows(.outside, target: "editor", links: [], starters: starters))
        #expect(!ControlSend.allows(.outside, target: "byPane", links: [], starters: starters))
        #expect(!ControlSend.allows(.outside, target: "any", links: [], starters: starters))
    }
}

/// What the command line puts in its requests: the pane's token, and no words for the agent's command line.
struct ControlCommandLineIdentityTests {
    @Test func requestsCarryThePanesToken() throws {
        let environment = [
            HeedEnvironment.sessionID: "s1", HeedEnvironment.pane: "p1", HeedEnvironment.token: "t.o.k",
        ]
        #expect(try ControlCommandLine.parse(["send", "s2", "hi"], directory: "/", environment: environment).token
            == "t.o.k")
        #expect(try ControlCommandLine.parse(["send", "s2", "hi"], directory: "/").token == nil)
        let goal = try GoalCommandLine.request(["goal", "show"], environment: environment)
        #expect(goal.token == "t.o.k" && goal.session == "s1" && goal.pane == "p1")
        let memory = try MemoryCommandLine.request(["memory", "note", "x"], environment: environment)
        #expect(memory.token == "t.o.k" && memory.pane == "p1")
    }

    @Test func startTakesNoAgentArguments() throws {
        #expect(throws: HookCommandLine.UsageError.self) {
            try ControlCommandLine.parse(["start", "--arg", "--yolo", "go"], directory: "/tmp")
        }
        #expect(try ControlCommandLine.parse(["start", "go"], directory: "/tmp").arguments == nil)
        #expect(!ControlCommandLine.usage.contains("--arg"))
        // Over the socket too.
        #expect(ControlStart.refusal(ControlRequest(method: .start, prompt: "go", arguments: ["--yolo"])) != nil)
        #expect(ControlStart.refusal(ControlRequest(method: .start, prompt: "go")) == nil)
    }

    @Test func hookMessagesKeepTheirToken() throws {
        let message = HookMessage(session: "s1", pane: "p1", kind: .title("x"), token: "t.o.k")
        #expect(try HookMessage.decode(line: message.encodedLine()).token == "t.o.k")
    }

    @Test func aPermissionAskCarriesThePanesToken() async throws {
        let path = "/tmp/heed-token-\(UUID().uuidString.prefix(8)).sock"
        let seen = LockedBox<String?>(nil)
        let server = ControlServer(path: path) { request in
            seen.set(request.token)
            return ControlReply(permission: .pass, permissionID: request.permission?.id)
        }
        try server.start()
        defer { server.stop() }
        let ask = PermissionAsk(id: "a1", session: "s1", pane: "p1", agent: "claude", tool: "Bash", askedAt: Date())
        _ = await Task.detached { PermissionHook.exchange(ask, token: "t.o.k", socket: path, ceiling: 2) }.value
        #expect(seen.get() == "t.o.k")
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.withLock { value = new } }
    func get() -> Value { lock.withLock { value } }
}

/// On a host the token rides with each line of the event log.
struct HostTokenTests {
    private func line(_ args: [String], token: String?) -> String {
        let encoded = args.map { Data($0.utf8).base64EncodedString() + " " }.joined()
        return "1700000000\ts1\tp1\t\(encoded)\t" + (token.map { "\t\($0)" } ?? "")
    }

    @Test func eventsAndCallsKeepTheirToken() throws {
        let messages = HostEvents.messages(fromLine: line(["state", "working"], token: "t.o.k"))
        #expect(messages.first?.token == "t.o.k")
        #expect(HostEvents.messages(fromLine: line(["state", "working"], token: nil)).first?.token == nil)
        let call = try #require(HostCall(line: line(["call", "1-2", "", "goal", "show"], token: "t.o.k")))
        #expect(call.token == "t.o.k")
    }

    @Test func aRemotePaneGetsItsToken() {
        let command = RemotePane.command(
            host: "box", pane: "p1", directory: "~/x", sessionID: "s1", token: "t.o.k", zmx: nil
        )
        #expect(command.contains("HEED_SESSION_TOKEN="))
        #expect(command.contains("t.o.k"))
    }
}
