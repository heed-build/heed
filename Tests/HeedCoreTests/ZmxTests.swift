import Foundation
@testable import HeedCore
import Testing

struct ZmxTests {
    @Test func sessionsAreNamedAfterPanes() {
        #expect(Zmx.sessionName(pane: "p-1") == "heed-p-1")
        #expect(Zmx.pane(ofSession: "heed-p-1") == "p-1")
        #expect(Zmx.pane(ofSession: "mine") == nil)
    }

    @Test func onlyHeedsSessionsCountAsLive() {
        let list = "heed-a\nheed-b\nmy-own-session\n\n"
        #expect(Zmx.livePanes(fromList: list) == ["a", "b"])
        #expect(Zmx.livePanes(fromList: "").isEmpty)
    }

    @Test func theAttachCommandAndEnvironment() {
        #expect(Zmx.attachCommand(zmx: "/Applications/Heed.app/Contents/Helpers/zmx", pane: "p1")
            == "/Applications/Heed.app/Contents/Helpers/zmx attach heed-p1")
        #expect(Zmx.attachCommand(zmx: "/Volumes/My Disk/zmx", pane: "p1") == "'/Volumes/My Disk/zmx' attach heed-p1")
        // ⌃\ is heed's INSERT escape: zmx must not take it as its detach key.
        #expect(Zmx.environment(socketDirectory: "/d") == ["ZMX_DIR": "/d", "ZMX_NO_DETACH_KEY": "1"])
        #expect(Zmx.socketDirectory().hasSuffix("Heed/zmx"))
    }

    @Test func persistIsReadFromSessions() throws {
        let (on, _) = ConfigLoader.decode("[sessions]\npersist = \"zmx\"")
        #expect(try #require(on).work.persist == .zmx)
        let (off, _) = ConfigLoader.decode("")
        #expect(try #require(off).work.persist == PanePersistence.none)
        let (_, problems) = ConfigLoader.decode("[sessions]\npersist = \"tmux\"")
        #expect(problems.map(\.path) == ["sessions.persist"])
    }

    @Test func killAndListAgainstTheRealBinaryWhenThere() async throws {
        // Runs against the zmx scripts/zmx.sh fetched, when it is there (CI fetches it before bundling).
        let lock = try String(contentsOfFile: "packaging/zmx/zmx.lock", encoding: .utf8)
        let version = lock.split(separator: "\n").first { $0.hasPrefix("version=") }
            .map { String($0.dropFirst(8)) } ?? ""
        let zmx = "Vendor/zmx/\(version)/macos-aarch64/zmx"
        guard FileManager.default.isExecutableFile(atPath: zmx) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-zmx-\(UUID().uuidString)").path
        let env = Zmx.environment(socketDirectory: dir)
        _ = try await ProcessRunner.run(
            zmx,
            ["run", Zmx.sessionName(pane: "t1"), "-d", "sleep", "60"],
            environment: env
        )
        #expect(await Zmx.livePanes(zmx: zmx, socketDirectory: dir) == ["t1"])
        await Zmx.kill(panes: ["t1", "never-was"], zmx: zmx, socketDirectory: dir)
        #expect(await Zmx.livePanes(zmx: zmx, socketDirectory: dir).isEmpty)
    }
}
