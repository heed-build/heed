import Foundation

/// Which Mindmap a piece of work belongs to. A GitHub org is a hard boundary: every org has its own Mindmap, and so
/// does your personal work, and nothing (grouping, synopses, links, search, what agents are told) ever crosses from
/// one to another.
public enum MindmapInstance {
    /// Work under your own login, chats with no repo, and anything heed cannot place in an org. No GitHub name can
    /// hold an `@`, so an org that happens to be called `personal` stays an org.
    public static let personal = "@personal"

    /// What heed knows that decides it.
    public struct Context: Hashable, Sendable {
        /// The signed-in GitHub login; nil while heed does not know it (then nothing is taken for personal by owner).
        public var login: String?
        /// Forks, by their `org/name`: the `org/name` they were forked from. A fork belongs with its upstream.
        public var upstreams: [String: String]
        /// A chat's folder, when it is a git repo: its `org/name`, by chat (session) id.
        public var chatRepos: [String: String]

        public init(login: String? = nil, upstreams: [String: String] = [:], chatRepos: [String: String] = [:]) {
            self.login = login
            self.upstreams = upstreams
            self.chatRepos = chatRepos
        }
    }

    /// Where it goes, and whether it spans orgs (its first repo decides; heed flags it so you can move it).
    public struct Resolved: Hashable, Sendable {
        public var instance: String
        public var spansOrgs: Bool
    }

    public static func of(_ entry: LedgerEntry, context: Context) -> Resolved {
        var repos = entry.repos
        if entry.chat, repos.isEmpty, let repo = context.chatRepos[entry.id] { repos = [repo] }
        let owners = repos.map { owner(of: $0, context: context) }
        guard let first = owners.first else { return Resolved(instance: personal, spansOrgs: false) }
        return Resolved(instance: first, spansOrgs: Set(owners).count > 1)
    }

    /// The instance of one `org/name`: its upstream's owner for a fork, `personal` for your own login and for repos
    /// with no owner heed can read (`local/…`).
    public static func owner(of slug: String, context: Context) -> String {
        let repo = context.upstreams[slug] ?? slug
        let org = String(repo.split(separator: "/").first ?? "")
        if org.isEmpty || org == "local" { return personal }
        if let login = context.login, org.caseInsensitiveCompare(login) == .orderedSame { return personal }
        return name(org)
    }

    /// An org's instance: its name, lowercased. GitHub org names are letters, digits and dashes; anything else is
    /// dropped, and a name with nothing left is personal.
    public static func name(_ org: String) -> String {
        let kept = org.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return kept.isEmpty ? personal : kept
    }

    /// The instance's file: `personal.sqlite`, or `org-<name>.sqlite`.
    public static func fileName(_ instance: String) -> String {
        instance == personal ? "personal.sqlite" : "org-\(name(instance)).sqlite"
    }

    /// How the instance is shown: the org's name, or `personal`.
    public static func title(_ instance: String) -> String {
        instance == personal ? "personal" : instance
    }
}
