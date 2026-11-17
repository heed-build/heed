import Foundation
@testable import HeedCore
import Testing

/// What a test changes for its own task is never seen by the work running beside it, as every suite in the process
/// runs beside the others.
struct HeedContextTests {
    /// The two sides meet while the override is in effect: the overriding side waits for its neighbour to read.
    @Test func anOverrideIsSeenInItsOwnTaskAndNotBesideIt() async {
        let real = Chats.localRoot
        let (overridden, inOverride) = AsyncStream.makeStream(of: Void.self)
        let (read, readDone) = AsyncStream.makeStream(of: Void.self)
        async let inside: (root: String, now: Date, id: String) = HeedContext.with {
            $0.chatsRoot = "/elsewhere/chats"
            $0.pinnedNow = Date(timeIntervalSince1970: 0)
            $0.newSessionID = { "pinned" }
        } operation: {
            inOverride.yield()
            for await _ in read {
                break
            }
            // A task started inside sees it too.
            let child = await Task { Chats.localRoot }.value
            return (child, Clock.now, HeedContext.current.newSessionID())
        }
        for await _ in overridden {
            break
        }
        let beside = (Chats.localRoot, Clock.now, HeedContext.current.newSessionID())
        readDone.yield()
        let seen = await inside
        #expect(seen.root == "/elsewhere/chats" && seen.now == Date(timeIntervalSince1970: 0) && seen.id == "pinned")
        #expect(beside.0 == real && beside.0 != "/elsewhere/chats")
        #expect(beside.1 != Date(timeIntervalSince1970: 0) && beside.2 != "pinned")
    }

    @Test func remoteRoutesAndOptionsStayInTheirTask() async {
        let (overridden, inOverride) = AsyncStream.makeStream(of: Void.self)
        let (read, readDone) = AsyncStream.makeStream(of: Void.self)
        async let inside: [String] = Remote.with(targets: ["box": "ssh://dev@127.0.0.1:2222"], extraOptions: ["-v"]) {
            inOverride.yield()
            for await _ in read {
                break
            }
            return Remote.sshArguments(host: "box", command: ["true"], controlDirectory: "/c")
        }
        for await _ in overridden {
            break
        }
        let beside = Remote.sshArguments(host: "box", command: ["true"], controlDirectory: "/c")
        readDone.yield()
        let seen = await inside
        #expect(seen.first == "-v" && seen.contains("ssh://dev@127.0.0.1:2222"))
        #expect(!beside.contains("-v") && !beside.contains("ssh://dev@127.0.0.1:2222") && beside.contains("box"))
    }
}
