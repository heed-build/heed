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

    @Test func aSecondWriteWaitsOutTheMinimumInterval() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 2)
        // An interval no loaded runner outlasts, so "not yet" cannot turn into "already".
        let store = DomainStore(file: file, writeDelay: .milliseconds(1), minimumInterval: .seconds(60))
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await DomainStore.load(from: file).sessions.count == 1, "the second write waited out the interval")
    }

    @Test func aSecondWriteComesOnceTheIntervalHasPassed() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 2)
        let store = DomainStore(file: file, writeDelay: .milliseconds(1), minimumInterval: .milliseconds(500))
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]))
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

    @Test func aQuietChangeWaitsOutTheQuietInterval() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 2)
        let store = DomainStore(
            file: file, writeDelay: .milliseconds(1), minimumInterval: .zero, quietInterval: .seconds(60)
        )
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]), quiet: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await DomainStore.load(from: file).sessions.count == 1, "the quiet change was not written yet")
        let stats = await store.takeStats()
        #expect(stats.writes == 1)
    }

    @Test func aChangeThatCannotWaitBringsTheQuietOneAlong() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 3)
        let store = DomainStore(
            file: file, writeDelay: .milliseconds(1), minimumInterval: .zero, quietInterval: .seconds(60)
        )
        await store.apply(.sessionUpserted(sessions[0]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        await store.apply(.sessionUpserted(sessions[1]), quiet: true)
        await store.apply(.sessionUpserted(sessions[2]))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 3 })
    }

    @Test func aThousandQuietChangesCostOneWriteAtQuit() async throws {
        let file = try file()
        let session = try #require(Fixtures.main.sessions.first)
        let store = DomainStore(
            file: file, writeDelay: .milliseconds(1), minimumInterval: .zero, quietInterval: .seconds(60)
        )
        await store.apply(.sessionUpserted(session))
        #expect(await eventually { await DomainStore.load(from: file).sessions.count == 1 })
        _ = await store.takeStats()
        for tick in 0 ..< 1000 {
            var ticking = session
            ticking.lastActivity = Date(timeIntervalSince1970: 1_800_000_000 + Double(tick))
            await store.apply(.sessionUpserted(ticking), quiet: true)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await store.takeStats().writes == 0, "ticks of activity write nothing while the app runs")
        await store.flushAll()
        #expect(await store.takeStats().writes == 1)
    }
}
