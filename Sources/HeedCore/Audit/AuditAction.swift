import Foundation

/// What kind of outward action a row is, as its tag shows it.
public enum AuditClass: String, Codable, Hashable, Sendable, CaseIterable {
    /// A release, a package published, a tag pushed, a deploy (`PermissionRisk.publishes`).
    case publish
    case merge
    case push
    case comment
    /// An approval, a review, reviewers asked for.
    case review
    /// Any other change on GitHub: a PR opened, closed or edited, a label, an issue.
    case write
}

/// One thing heed or an agent did outside this Mac, with what caused it.
public struct AuditAction: Codable, Hashable, Sendable, Identifiable {
    public enum Actor: String, Codable, Hashable, Sendable {
        /// heed's own call (`gh`, `git push`).
        case heed
        /// An agent's tool call, as its hooks reported it.
        case agent
        /// Seen on GitHub (a release, a deployment) with no recorded cause.
        case outside
    }

    public enum Outcome: String, Codable, Hashable, Sendable {
        case done
        case failed
        /// Asked for and not allowed: denied in heed, or never answered.
        case held
    }

    /// Who let an agent's call through.
    public struct Approval: Codable, Hashable, Sendable {
        public enum By: String, Codable, Hashable, Sendable {
            /// You, in the approvals (`gy`).
            case you
            /// A notification's Allow.
            case notification
            /// An Always rule the agent already had: nobody was asked.
            case rule
            /// The agent's own permission mode or its pane: heed did not see an ask.
            case agent
        }

        public var by: By
        public var at: Date?
        /// `allowed once`, `allowed always`, `denied`, or the rule that matched.
        public var detail: String

        public init(by: By, at: Date? = nil, detail: String) {
            self.by = by
            self.at = at
            self.detail = detail
        }

        /// `Denied by you in approvals`, `Allowed once by you from a notification`, `Allowed by an Always rule: …`.
        public var text: String {
            let done = detail.prefix(1).uppercased() + detail.dropFirst()
            return switch by {
            case .you: "\(done) by you in approvals"
            case .notification: "\(done) by you from a notification"
            case .rule: "Allowed by an Always rule: \(detail)"
            case .agent: "Allowed without asking heed: \(detail)"
            }
        }
    }

    public var id: String
    public var at: Date
    public var actor: Actor
    public var tag: AuditClass
    /// `merged #412 webapp`, `pushed to feature/x`, `npm publish`.
    public var what: String
    /// Exactly what ran, as it could be typed again (a body the log does not keep is `…`).
    public var command: String
    /// `org/name`, when known.
    public var repo: String?
    public var url: String?
    public var cause: String?
    public var session: String?
    public var sessionTitle: String?
    public var agent: String?
    public var approval: Approval?
    public var outcome: Outcome
    /// For a row seen on GitHub: what it is there (`release:org/name:123`), so it is recorded once.
    public var key: String?

    public init(
        id: String = UUID().uuidString.lowercased(), at: Date, actor: Actor, tag: AuditClass, what: String,
        command: String, repo: String? = nil, url: String? = nil, cause: String? = nil, session: String? = nil,
        sessionTitle: String? = nil, agent: String? = nil, approval: Approval? = nil, outcome: Outcome = .done,
        key: String? = nil
    ) {
        self.id = id
        self.at = at
        self.actor = actor
        self.tag = tag
        self.what = what
        self.command = command
        self.repo = repo
        self.url = url
        self.cause = cause
        self.session = session
        self.sessionTitle = sessionTitle
        self.agent = agent
        self.approval = approval
        self.outcome = outcome
        self.key = key
    }
}
