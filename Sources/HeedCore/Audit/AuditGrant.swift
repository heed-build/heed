import Foundation

/// Something heed gave for good: a rule an agent no longer asks about, trust in a repo, a reviewer or author whose
/// word counts for Autopilot, a decision every session is told. Recorded when heed writes it; revoked with `d` in
/// Audit.
public struct AuditGrant: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// An allow rule in a project's `.claude/settings.local.json` (Always in the approvals).
        case alwaysRule = "always rule"
        /// Always allow, answered to a helper's agent over ACP: kept by that agent for its own run.
        case helperAlways = "helper always"
        /// `hasTrustDialogAccepted` for a repo in `~/.claude.json`.
        case claudeTrust = "claude trust"
        /// `mise trust` for a repo's config.
        case miseTrust = "mise trust"
        /// A login added to a repo's `trusted_reviewers`.
        case trustedReviewer = "trusted reviewer"
        /// A login added to a repo's `trusted_authors`.
        case trustedAuthor = "trusted author"
        /// A decision an agent proposed for the Mindmap, kept: sessions are told it.
        case memory

        public var label: String {
            switch self {
            case .alwaysRule: "Always rule"
            case .helperAlways: "helper Always"
            case .claudeTrust: "Claude trust"
            case .miseTrust: "mise trust"
            case .trustedReviewer: "trusted reviewer"
            case .trustedAuthor: "trusted author"
            case .memory: "memory"
            }
        }

        /// Whether heed can take it back. A helper's Always lives in its agent's own run, which ends with it.
        public var revocable: Bool { self != .helperAlways }
    }

    public var id: String
    public var at: Date
    public var kind: Kind
    /// What was given: `Bash(npm test:*)`, a repo's path, `@coderabbitai[bot]`, a decision's text.
    public var subject: String
    /// Where it lives: the settings file, `org/name`, a Mindmap node (`instance|node`).
    public var scope: String
    /// Why, in a few words.
    public var why: String
    public var cause: String?
    public var session: String?
    /// Found in a file heed knows (an Always rule already in `settings.local.json`), not recorded as it was given.
    public var beforeAudit: Bool

    public init(
        id: String = UUID().uuidString.lowercased(), at: Date, kind: Kind, subject: String, scope: String, why: String,
        cause: String? = nil, session: String? = nil, beforeAudit: Bool = false
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.subject = subject
        self.scope = scope
        self.why = why
        self.cause = cause
        self.session = session
        self.beforeAudit = beforeAudit
    }

    /// The same grant, recorded again: one per kind, subject and scope.
    public var identity: String { "\(kind.rawValue)\u{0}\(subject)\u{0}\(scope)" }
}

/// A grant taken back in Audit, or a try that failed. The grant is kept with it, so one listed as "before Audit" (never
/// recorded) shows what went.
public struct AuditRevocation: Codable, Hashable, Sendable {
    public var grant: AuditGrant
    public var at: Date
    public var cause: String?
    /// What heed did, or why it could not.
    public var result: String
    /// heed could not take the grant back: it still stands, and `d` tries again. Rows written before this was kept
    /// have none, and read as taken back, as they did then.
    public var failed: Bool

    public init(grant: AuditGrant, at: Date, cause: String? = nil, result: String, failed: Bool = false) {
        self.grant = grant
        self.at = at
        self.cause = cause
        self.result = result
        self.failed = failed
    }

    /// The record of a try: what heed did, or why it could not.
    public init(grant: AuditGrant, at: Date, cause: String? = nil, outcome: Result<String, AuditRevokeFailure>) {
        switch outcome {
        case let .success(result): self.init(grant: grant, at: at, cause: cause, result: result)
        case let .failure(failure):
            self.init(grant: grant, at: at, cause: cause, result: failure.message, failed: true)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grant = try container.decode(AuditGrant.self, forKey: .grant)
        at = try container.decode(Date.self, forKey: .at)
        cause = try container.decodeIfPresent(String.self, forKey: .cause)
        result = try container.decode(String.self, forKey: .result)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

/// Why a grant could not be taken back, in a few words.
public struct AuditRevokeFailure: Error, Hashable, Sendable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

/// Where a grant stands: given, being taken back (`d` was confirmed and heed is at it), taken back, or a try that
/// failed, which leaves it standing and can be tried again.
public enum GrantState: Hashable, Sendable {
    case standing
    case revoking(since: Date)
    case revoked(AuditRevocation)
    case failed(AuditRevocation)

    public enum Event: Hashable, Sendable {
        case revokeStarted(at: Date)
        case revokeFinished(AuditRevocation)
    }

    /// The state after `event`. Starting again while one try is under way, or once the grant is taken back, changes
    /// nothing.
    public func reduce(_ event: Event) -> GrantState {
        switch (self, event) {
        case let (.standing, .revokeStarted(at)), let (.failed, .revokeStarted(at)): .revoking(since: at)
        case (.revoking, .revokeStarted), (.revoked, .revokeStarted): self
        case let (_, .revokeFinished(revocation)):
            if revocation.failed { .failed(revocation) } else { .revoked(revocation) }
        }
    }

    /// Whether `d` starts a try.
    public var canRevoke: Bool {
        switch self {
        case .standing, .failed: true
        case .revoking, .revoked: false
        }
    }

    /// The grant was taken back.
    public var isRevoked: Bool {
        if case .revoked = self { return true }
        return false
    }

    /// The last try's record, taken back or failed.
    public var revocation: AuditRevocation? {
        switch self {
        case let .revoked(revocation), let .failed(revocation): revocation
        case .standing, .revoking: nil
        }
    }
}
