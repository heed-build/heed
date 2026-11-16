import Foundation
@testable import HeedCore
import Testing

/// Agents and other programs talking to heed (`Fixtures/inputs/control.json`): control requests, sends, starts, plan
/// approvals, hook messages and Claude Code inbox paths.
struct ControlCorpus: Decodable, Sendable {
    struct Caller: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let method: String
        let session: String?
        let pane: String?
        /// `none`, `s/p` (heed's token for that session and pane), `other-key s/p`, `swapped s/p` (its session
        /// replaced by the request's), or a literal token.
        let token: String
        /// `refused`, `outside`, or the `s/p` heed takes the caller to be.
        let expect: String
        var testDescription: String { name }
    }

    struct Send: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        /// `outside`, or the calling pane's session.
        let caller: String
        let target: String
        let expect: Bool
        var testDescription: String { name }
    }

    struct Start: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let arguments: [String]
        let refused: Bool
        var testDescription: String { name }
    }

    struct StartLine: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let words: [String]
        let refused: Bool
        var testDescription: String { name }
    }

    struct Approval: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let caller: String
        let fromRun: Bool?
        let worker: String?
        let expect: String
        var testDescription: String { name }
    }

    struct Hook: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let session: String
        let pane: String
        let token: String
        let accepted: Bool
        var testDescription: String { name }
    }

    struct Inbox: Decodable, Sendable, CustomTestStringConvertible {
        let path: String
        let accepted: Bool
        var testDescription: String { path.debugDescription }
    }

    let callers: [Caller]
    let sends: [Send]
    let starts: [Start]
    let startLines: [StartLine]
    let approvals: [Approval]
    let hooks: [Hook]
    let inboxes: [Inbox]

    static let loaded: ControlCorpus? = UnusualInputs.cases("control")

    static let keys = SessionKeys.ephemeral()
    static let otherKeys = SessionKeys.ephemeral()

    /// `s/p` as a caller.
    static func caller(_ spec: String) -> SessionCaller {
        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return SessionCaller(session: parts[0], pane: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// The token a spec names (see `Caller.token`); `session` is the request's, for `swapped`.
    static func token(_ spec: String, session: String?) -> String? {
        if spec == "none" { return nil }
        if spec.hasPrefix("other-key ") {
            let who = caller(String(spec.dropFirst(10)))
            return otherKeys.token(session: who.session, pane: who.pane)
        }
        if spec.hasPrefix("swapped ") {
            let who = caller(String(spec.dropFirst(8)))
            var parts = keys.token(session: who.session, pane: who.pane).split(separator: ".").map(String.init)
            let other = keys.token(session: session ?? "s2", pane: who.pane).split(separator: ".").map(String.init)
            parts[0] = other[0]
            return parts.joined(separator: ".")
        }
        if spec.contains("/"), !spec.contains(".") {
            let who = caller(spec)
            return keys.token(session: who.session, pane: who.pane)
        }
        return spec
    }
}

struct UnusualCallerTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    /// heed takes the caller from the token, and refuses a request whose claims the token does not back.
    @Test(arguments: ControlCorpus.loaded?.callers ?? [])
    func callerIsWhoTheTokenSays(_ input: ControlCorpus.Caller) throws {
        let method = try #require(ControlRequest.Method(rawValue: input.method))
        var request = ControlRequest(
            method: method, session: input.session, text: method == .send ? "hi" : nil, pane: input.pane,
            token: ControlCorpus.token(input.token, session: input.session)
        )
        if method == .goal { request.goal = GoalCommand(.show) }
        let result = ControlCaller.of(request, keys: ControlCorpus.keys)
        switch input.expect {
        case "refused":
            #expect(result == nil)
        case "outside":
            #expect(result?.0 == .outside)
            if method != .send { #expect(result?.1.session == nil && result?.1.pane == nil) }
        default:
            let expected = ControlCorpus.caller(input.expect)
            #expect(result?.0 == .pane(expected))
            if method == .send {
                #expect(result?.1.session == input.session)
            } else {
                #expect(result?.1.session == expected.session && result?.1.pane == expected.pane)
            }
        }
    }

    /// A send reaches only the sessions its caller may type into.
    @Test(arguments: ControlCorpus.loaded?.sends ?? [])
    func sendReachesOnlyWhatItMay(_ input: ControlCorpus.Send) {
        let links = [
            GoalLink(goal: "g1", kind: .session, target: "lead", at: at),
            GoalLink(goal: "g1", kind: .session, target: "w1", at: at),
            GoalLink(goal: "g2", kind: .session, target: "w2", at: at),
        ]
        let starters: [String: ControlCaller] = [
            "editor": .outside, "started": .pane(SessionCaller(session: "w2", pane: "p-w2")),
        ]
        let caller: ControlCaller = input.caller == "outside"
            ? .outside : .pane(SessionCaller(session: input.caller, pane: "p-\(input.caller)"))
        #expect(ControlSend.allows(caller, target: input.target, links: links, starters: starters) == input.expect)
    }

    /// A start over the socket never adds words to the agent's command line.
    @Test(arguments: ControlCorpus.loaded?.starts ?? [])
    func startTakesNoArguments(_ input: ControlCorpus.Start) {
        let request = ControlRequest(method: .start, prompt: "go", arguments: input.arguments)
        #expect((ControlStart.refusal(request) != nil) == input.refused)
    }

    @Test(arguments: ControlCorpus.loaded?.startLines ?? [])
    func startLineTakesNoArguments(_ input: ControlCorpus.StartLine) {
        let request = try? ControlCommandLine.parse(input.words, directory: "/tmp")
        #expect((request == nil) == input.refused)
        #expect(request?.arguments == nil)
    }

    /// Approving a plan is the owner's, in heed: from a command line it is held or refused, never applied.
    @Test(arguments: ControlCorpus.loaded?.approvals ?? [])
    func planApprovalIsTheOwners(_ input: ControlCorpus.Approval) async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: at)
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "lead-1", origin: .swarm, at: at))
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "s2", at: at))
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: at)
        try await ops.setLead(swarm: swarm.id, session: "lead-1", now: at)
        var command = GoalCommand(.planApprove, goal: goal.id)
        command.fromRun = input.fromRun
        let caller = input.caller == "outside"
            ? nil : GoalCaller(session: input.caller, title: input.caller, worker: input.worker)
        let outcome = await GoalControl.run(command, caller: caller, ops: ops, files: .fixture, now: at)
        guard case let .reply(reply) = outcome else {
            Issue.record("no reply")
            return
        }
        #expect(reply.outcome == input.expect || (input.expect == "refused" && reply.exit == .refused))
        #expect(reply.exit == (input.expect == "held" ? .waiting : .refused))
        #expect(try await ops.activeSwarm(of: goal.id)?.approved == nil)
    }

    /// A hook message counts only when heed's token vouches for the session and pane it names, as it arrives.
    @Test(arguments: ControlCorpus.loaded?.hooks ?? [])
    func hookMessageNeedsItsToken(_ input: ControlCorpus.Hook) throws {
        let message = HookMessage(
            session: input.session, pane: input.pane, kind: .title("x"),
            token: ControlCorpus.token(input.token, session: input.session)
        )
        let arrived = try HookMessage.decode(line: message.encodedLine())
        #expect(ControlCorpus.keys.verifies(arrived.token, session: arrived.session, pane: arrived.pane)
            == input.accepted)
    }

    /// heed writes to and binds beside a Claude Code inbox only where Claude Code makes them.
    @Test(arguments: ControlCorpus.loaded?.inboxes ?? [])
    func inboxOnlyInClaudeCodesFolders(_ input: ControlCorpus.Inbox) {
        #expect(ClaudeInbox.accepts(input.path) == input.accepted)
        #expect((ClaudeInbox.socket(from: ["CLAUDE_CODE_MESSAGING_SOCKET": input.path]) != nil) == input.accepted)
    }
}

