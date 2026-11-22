import Foundation
@testable import HeedCore
import Testing

struct DomainStoreWriteTests {
    private func file() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("domain.json")
    }

    /// Polls until `condition` holds, up to `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aChangeThatLeavesTheDomainAsItWasWritesNothing() async throws {
        let file = try file()
        let session = try #require(Fixtures.main.sessions.first)
        let store = DomainStore(
            domain: Domain.empty.applying([.sessionUpserted(session)]), file: file,
            writeDelay: .milliseconds(1), minimumInterval: .zero
        )
        await store.apply(.sessionUpserted(session))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRealChangeIsWritten() async throws {
        let file = try file()
        let session = try #require(Fixtures.main.sessions.first)
        let store = DomainStore(file: file, writeDelay: .milliseconds(1), minimumInterval: .zero)
        await store.apply(.sessionUpserted(session))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
    }

    @Test func writesAreSpacedByTheMinimumInterval() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 2)
        let store = DomainStore(file: file, writeDelay: .milliseconds(1), minimumInterval: .seconds(1))
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await DomainStore.load(from: file).sessions.count == 1, "the second write waited out the interval")
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 2 })
    }

    @Test func flushAllWritesAtOnceDespiteTheInterval() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        let store = DomainStore(file: file, writeDelay: .milliseconds(1), minimumInterval: .seconds(60))
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]))
        await store.flushAll()
        #expect(await DomainStore.load(from: file).sessions.count == 2)
    }
}
