import Foundation
@testable import HeedCore
import Testing

/// `persist = "auto"` and zmx's check: what panes do, and whether zmx works the way heed uses it.
struct ZmxCheckTests {
    @Test func autoUsesZmxOnlyWhenItWorks() {
        let works = ZmxHealth(path: "/opt/homebrew/bin/zmx", version: "0.8.1")
        let broken = ZmxHealth(path: "/opt/homebrew/bin/zmx", problem: "zmx list failed: boom")
        let missing = ZmxHealth(path: nil, problem: "not installed")
        #expect(ZmxHealth.decide(.auto, health: works) == .zmx)
        #expect(ZmxHealth.decide(.auto, health: broken) == .none)
        #expect(ZmxHealth.decide(.auto, health: missing) == .none)
        #expect(ZmxHealth.decide(.auto, health: nil) == .none)
        // Asked for: zmx whenever it is there; never when off.
        #expect(ZmxHealth.decide(.zmx, health: broken) == .zmx)
        #expect(ZmxHealth.decide(.zmx, health: missing) == .none)
        #expect(ZmxHealth.decide(.none, health: works) == .none)
        #expect(ZmxCheck.parseVersion("zmx 0.8.1 (abc)\n") == "0.8.1")
        #expect(ZmxCheck.parseVersion("something else") == nil)
    }

    @Test func autoIsTheDefault() {
        #expect(HeedConfig.default.work.persist == .auto)
        #expect(ConfigLoader.decode("[sessions]\npersist = \"zmx\"").config?.work.persist == .zmx)
        #expect(ConfigLoader.decode("[sessions]\npersist = \"often\"").problems.first?
            .message == "expected auto, zmx or none")
        #expect(ConfigLoader.decode("[tools]\nzmx = \"~/bin/zmx\"").config?.tools.zmx == "~/bin/zmx")
    }

    @Test func theCheckRunsZmxTheWayPanesDo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-zmx-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func script(_ name: String, list: String) throws -> String {
            let path = "\(dir)/\(name)"
            try """
            #!/bin/sh
            case "$1" in
              version) echo "zmx 0.8.1"; echo "ghostty-vt 1.2" ;;
              list) [ -n "$ZMX_DIR" ] && [ "$ZMX_NO_DETACH_KEY" = 1 ] || exit 3; \(list) ;;
            esac
            """.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let good = try await ZmxCheck.run(zmx: script("good", list: "exit 0"), socketDirectory: dir + "/sock")
        #expect(good == ZmxHealth(path: dir + "/good", version: "0.8.1"))
        #expect(FileManager.default.fileExists(atPath: dir + "/sock"))
        let bad = try await ZmxCheck.run(zmx: script("bad", list: "echo nope >&2; exit 1"), socketDirectory: dir + "/s")
        #expect(!bad.works && bad.problem == "zmx list failed: nope" && bad.version == "0.8.1")
        #expect(await ZmxCheck.run(zmx: nil) == ZmxHealth(path: nil, problem: "not installed"))
    }
}
