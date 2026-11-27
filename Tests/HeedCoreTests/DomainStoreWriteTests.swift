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

    // MARK: The background file

    private func github(_ viewer: String) -> GitHubState {
        var state = Fixtures.main.github
        state.viewer = viewer
        return state
    }

    @Test func theCacheGoesToItsOwnFileAndTheCoreKeepsSessions() async throws {
        let file = try file()
        let store = DomainStore(domain: Fixtures.main, file: file)
        await store.flush()
        let data = try Data(contentsOf: file)
        let core = try DomainStore.decode(data).get()
        #expect(core.sessions.count == Fixtures.main.sessions.count)
        #expect(core.github == GitHubState(), "the cache is not in the core file")
        #expect(core.pullDetails.isEmpty)
        #expect(FileManager.default.fileExists(atPath: DomainStore.backgroundFile(of: file).path))
        let loaded = await DomainStore.load(from: file)
        #expect(loaded == Fixtures.main, "both files read back as the one domain")
    }

    @Test func aSessionChangeDoesNotRewriteTheBackgroundFile() async throws {
        let file = try file()
        let sessions = Fixtures.main.sessions
        try #require(sessions.count >= 2)
        let store = DomainStore(
            domain: Domain.empty.applying([.githubSynced(github("first"))]), file: file,
            writeDelay: .milliseconds(1), minimumInterval: .zero
        )
        await store.flush()
        let background = DomainStore.backgroundFile(of: file)
        try Data("sentinel".utf8).write(to: background)
        await store.apply(.sessionUpserted(sessions[1]))
        // The core file is read directly: `load` would take the sentinel for an unreadable background file.
        #expect(await eventually { (try? DomainStore.decode(Data(contentsOf: file)).get().sessions.count) == 1 })
        #expect(try Data(contentsOf: background) == Data("sentinel".utf8), "only the core was written")
    }

    @Test func aSyncWaitsOutTheBackgroundIntervalAndQuitWritesIt() async throws {
        let file = try file()
        let store = DomainStore(
            file: file, writeDelay: .milliseconds(1), minimumInterval: .zero, backgroundInterval: .seconds(60)
        )
        await store.apply(.githubSynced(github("first")))
        #expect(await eventually { await DomainStore.load(from: file).github.viewer == "first" })
        await store.apply(.githubSynced(github("second")))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await DomainStore.load(from: file).github.viewer == "first", "the second sync waits")
        await store.flushAll()
        #expect(await DomainStore.load(from: file).github.viewer == "second")
    }

    @Test func aCacheWrittenBeforeTheSplitStillLoadsWhole() async throws {
        let file = try file()
        let old = CachedDomain(version: CachedDomain.currentVersion, domain: Fixtures.main.leavingLog)
        try JSONEncoder.heed.encode(old).write(to: file)
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.github == Fixtures.main.github)
        #expect(loaded.pullDetails == Fixtures.main.pullDetails)
    }

    @Test func aBackgroundFileThatDoesNotReadIsMovedAsideAndTheCoreStillLoads() async throws {
        let file = try file()
        let store = DomainStore(domain: Fixtures.main, file: file)
        await store.flush()
        try Data("not json".utf8).write(to: DomainStore.backgroundFile(of: file))
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.sessions.count == Fixtures.main.sessions.count)
        #expect(loaded.github == GitHubState())
        let dir = file.deletingLastPathComponent().path
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir)
            .contains { $0.hasPrefix("domain.background.unreadable-") })
    }
}
