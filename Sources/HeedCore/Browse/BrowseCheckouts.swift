import Foundation

/// What Browse works inside: the orgs and repos checked out on a Mac heed knows (this one or a host). It is built from
/// the repo records each time and never stored, so it is always what `repos` says now. A repo that is not checked out
/// is not searched: clone it first (Add or clone).
public struct BrowseCheckouts: Equatable, Sendable {
    /// One org (or account) with the repos checked out under it.
    public struct Org: Equatable, Sendable, Identifiable {
        public var name: String
        public var repos: [Repo]
        public var id: String { name.lowercased() }
    }

    /// Most checked-out repos first, then by name.
    public let orgs: [Org]

    /// `local` is heed's placeholder for a repo with no remote: it is no org on GitHub.
    public init(records: [RepoRecord]) {
        var byOrg: [String: Org] = [:]
        for record in records where record.repo.org.lowercased() != "local" && !record.repo.org.isEmpty {
            let key = record.repo.org.lowercased()
            var org = byOrg[key] ?? Org(name: record.repo.org, repos: [])
            if !org.repos.contains(where: { $0.slug.lowercased() == record.repo.slug.lowercased() }) {
                org.repos.append(record.repo)
            }
            byOrg[key] = org
        }
        orgs = byOrg.values.map { org in
            var org = org
            org.repos.sort { $0.name.lowercased() < $1.name.lowercased() }
            return org
        }.sorted {
            $0.repos.count == $1.repos.count ? $0.name.lowercased() < $1.name.lowercased()
                : $0.repos.count > $1.repos.count
        }
    }

    public var isEmpty: Bool { orgs.isEmpty }
    public var orgNames: [String] { orgs.map(\.name) }

    public func org(_ name: String) -> Org? { orgs.first { $0.id == name.lowercased() } }

    /// Whether anything under `owner` is checked out: Browse searches an org as a whole, so one checkout is enough.
    public func contains(org name: String) -> Bool { org(name) != nil }

    /// Whether a place may be searched: its org has a checkout. A `repo:` qualifier follows its org (an org-level scope
    /// is allowed, so a repo inside it is too).
    public func allows(_ place: BrowsePlace) -> Bool { contains(org: place.owner) }

    /// The default scope's search qualifiers: `org:` for every org with a checkout (GitHub takes an account's name
    /// there too).
    public var qualifiers: [String] { orgNames.map { "org:\($0)" } }

    /// The repos of `org` that are checked out, as `repo:` qualifiers: for an org too big to browse whole.
    public func repoQualifiers(of org: String) -> [String] {
        self.org(org)?.repos.map { "repo:\($0.slug)" } ?? []
    }
}

/// An org, or one repo of an org, that a query names.
public struct BrowsePlace: Equatable, Sendable {
    public var owner: String
    /// `org/name` when it is a repo.
    public var repo: String?
    /// What the message calls it.
    public var name: String { repo ?? owner }

    public init(owner: String, repo: String? = nil) {
        self.owner = owner
        self.repo = repo
    }

    /// `org` or `org/name` as a qualifier's value (a Project is `org/number`: the owner is what counts).
    static func parse(_ value: String, isRepo: Bool) -> BrowsePlace {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let owner = parts.first else { return BrowsePlace(owner: value) }
        return BrowsePlace(owner: owner, repo: isRepo && parts.count == 2 ? value : nil)
    }
}
