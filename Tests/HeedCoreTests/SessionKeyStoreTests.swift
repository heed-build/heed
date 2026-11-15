import Foundation
@testable import HeedCore
import Testing

/// A store in memory, which can be told to refuse writes.
final class MemoryKeyStore: SessionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    let refusesWrites: Bool

    init(_ key: Data? = nil, refusesWrites: Bool = false) {
        self.key = key
        self.refusesWrites = refusesWrites
    }

    struct Refused: Error {}

    var kept: Data? { lock.withLock { key } }
    func read() throws -> Data? { lock.withLock { key } }
    func write(_ key: Data) throws {
        if refusesWrites { throw Refused() }
        lock.withLock { self.key = key }
    }

    func delete() throws { lock.withLock { key = nil } }
}

struct SessionKeyStoreTests {
    let old = Data(repeating: 7, count: 32)

    @Test func theSignatureDecidesTheStore() {
        #expect(SigningKind(teamID: "ABCDE12345", flags: 0) == .developerID)
        #expect(SigningKind(teamID: nil, flags: SecCodeSignatureFlags.adhoc.rawValue) == .adHoc)
        #expect(SigningKind(teamID: "ABCDE12345", flags: SecCodeSignatureFlags.adhoc.rawValue) == .adHoc)
        #expect(SigningKind(teamID: "", flags: 0) == .adHoc)
        #expect(SigningKind(teamID: nil, flags: 0) == .adHoc)
    }

    @Test func aReleaseKeepsItsKeyInTheKeychainAndNeverInTheFile() throws {
        let keychain = MemoryKeyStore()
        let file = MemoryKeyStore()
        let keys = try SessionKeyStorage.load(signing: .developerID, keychain: keychain, file: file)
        #expect(keychain.kept?.count == 32)
        #expect(file.kept == nil)
        let token = keys.token(session: "s1", pane: "p1")
        // Read again: the same key.
        let again = try SessionKeyStorage.load(signing: .developerID, keychain: keychain, file: file)
        #expect(again.verifies(token, session: "s1", pane: "p1"))
    }

    @Test func aKeyInTheFileMovesIntoTheKeychainOnce() throws {
        let keychain = MemoryKeyStore()
        let file = MemoryKeyStore(old)
        let before = SessionKeys(key: old).token(session: "s1", pane: "p1")
        let keys = try SessionKeyStorage.load(signing: .developerID, keychain: keychain, file: file)
        // Panes started with the file's key are still known; the file is gone.
        #expect(keys.verifies(before, session: "s1", pane: "p1"))
        #expect(keychain.kept == old)
        #expect(file.kept == nil)
        // A file that came back (an older heed ran) is removed, and the Keychain's key wins.
        let stray = MemoryKeyStore(Data(repeating: 9, count: 32))
        let later = try SessionKeyStorage.load(signing: .developerID, keychain: keychain, file: stray)
        #expect(later.verifies(before, session: "s1", pane: "p1"))
        #expect(stray.kept == nil)
    }

    @Test func aKeychainThatWillNotKeepItLeavesTheFile() throws {
        let file = MemoryKeyStore(old)
        let keys = try SessionKeyStorage.load(
            signing: .developerID, keychain: MemoryKeyStore(refusesWrites: true), file: file
        )
        #expect(keys.verifies(SessionKeys(key: old).token(session: "s", pane: nil), session: "s", pane: nil))
        #expect(file.kept == old)
    }

    @Test func aDevelopmentBuildUsesTheFileOnly() throws {
        let keychain = MemoryKeyStore(old)
        let file = MemoryKeyStore()
        _ = try SessionKeyStorage.load(signing: .adHoc, keychain: keychain, file: file)
        #expect(file.kept?.count == 32)
        #expect(file.kept != old)
        #expect(keychain.kept == old)
    }
}