/// A report a branch carries, or one left from an earlier run, is never read as this run's.
struct UnusualRunFolderTests {
    private let report = Data(#"{"summary": "fine", "objections": []}"#.utf8)

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aReportTheBranchCarriesIsNotRead() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("work").path
        let folder = root.appendingPathComponent("run").path
        try FileManager.default.createDirectory(atPath: worktree + "/.heed", withIntermediateDirectories: true)
        let started = Date()
        // The branch's reports are as fresh as the run's own would be: only where heed reads from keeps them out.
        for name in RunFolder.worktreeLeftovers {
            try report.write(to: URL(fileURLWithPath: "\(worktree)/.heed/\(name)"))
        }
        let leftovers = RunFolder.leftovers(in: worktree)
        #expect(leftovers.sorted() == RunFolder.worktreeLeftovers.map { "\(worktree)/.heed/\($0)" }.sorted())
        let carried = try #require(leftovers.first { $0.hasSuffix("/review.json") })
        #expect(ReviewRun.read(file: RunFolder.read(carried, started: started), lastMessage: nil).report != nil)
        try RunFolder.prepare(folder)
        // Where the run's report is read from is the run's folder, never the worktree.
        let path = ReviewRun.reportPath(folder: folder)
        #expect(!path.hasPrefix(worktree) && !leftovers.contains(path))
        #expect(ReviewRun.read(file: RunFolder.read(path, started: started), lastMessage: nil).report == nil)
        // And before the run starts, what the branch carries is gone from the worktree.
        await RunFolder.clearLeftovers(in: worktree, on: .local)
        #expect(leftovers.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func aReportFromBeforeTheRunIsNotRead() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("run").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = ReviewRun.reportPath(folder: folder)
        let message = ReviewRun.lastMessagePath(folder: folder)
        let started = Date()
        let old = started.addingTimeInterval(-3600)
        for file in [path, message] {
            try report.write(to: URL(fileURLWithPath: file))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file)
        }
        // Left in place, an old one is not this run's.
        #expect(RunFolder.read(path, started: started) == nil)
        #expect(RunFolder.readText(message, started: started) == nil)
        // A run's folder starts empty.
        try RunFolder.prepare(folder)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: message))
        // The control: what this run wrote is read.
        try report.write(to: URL(fileURLWithPath: path))
        #expect(ReviewRun.read(file: RunFolder.read(path, started: started), lastMessage: nil).report != nil)
    }
}
