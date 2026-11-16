import Foundation

/// What Audit shows, from its records: the ledger of outward actions newest first, each with its cause chain, and the
/// grants with whether each still stands.
public struct AuditBook: Hashable, Sendable {
    public private(set) var causes: [String: Cause] = [:]
    public private(set) var actions: [AuditAction] = []
    public private(set) var grants: [AuditGrant] = []
    /// By grant id: where each grant that was revoked, or is being, stands. Absent is standing.
    public private(set) var grantStates: [String: GrantState] = [:]
    /// Where the record's chain stopped holding, when it did.
    public var broken: AuditChain.Break?

    public init(_ records: [AuditRecord] = [], broken: AuditChain.Break? = nil) {
        self.broken = broken
        apply(records)
    }

    public mutating func apply(_ records: [AuditRecord]) {
        var added = false
        for record in records {
            switch record {
            case let .cause(cause): causes[cause.id] = cause
            case let .action(action):
                actions.append(action)
                added = true
            case let .grant(grant): grants.append(grant)
            case let .revoke(revocation): update(revocation.grant.id, .revokeFinished(revocation))
            }
        }
        if added { actions.sort { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id } }
    }

    /// `d` on `grant` was confirmed: false (nothing changes) while a try is under way or once it is taken back.
    public mutating func startRevoke(_ grant: AuditGrant, at: Date) -> Bool {
        let before = grantState(grant)
        guard before.canRevoke else { return false }
        grantStates[grant.id] = before.reduce(.revokeStarted(at: at))
        return true
    }

    private mutating func update(_ id: String, _ event: GrantState.Event) {
        grantStates[id] = (grantStates[id] ?? .standing).reduce(event)
    }

    /// Where `grant` stands. A revocation from before it was given (the same rule found in a file again) is not its.
    public func grantState(_ grant: AuditGrant) -> GrantState {
        guard let state = grantStates[grant.id] else { return .standing }
        if let revocation = state.revocation, revocation.at < grant.at { return .standing }
        return state
    }

    /// One action, as its row and detail show it.
    public struct Row: Hashable, Sendable, Identifiable {
        public var action: AuditAction
        /// From the trigger down to the action's own cause.
        public var chain: [Cause]
        /// Whose text reached what caused it, least trusted first.
        public var authors: [ExternalText.Author]
        public var id: String { action.id }

        /// What started it, in a few words: `you · gm`, `Autopilot`, `outside heed`.
        public var trigger: String {
            if action.actor == .outside { return "outside heed" }
            // The nearest decision above the action: the key, rule, event or helper, not the session it ran in.
            guard let root = chain.last(where: { $0.trigger != .session && $0.trigger != .agent }) ?? chain.first
            else { return action.actor == .agent ? "the agent" : "heed" }
            return root.trigger == .key ? "you · \(root.detail)" : root.trigger.label
        }

        /// The least trusted author whose text reached it, when that is anyone but you and your collaborators.
        public var worstTrust: ExternalText.Trust? { authors.first.map(\.trust) }
    }

    /// Newest first.
    public var rows: [Row] {
        actions.map { action in
            let chain = Cause.chain(action.cause, in: causes)
            return Row(action: action, chain: chain, authors: Cause.authors(of: chain))
        }
    }

    /// Actions since `since`: what the tab's count says (the last 7 days).
    public func count(since: Date) -> Int { actions.count { $0.at >= since } }

    /// Rows seen on GitHub already recorded, by their key.
    public var outsideKeys: Set<String> { Set(actions.compactMap(\.key)) }

    /// A grant and whether it stands.
    public struct GrantRow: Hashable, Sendable, Identifiable {
        public var grant: AuditGrant
        public var state: GrantState
        public var chain: [Cause]
        public var id: String { grant.id }

        public init(grant: AuditGrant, state: GrantState = .standing, chain: [Cause] = []) {
            self.grant = grant
            self.state = state
            self.chain = chain
        }
    }

    /// The grants recorded, newest first, then `before` (found in files, not recorded), each once; a later grant of
    /// the same thing replaces an earlier one.
    public func grantRows(before: [AuditGrant] = []) -> [GrantRow] {
        var latest: [String: AuditGrant] = [:]
        for grant in grants where latest[grant.identity].map({ $0.at <= grant.at }) ?? true {
            latest[grant.identity] = grant
        }
        let recorded = latest.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        let known = Set(latest.keys)
        let older = before.filter { !known.contains($0.identity) }
            .sorted { $0.scope != $1.scope ? $0.scope < $1.scope : $0.subject < $1.subject }
        return (recorded + older).map { grant in
            GrantRow(grant: grant, state: grantState(grant), chain: Cause.chain(grant.cause, in: causes))
        }
    }

