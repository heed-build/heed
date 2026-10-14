import Foundation
@testable import HeedCore
import Testing

struct DomainStoreSafetyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aReadableCacheIsKeptAsThePreviousOne() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("domain.json")
        let store = DomainStore(domain: Fixtures.main, file: file)
        await store.flush()
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.sessions.count == Fixtures.main.sessions.count)
        let previous = try Data(contentsOf: DomainStore.previousFile(of: file))
        #expect(try previous == Data(contentsOf: file))
    }

    @Test func anUnreadableCacheIsMovedAsideNotLost() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("domain.json")
        try Data(#"{"version":6,"domain":{"sessions":"not what you think"}}"#.utf8).write(to: file)
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("domain.unreadable-") }
        #expect(aside.count == 1)
    }

    @Test func anotherFormatVersionIsMovedAsideToo() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("domain.json")
        let cached = CachedDomain(version: CachedDomain.currentVersion + 1, domain: Fixtures.main)
        try JSONEncoder.heed.encode(cached).write(to: file)
        _ = await DomainStore.load(from: file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .contains { $0.hasPrefix("domain.unreadable-") })
        if case let .failure(reason) = try DomainStore.decode(JSONEncoder.heed.encode(cached)) {
            #expect(reason.description.contains("format version"))
        }
    }
}
