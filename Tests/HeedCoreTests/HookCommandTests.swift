import Foundation
@testable import HeedCore
import Testing

/// Hooks name heed's own `heed` and sockets in their command lines: a pane's environment cannot send them elsewhere.
struct HookCommandTests {
    let sockets = HookSockets(hooks: "/heed/h.sock", control: "/heed/c.sock")

    @Test func claudesHooksNameHeedsBinaryAndSockets() throws {
        let json = AgentIntegration.claudeSettingsJSON(heed: "/Apps/Heed.app/Contents/Helpers/heed", sockets: sockets)
        #expect(!json.contains("HEED_BIN"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        let permission = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"]
            as? [[String: Any]])
        #expect(permission.first?["command"] as? String
            == "HEED_SOCKET=/heed/h.sock HEED_CONTROL=/heed/c.sock /Apps/Heed.app/Contents/Helpers/heed hook claude "
            + "PermissionRequest")
    }

    @Test func codexsHooksDoToo() {
        let codex = AgentIntegration.codexArguments(heed: "/h/heed", sockets: sockets).joined(separator: " ")
        #expect(codex.contains("HEED_CONTROL=/heed/c.sock /h/heed hook codex PermissionRequest"))
    }

    @Test func theFilesHeedWritesUseItsOwnSockets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = IntegrationFiles(directory: folder, heedBinary: "/h/heed", sockets: sockets)
        try files.write()
        let written = try String(contentsOfFile: files.claudeSettings, encoding: .utf8)
        #expect(written == AgentIntegration.claudeSettingsJSON(heed: "/h/heed", sockets: sockets))
        #expect(written.contains(#"HEED_CONTROL=\/heed\/c.sock \/h\/heed hook claude Stop"#))
        #expect(IntegrationFiles.default(heedBinary: "/h/heed").sockets == .default)
    }

    /// The hook as a shell runs it: the pane's own HEED_CONTROL does not win.
    @Test func thePanesEnvironmentDoesNotWin() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let printer = folder.appendingPathComponent("heed")
        try Data("#!/bin/sh\necho \"HEED_CONTROL=$HEED_CONTROL\"\necho \"HEED_SOCKET=$HEED_SOCKET\"\n".utf8)
            .write(to: printer)
        chmod(printer.path, 0o755)
        let command = AgentIntegration.hookCommand(heed: printer.path, sockets: sockets, agent: "claude", event: "x")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HEED_CONTROL": "/elsewhere.sock", "HEED_SOCKET": "/elsewhere2.sock", "PATH": "/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let env = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(env.contains("HEED_CONTROL=/heed/c.sock\n"))
        #expect(env.contains("HEED_SOCKET=/heed/h.sock\n"))
        #expect(!env.contains("elsewhere"))
    }
}
