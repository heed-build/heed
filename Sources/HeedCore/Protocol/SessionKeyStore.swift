import CryptoKit
import Foundation
import Security

/// Somewhere heed keeps its session key (`SessionKeys`).
public protocol SessionKeyStore: Sendable {
    /// The key kept there; nil when there is none.
    func read() throws -> Data?
    func write(_ key: Data) throws
    func delete() throws
}

/// How the running heed is signed, which decides where its key is kept.
public enum SigningKind: Equatable, Sendable {
    /// Signed with a Developer ID (a release): the login Keychain, where only this app reads it without asking you.
    case developerID
    /// Signed ad hoc (`codesign -s -`, a development build) or not at all: a new signature every build, so the
    /// Keychain would ask about every one. The 0600 file instead.
    case adHoc

    /// From the code signature's team identifier and flags (`kSecCodeInfoTeamIdentifier`, `kSecCodeInfoFlags`).
    public init(teamID: String?, flags: UInt32) {
        let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        self = !adhoc && !(teamID ?? "").isEmpty ? .developerID : .adHoc
    }

    /// The running process's.
    public static func current() -> SigningKind {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .adHoc }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .adHoc }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dictionary = info as? [String: Any] else { return .adHoc }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return SigningKind(teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String, flags: flags)
    }
}

/// Where the key is kept for each kind of build, and moving a key kept in the file into the Keychain once.
public enum SessionKeyStorage {
    /// The key for a build signed `signing`: in `keychain` for a Developer ID build, where a key still in `file`
    /// moves once (the file is then removed); in `file` otherwise. A Keychain that will not keep it leaves the file as
    /// it was and the key is this run's only.
    public static func load(
        signing: SigningKind, keychain: SessionKeyStore, file: SessionKeyStore
    ) throws -> SessionKeys {
        func valid(_ data: Data?) -> Data? { data?.count == 32 ? data : nil }
        func fresh() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
        guard signing == .developerID else {
            if let key = try valid(file.read()) { return SessionKeys(key: key) }
            let key = fresh()
            try file.write(key)
            return SessionKeys(key: key)
        }
        if let key = try? valid(keychain.read()) {
            // A file left by an earlier move that could not remove it.
            if (try? file.read()) != nil { try? file.delete() }
            return SessionKeys(key: key)
        }
        let key = (try? valid(file.read())) ?? fresh()
        guard (try? keychain.write(key)) != nil else { return SessionKeys(key: key) }
        try? file.delete()
        return SessionKeys(key: key)
    }
}

/// The key as a 0600 file beside heed's sockets: development builds and fixtures.
public struct FileKeyStore: SessionKeyStore {
    public let url: URL

    public init(url: URL = SessionKeys.defaultFile()) {
        self.url = url
    }

    public func read() throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    public func write(_ key: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: key)
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        chmod(url.path, 0o600)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// The key as a generic password in the login Keychain. The item's access list is the app that made it: a Developer
/// ID heed reads it without asking, a later release of the same app too, and any other program only if you allow it
/// when macOS asks.
public struct KeychainKeyStore: SessionKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "build.heed.session-key", account: String = "heed") {
        self.service = service
        self.account = account
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)")
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public func write(_ key: Data) throws {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "heed session key"
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
