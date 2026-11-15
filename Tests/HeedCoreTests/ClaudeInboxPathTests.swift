import Foundation
@testable import HeedCore
import Testing

/// Claude Code's inbox: heed writes to it and binds beside it only where Claude Code makes inboxes.
struct ClaudeInboxPathTests {
    @Test func onlyClaudeCodesOwnInboxFolders() {
        for path in [
            "/tmp/cc-socks/123.sock", "/tmp/cc-socks-501/123.sock", "/private/tmp/cc-socks/9-0123abcd.sock",
            "/run/user/501/cc-socks/42.sock", "/var/folders/x/T/cc-socks/abc123.sock",
        ] {
            #expect(ClaudeInbox.accepts(path), "\(path)")
        }
        for path in [
            "relative/cc-socks/1.sock", "/tmp/1.sock", "/Users/me/.ssh/1.sock", "/tmp/cc-socks/../x/1.sock",
            "/tmp//cc-socks/1.sock", "/tmp/cc-socks/agent.sock", "/tmp/cc-socks/1.sock/", "/tmp/cc-socks-x/1.sock",
            "/var/run/docker.sock", "/tmp/cc-socks/1.socket", "/tmp/cc-socks/./1.sock",
            "/" + String(repeating: "a", count: 100) + "/cc-socks/1.sock",
        ] {
            #expect(!ClaudeInbox.accepts(path), "\(path)")
        }
        #expect(ClaudeInbox.socket(from: ["CLAUDE_CODE_MESSAGING_SOCKET": "/Users/me/.ssh/1.sock"]) == nil)
        #expect(ClaudeInbox.socket(from: ["CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/1.sock"])
            == "/tmp/cc-socks/1.sock")
    }

    @Test func nothingIsSentAnywhereElse() async {
        let fake = FakeTransport()
        let channels = AgentChannels(transport: fake, receiptWindow: .milliseconds(50))
        #expect(await channels.send("hi", to: .claude(socket: "/var/run/docker.sock"))
            == .unreachable("not where Claude Code keeps an inbox"))
        #expect(fake.written.isEmpty)
    }

    @Test func aFileThatIsNotASocketIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("heed-1.sock")
        try Data("keep me".utf8).write(to: file)
        let listener = LineListener(path: file.path) { _ in }
        #expect(throws: (any Error).self) { try listener.start() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
    }
}
