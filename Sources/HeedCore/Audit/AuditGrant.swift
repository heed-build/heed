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

/// A grant taken back, in Audit. The grant is kept with it, so one listed as "before Audit" (never recorded) shows
/// what went.
public struct AuditRevocation: Codable, Hashable, Sendable {
    public var grant: AuditGrant
    public var at: Date
    public var cause: String?
    /// What heed did, or why it could not.
    public var result: String

    public init(grant: AuditGrant, at: Date, cause: String? = nil, result: String) {
        self.grant = grant
        self.at = at
        self.cause = cause
        self.result = result
    }
}
