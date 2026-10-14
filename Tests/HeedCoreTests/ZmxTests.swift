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
        #expect(Zmx.attachCommand(zmx: "/opt/homebrew/bin/zmx", pane: "p1") == "/opt/homebrew/bin/zmx attach heed-p1")
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
        // Runs against a zmx you installed (on PATH, or HEED_ZMX), when there is one.
        let candidates = [
            ProcessInfo.processInfo.environment["HEED_ZMX"],
            "/opt/homebrew/bin/zmx",
            "/usr/local/bin/zmx",
        ]
        guard let zmx = candidates.compactMap(\.self).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
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

struct ZmxInstallTests {
    @Test func instructionsForEachMachine() {
        #expect(ZmxInstall.commands(platform: "Darwin arm64") == ["brew install neurosnap/tap/zmx"])
        #expect(ZmxInstall.commands(platform: "Linux x86_64", os: "nixos") == ["nix profile install nixpkgs#zmx"])
        let ubuntu = ZmxInstall.commands(platform: "Linux x86_64", os: "ubuntu")
        #expect(ubuntu ==
            [
                "mkdir -p ~/.local/bin && curl -fsSL https://zmx.sh/a/zmx-0.8.1-linux-x86_64.tar.gz | tar -xz -C ~/.local/bin zmx",
            ])
        #expect(ZmxInstall.commands(platform: "Linux aarch64", os: "alpine").first?.contains("linux-aarch64") == true)
        #expect(ZmxInstall.commands(platform: "FreeBSD amd64").isEmpty)
    }
}
