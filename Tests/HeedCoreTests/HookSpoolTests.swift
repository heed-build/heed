import Foundation
@testable import HeedCore
import Testing

struct HookSpoolTests {
    private func spool() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return HookSpool.path(forSocket: url.appendingPathComponent("heed.sock").path)
    }

    private func line(_ state: AgentState, at seconds: Double) throws -> Data {
        try HookMessage(
            session: "s", pane: "p", kind: .state(state, reason: nil), sentAt: Date(timeIntervalSince1970: seconds)
        ).encodedLine()
    }

    @Test func itSitsBesideTheSocket() {
        #expect(HookSpool.path(forSocket: "/a/b/heed.sock") == "/a/b/hooks.spool")
    }

    @Test func spooledMessagesComeBackInOrderOnce() throws {
        let path = try spool()
        try #expect(HookSpool.append(line(.working, at: 1), to: path))
        try #expect(HookSpool.append(line(.asking, at: 2) + line(.done, at: 3), to: path))
        let drained = HookSpool.drain(path)
        #expect(drained.map(\.kind) == [
            .state(.working, reason: nil), .state(.asking, reason: nil), .state(.done, reason: nil),
        ])
        #expect(drained.map(\.sentAt.timeIntervalSince1970) == [1, 2, 3])
        #expect(HookSpool.drain(path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aDrainACrashInterruptedIsReadFirst() throws {
        let path = try spool()
        try line(.working, at: 1).write(to: URL(fileURLWithPath: path + ".draining"))
        try #expect(HookSpool.append(line(.done, at: 2), to: path))
        #expect(HookSpool.drain(path).map(\.sentAt.timeIntervalSince1970) == [1, 2])
    }

    @Test func aBrokenLineIsSkipped() throws {
        let path = try spool()
        try #expect(HookSpool.append(Data("{half a line\n".utf8) + line(.done, at: 2), to: path))
        #expect(HookSpool.drain(path).count == 1)
    }

    @Test func aFullSpoolTakesNothingMore() throws {
        let path = try spool()
        let one = try line(.working, at: 1)
        #expect(HookSpool.append(one, to: path, limit: one.count * 2))
        #expect(HookSpool.append(one, to: path, limit: one.count * 2))
        #expect(!HookSpool.append(one, to: path, limit: one.count * 2))
        #expect(HookSpool.drain(path).count == 2)
    }
}
