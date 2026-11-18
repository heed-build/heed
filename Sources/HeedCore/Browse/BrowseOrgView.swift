import Foundation

/// A saved slice of an org with very many repos: filters on the repos (topic, team, language, archived) and the
/// repos they left. Browse searches the repos, so the scope is a list of `repo:` qualifiers.
///
/// Which qualifier is real: `language:` and `archived:` are qualifiers of GitHub's issue search, but heed does not
/// use them here, because the filter is on the repo and the list of repos is needed anyway for the count. `topic:`
/// is a qualifier of repository search only, and `team:` matches mentions of a team: neither narrows issues. So all
/// four are resolved locally, over `gh repo list --json …` (topic, language, archived) and
/// `gh api orgs/<org>/teams/<team>/repos` (team), and the search names the repos that remain.
public struct BrowseOrgView: Hashable, Sendable, Codable {
    public var owner: String
    public var name: String
    /// The `topic`, `team`, `language` and `archived` tokens that made the list.
    public var filters: [BrowseToken]
    /// `org/name` of each repo that remains; nil is the whole org.
    public var repos: [String]?

    public init(owner: String, name: String, filters: [BrowseToken] = [], repos: [String]? = nil) {
        self.owner = owner
        self.name = name
        self.filters = filters
        self.repos = repos
    }

    /// One qualifier for the whole view (`org:` for all of it); a view too big for one search goes through
    /// `repoChunks`.
    public var qualifier: String {
        guard let repos else { return "org:\(owner)" }
        return repos.map { "repo:\($0)" }.joined(separator: " ")
    }

    public func contains(_ repo: Repo) -> Bool {
        guard let repos else { return repo.org.caseInsensitiveCompare(owner) == .orderedSame }
        return repos.contains { $0.caseInsensitiveCompare(repo.slug) == .orderedSame }
    }

    /// The `repo:` qualifiers in groups that each fit in `room` characters (at least one repo to a group).
    public func repoChunks(room: Int) -> [String] {
        guard let repos else { return ["org:\(owner)"] }
        var chunks: [String] = []
        var current = ""
        for repo in repos {
            let part = "repo:\(repo)"
            if !current.isEmpty, current.count + 1 + part.count > room {
                chunks.append(current)
                current = part
            } else {
                current += (current.isEmpty ? "" : " ") + part
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// What the filters need to know about a repo.
public struct BrowseRepoInfo: Hashable, Sendable, Codable {
    public var slug: String
    public var language: String?
    public var topics: [String]
    public var isArchived: Bool

    public init(slug: String, language: String? = nil, topics: [String] = [], isArchived: Bool = false) {
        self.slug = slug
        self.language = language
        self.topics = topics
        self.isArchived = isArchived
    }

    public static func listArguments(owner: String, limit: Int = 1000) -> [String] {
        [
            "repo",
            "list",
            owner,
            "--limit",
            "\(limit)",
            "--json",
            "nameWithOwner,primaryLanguage,repositoryTopics,isArchived",
        ]
    }

    /// `gh repo list --json nameWithOwner,primaryLanguage,repositoryTopics,isArchived`, read back.
    public static func parse(_ data: Data) -> [BrowseRepoInfo]? {
        struct Raw: Decodable {
            struct Language: Decodable { let name: String? }
            struct Topic: Decodable { let name: String? }
            let nameWithOwner: String
            let primaryLanguage: Language?
            let repositoryTopics: [Topic]?
            let isArchived: Bool?
        }
        guard let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return nil }
        return raws.map {
            BrowseRepoInfo(
                slug: $0.nameWithOwner, language: $0.primaryLanguage?.name,
                topics: ($0.repositoryTopics ?? []).compactMap(\.name), isArchived: $0.isArchived ?? false
            )
        }
    }

    /// `gh api orgs/<org>/teams/<team>/repos --jq '.[].full_name'`, one per line.
    public static func teamRepos(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("/") })
    }
}

public enum BrowseOrgViews {
    /// The repos the filters keep. Different fields all must hold; several values of one field are alternatives.
    /// No `archived` token hides archived repos, as the design's "Archived hidden". `teams` maps a team to its repos
    /// (lowercased slugs); a team not fetched yet keeps nothing.
    public static func repos(
        matching filters: [BrowseToken], in infos: [BrowseRepoInfo], teams: [String: Set<String>] = [:]
    ) -> [String] {
        var topics: Set<String> = []
        var languages: Set<String> = []
        var wanted: [String] = []
        var archived: Bool?
        for filter in filters {
            switch filter {
            case let .topic(value): topics.insert(value.lowercased())
            case let .language(value): languages.insert(value.lowercased())
            case let .team(value): wanted.append(value.lowercased())
            case let .archived(value): archived = value
            default: break
            }
        }
        let teamRepos = wanted.reduce(into: Set<String>()) { $0.formUnion(teams[$1] ?? []) }
        return infos.filter { info in
            if info.isArchived, archived != true { return false }
            if archived == true, !info.isArchived { return false }
            if !topics.isEmpty, topics.isDisjoint(with: info.topics.map { $0.lowercased() }) { return false }
            if !languages.isEmpty, !languages.contains((info.language ?? "").lowercased()) { return false }
            if !wanted.isEmpty, !teamRepos.contains(info.slug.lowercased()) { return false }
            return true
        }
        .map(\.slug)
        .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// How many repos have each topic / language, most first.
    public static func facets(_ infos: [BrowseRepoInfo]) -> (topics: [String: Int], languages: [String: Int]) {
        var topics: [String: Int] = [:]
        var languages: [String: Int] = [:]
        for info in infos {
            for topic in info.topics {
                topics[topic, default: 0] += 1
            }
            if let language = info.language { languages[language, default: 0] += 1 }
        }
        return (topics, languages)
    }

    /// A name for a view from its filters: `docs · docs-eng · C#`.
    public static func name(for filters: [BrowseToken], owner: String) -> String {
        let parts = filters.compactMap { token -> String? in
            switch token {
            case let .topic(value), let .team(value), let .language(value): value
            case .archived(true): "archived"
            default: nil
            }
        }
        return parts.isEmpty ? "\(owner) view" : parts.joined(separator: " · ")
    }
}
