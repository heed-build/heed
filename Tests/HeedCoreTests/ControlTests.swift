import Foundation
@testable import HeedCore
import Testing

struct ControlTests {
    private static func path() -> String { "/tmp/heed-control-\(UUID().uuidString.prefix(8)).sock" }

    private static let sample = ControlSession(
        id: "s1", title: "Fix the build", agent: "claude", state: "asking", needsYou: true, group: "Needs you",
        directory: "/tmp/x", lastActivity: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test func repliesCarryTheRequestsID() async throws {
        let path = Self.path()
        let server = ControlServer(path: path) { request in
            switch request.method {
            case .sessions: ControlReply(sessions: [Self.sample])
            case .start: ControlReply(session: "new-\(request.prompt ?? "")")
            default: .failure("no")
            }
        }
        try server.start()
        defer { server.stop() }

        let reply = try await Task.detached {
            let client = try ControlClient(path: path)
            let sessions = try client.call(ControlRequest(method: .sessions))
            let started = try client.call(ControlRequest(method: .start, directory: "/tmp", prompt: "go"))
            let refused = try client.call(ControlRequest(method: .send, session: "s1", text: "hi"))
            return (sessions, started, refused)
        }.value
        #expect(reply.0.sessions == [Self.sample])
        #expect(reply.0.id == 1)
        #expect(reply.1.session == "new-go")
        #expect(reply.1.id == 2)
        #expect(reply.2.ok == false)
        #expect(reply.2.error == "no")
        #expect(throws: HookServerError.self) { try ControlServer(path: path) { _ in ControlReply() }.start() }
    }

    @Test func watchersGetTheListWhenItChanges() async throws {
        let path = Self.path()
        let server = ControlServer(path: path) { _ in ControlReply(sessions: [Self.sample]) }
        try server.start()
        defer { server.stop() }

        var changed = Self.sample
        changed.state = "working"
        changed.needsYou = false
        let next = changed
        let events = try await Task.detached {
            let client = try ControlClient(path: path)
            let first = try client.call(ControlRequest(method: .watch))
            // The same list again is not news; the changed one is.
            server.publish([Self.sample])
            server.publish([next])
            return try (first, client.next())
        }.value
        #expect(events.0.sessions == [Self.sample])
        #expect(events.1.event == "sessions")
        #expect(events.1.sessions == [changed])
    }

    @Test func badLinesAreAnsweredNotFatal() async throws {
        let path = Self.path()
        let server = ControlServer(path: path) { _ in ControlReply(sessions: []) }
        try server.start()
        defer { server.stop() }
        let replies = try await Task.detached {
            let client = try ControlClient(path: path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = HookServer.address(path)
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            defer { close(fd) }
            let garbage = Data("{\"method\":\"explode\"}\n".utf8)
            _ = garbage.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            let answer = try ControlCoding.decode(ControlReply.self, line: Data(buffer[0 ..< max(count - 1, 0)]))
            return try (answer, client.call(ControlRequest(method: .sessions)))
        }.value
        #expect(replies.0.ok == false)
        #expect(replies.0.error?.hasPrefix("not a request") == true)
        #expect(replies.1.ok)
    }

    @Test func commandLines() throws {
        let start = try ControlCommandLine.parse(
            ["start", "--agent", "codex", "fix", "the", "build", "--focus"], directory: "/w"
        )
        #expect(start == ControlRequest(
            method: .start, directory: "/w", agent: "codex", prompt: "fix the build", focus: true
        ))
        #expect(try ControlCommandLine.parse(["start", "--dir", "/x", "go"], directory: "/w").directory == "/x")
        let send = try ControlCommandLine.parse(["send", "s1", "look", "again"], directory: "/w")
        #expect(send.session == "s1")
        #expect(send.text == "look again")
        #expect(try ControlCommandLine.parse(["show", "--focus", "s1"], directory: "/w").focus == true)
        #expect(throws: HookCommandLine.UsageError.self) {
            try ControlCommandLine.parse(["send", "s1"], directory: "/w")
        }
        #expect(throws: HookCommandLine.UsageError.self) {
            try ControlCommandLine.parse(["start", "--agent"], directory: "/w")
        }
    }

    @Test func aSessionIsDescribedByItsOwnFields() {
        var session = Session(
            title: "Fix", prompt: "Fix it", repos: [Repo(org: "o", name: "r")], branch: "fix/it", agent: "claude",
            state: ObservedState(.blocked, reason: "Bash"), lastActivity: Date(timeIntervalSince1970: 0)
        )
        session.worktreePaths = ["/w/r"]
        let described = ControlSession(session, needsYou: true, group: .needsYou)
        #expect(described.state == "blocked")
        #expect(described.reason == "Bash")
        #expect(described.repo == "o/r")
        #expect(described.branch == "fix/it")
        #expect(described.directory == "/w/r")
        #expect(described.group == "Needs you")
    }

    @Test func importStartsTheAgentOnAPrompt() throws {
        let worktree = Worktree(
            repo: Repo(org: "o", name: "r"), path: "/w/r", branch: "main", head: "abc", isMain: true
        )
        let changes = Import.session(
            for: worktree, agent: AgentProfile(name: "claude", command: "claude"), resume: nil, integration: nil,
            prompt: "Fix the build"
        )
        guard case let .sessionUpserted(session) = changes.first else {
            Issue.record("no session")
            return
        }
        #expect(session.title == "Fix the build")
        #expect(session.prompt == "Fix the build")
        guard case let .layoutChanged(_, layout) = changes.last else {
            Issue.record("no layout")
            return
        }
        let command = try #require(layout.tabs.first?.tree.panes.first?.command)
        #expect("\(command)".contains("Fix the build"))
    }
}
