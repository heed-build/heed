import CryptoKit
import Foundation

/// Who a pane's processes are, as heed vouches for them: each pane gets a token in its environment
/// (`HEED_SESSION_TOKEN`) that names its session and pane and carries heed's signature over both. Every hook message
/// and control request from a pane carries it, and heed takes the session and pane from the token, never from what
/// the request says: a process speaks for the pane it was started in, and no other. The signing key is heed's own and
/// kept (`SessionKeyStorage`), so a pane heed started before a restart (a zmx session it reattaches) is still known
/// after.
public struct SessionKeys: Sendable {
    private let key: SymmetricKey

    public init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    /// A key for this process only: fixtures, snapshots and tests.
    public static func ephemeral() -> SessionKeys {
        SessionKeys(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// `~/Library/Application Support/Heed/session.key`, beside the sockets.
    public static func defaultFile() -> URL {
        URL(fileURLWithPath: (HeedEnvironment.defaultSocketPath() as NSString).deletingLastPathComponent)
            .appendingPathComponent("session.key")
    }

    /// The key in `file`, made (32 random bytes, mode 0600) the first time. A file that is not a key is replaced.
    public static func load(from file: URL = defaultFile()) throws -> SessionKeys {
        try SessionKeyStorage.load(signing: .adHoc, keychain: FileKeyStore(url: file), file: FileKeyStore(url: file))
    }

    /// The token for `pane` of `session`: `<session>.<pane>.<signature>`, the first two base64url.
    public func token(session: String, pane: String?) -> String {
        let fields = [session, pane ?? ""].map { Self.encode(Data($0.utf8)) }
        return (fields + [signature(session: session, pane: pane ?? "")]).joined(separator: ".")
    }

    /// The session and pane `token` vouches for; nil when heed did not make it.
    public func caller(_ token: String?) -> SessionCaller? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let session = Self.decode(parts[0]), let pane = Self.decode(parts[1]),
              !session.isEmpty,
              Self.equal(parts[2], signature(session: session, pane: pane))
        else { return nil }
        return SessionCaller(session: session, pane: pane.isEmpty ? nil : pane)
    }

    /// Whether `token` is heed's for exactly this session and pane.
    public func verifies(_ token: String?, session: String, pane: String?) -> Bool {
        caller(token) == SessionCaller(session: session, pane: pane)
    }

    private func signature(session: String, pane: String) -> String {
        var message = Data("heed-session-v1\u{0}".utf8)
        message.append(Data(session.utf8))
        message.append(0)
        message.append(Data(pane.utf8))
        return Self.encode(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> String? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 {
            base += "="
        }
        return Data(base64Encoded: base).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Compares every byte whatever the first difference, so how long a check takes says nothing about the token.
    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A pane heed vouches for: the session it belongs to and the pane itself.
public struct SessionCaller: Hashable, Sendable {
    public var session: String
    public var pane: String?

    public init(session: String, pane: String?) {
        self.session = session
        self.pane = pane
    }
}

/// Who sent a control request, as heed knows it: a pane (by its token), or something outside heed's panes (no
/// token, no session named). Something outside is nobody in particular: never you, whatever it says.
public enum ControlCaller: Hashable, Sendable {
    case pane(SessionCaller)
    case outside

    public var session: String? {
        if case let .pane(caller) = self { caller.session } else { nil }
    }

    /// The request's caller, and the request with its session and pane set from the token. Nil when the request names
    /// a session it cannot vouch for: a token heed did not make, or a session or pane other than the token's.
    public static func of(_ request: ControlRequest, keys: SessionKeys) -> (ControlCaller, ControlRequest)? {
        var request = request
        // For these the request's `session` is the caller; for the rest it names the session acted on.
        let callerMethods: Set<ControlRequest.Method> = [.goal, .memory, .permission]
        let claims = callerMethods.contains(request.method)
        guard let token = request.token else {
            guard !claims || request.session == nil else { return nil }
            if claims { request.pane = nil }
            return (.outside, request)
        }
        guard let caller = keys.caller(token) else { return nil }
        if claims {
            if let session = request.session, session != caller.session { return nil }
            if let pane = request.pane, pane != caller.pane { return nil }
            request.session = caller.session
            request.pane = caller.pane
        }
        return (.pane(caller), request)
    }
}
