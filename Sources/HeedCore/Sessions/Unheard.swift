import Foundation

/// A session's agent pane whose hook messages heed does not take: they carry no token, or one heed cannot vouch for
/// with the key it has now (`SessionKeys`). Heed still drops every such message; this only says that they arrive, so
/// the session is not filed by a state its agent stopped reporting. A pane started by an older heed (a zmx session
/// heed reattached, an agent resumed in it) has no token. Kept for this run only: after a relaunch the next message
/// heed drops says it again. `session.reconnect` restarts the pane with this run's token.
public struct Unheard: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        /// The pane was started without a token: by a heed from before panes had one.
        case noToken
        /// Its token is not one heed can vouch for: made with another key (a key that could not be kept), or for
        /// another pane.
        case unverified

        /// Why, for the session's band and the docs.
        public var text: String {
            switch self {
            case .noToken: "its pane was started by an older heed, without a token"
            case .unverified: "its pane's token is not one this heed can check"
            }
        }
    }

    /// The pane the messages name: the session's agent pane.
    public var pane: String
    public var reason: Reason
    public var firstSeen: Date
    public var lastSeen: Date
    /// How many messages heed did not take.
    public var count: Int

    public init(pane: String, reason: Reason, firstSeen: Date, lastSeen: Date? = nil, count: Int = 1) {
        self.pane = pane
        self.reason = reason
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen ?? firstSeen
        self.count = count
    }

    /// Why heed does not take a message with `token` from `pane` of `session`; nil when it does.
    public static func reason(token: String?, session: String, pane: String?, keys: SessionKeys) -> Reason? {
        if keys.verifies(token, session: session, pane: pane) { return nil }
        return (token ?? "").isEmpty ? .noToken : .unverified
    }

    /// A message heed did not take, as its session records it. Only a message that names a session heed has and that
    /// session's agent pane (`agentPane`, nil when heed has no such session) counts; anything else changes nothing
    /// and returns nil. The pane and reason are the latest message's; the first time stays.
    public static func noting(
        _ reason: Reason, pane: String?, agentPane: String?, on existing: Unheard?, at date: Date
    ) -> Unheard? {
        guard let pane, let agentPane, pane == agentPane else { return nil }
        guard var unheard = existing, unheard.pane == pane else {
            return Unheard(pane: pane, reason: reason, firstSeen: date)
        }
        unheard.reason = reason
        unheard.lastSeen = max(unheard.lastSeen, date)
        unheard.count += 1
        return unheard
    }

    /// A message heed took, from `pane`: that pane is heard again. Another pane's message (a shell split) leaves it.
    public static func heard(pane: String?, on existing: Unheard?) -> Unheard? {
        guard let existing, let pane, existing.pane == pane else { return existing }
        return nil
    }
}