    /// The identities of the grants recorded: a file's rule already among them is not listed again as before Audit.
    public var grantIdentities: Set<String> { Set(grants.map(\.identity)) }
}

/// A release or deployment on a watched repo, as GitHub lists it.
public struct GitHubRelease: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case release
        case deployment
    }

    public var kind: Kind
    public var repo: String
    /// GitHub's id.
    public var id: String
    /// The tag (a release) or the environment (a deployment).
    public var name: String
    public var at: Date
    public var url: String?
    public var author: String?

    public init(
        kind: Kind, repo: String, id: String, name: String, at: Date, url: String? = nil, author: String? = nil
    ) {
        self.kind = kind
        self.repo = repo
        self.id = id
        self.name = name
        self.at = at
        self.url = url
        self.author = author
    }

    /// What Audit records it by, once.
    public var key: String { "\(kind.rawValue):\(repo):\(id)" }

    /// `gh api repos/<repo>/releases` and `.../deployments` answers; nothing for what cannot be read.
    public static func parse(_ data: Data, kind: Kind, repo: String) -> [GitHubRelease] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let format = ISO8601DateFormatter()
        return list.compactMap { item in
            let id = (item["id"] as? Int).map(String.init) ?? item["id"] as? String
            let stamp = (kind == .release ? item["published_at"] ?? item["created_at"] : item["created_at"]) as? String
            guard let id, let date = stamp.flatMap(format.date) else { return nil }
            let name = (kind == .release ? item["tag_name"] : item["environment"]) as? String ?? ""
            let author = ((kind == .release ? item["author"] : item["creator"]) as? [String: Any])?["login"] as? String
            let url = kind == .release ? item["html_url"] as? String
                : "https://github.com/\(repo)/deployments/\(name)"
            return GitHubRelease(kind: kind, repo: repo, id: id, name: name, at: date, url: url, author: author)
        }
    }

    /// The row Audit shows for one no recorded cause explains.
    public func action() -> AuditAction {
        AuditAction(
            at: at, actor: .outside, tag: .publish,
            what: kind == .release ? "release \(name) \(repo.split(separator: "/").last ?? "")"
                : "deployed to \(name) \(repo.split(separator: "/").last ?? "")",
            command: kind == .release ? "gh release view \(name) -R \(repo)" : "deployment \(id) to \(name)",
            repo: repo, url: url, agent: author.map { "@" + $0 }, key: key
        )
    }
}

/// Which releases and deployments heed or an agent explains: a publish recorded for the same repo near the same
/// time (a release whose tag the command names, or a tag pushed; for a deployment, a publish or a merge there).
public enum AuditOutside {
    /// How far apart a cause and what GitHub shows of it may be: a workflow that releases on a tag takes a while.
    public static let window: TimeInterval = 2 * 3600

    /// The ones nothing explains, of those seen since `since` (Audit's start: older ones are not its business) and
    /// not recorded yet (`known` keys).
    public static func unexplained(
        _ releases: [GitHubRelease], actions: [AuditAction], since: Date, known: Set<String>
    ) -> [GitHubRelease] {
        releases.filter { release in
            release.at >= since && !known.contains(release.key)
                && !actions.contains { explains($0, release) }
        }
    }

    static func explains(_ action: AuditAction, _ release: GitHubRelease) -> Bool {
        guard action.actor != .outside, action.outcome == .done,
              action.repo.map({ $0.caseInsensitiveCompare(release.repo) == .orderedSame }) ?? false,
              release.at >= action.at.addingTimeInterval(-300), release.at <= action.at.addingTimeInterval(window)
        else { return false }
        switch release.kind {
        case .release:
            guard action.tag == .publish else { return false }
            let names = !release.name
                .isEmpty && (action.command.contains(release.name) || action.what.contains(release.name))
            return names || action.what.hasPrefix("pushed tag") || action.command.contains("workflow")
        case .deployment:
            return action.tag == .publish || action.tag == .merge
        }
    }
}
