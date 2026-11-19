import Foundation

/// A saved slice of an org with very many repos: the org plus the filters GitHub's own issue search evaluates on
/// every fetch, `language:<x>` and `archived:false` (or `archived:true`). A view stores no list of repos, so it never
/// goes stale: it is only ever as true as the search GitHub runs for it.
///
/// Topics and teams are not here on purpose: issue search has no `topic:` qualifier (it belongs to repository search)
/// and `team:` matches mentions, so a view over them would have to keep a snapshot of repos, and a snapshot goes stale.
public struct BrowseOrgView: Hashable, Sendable, Codable {
    public var owner: String
    public var name: String
    /// The `language` and `archived` tokens (at most one of each). No `archived` token is `archived:false`.
    public var filters: [BrowseToken]

    public init(owner: String, name: String, filters: [BrowseToken] = []) {
        self.owner = owner
        self.name = name
        self.filters = Self.kept(filters)
    }

    /// Reads a view stored by an earlier build: a stored list of repos is ignored, and a filter that is no longer
    /// one of heed's (a topic or a team) is dropped with the rest kept.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        filters = try Self.kept(container.decodeIfPresent([LossyToken].self, forKey: .filters)?
            .compactMap(\.token) ?? [])
    }

    private enum CodingKeys: String, CodingKey { case owner, name, filters }

    /// Only the tokens a view can hold, the first language and the last archived choice.
    static func kept(_ tokens: [BrowseToken]) -> [BrowseToken] {
        var language: BrowseToken?
        var archived: BrowseToken?
        for token in tokens {
            switch token {
            case .language: if language == nil { language = token }
            case .archived: archived = token
            default: break
            }
        }
        return [language, archived].compactMap { $0 }
    }

    public var language: String? {
        for case let .language(value) in filters {
            return value
        }
        return nil
    }

    /// Whether the view asks for archived repos only (`archived:true`) rather than hiding them.
    public var onlyArchived: Bool { filters.contains(.archived(true)) }

    /// The qualifiers GitHub evaluates: `org:globex language:C# archived:false`.
    public var qualifier: String {
        var parts = ["org:\(owner)"]
        if let language { parts += BrowseQuery.render(.language(language), now: Date()) }
        parts.append("archived:\(onlyArchived)")
        return parts.joined(separator: " ")
    }

    /// Whether an item can be in the view, as far as the item says: its repo is in the org. The language and
    /// archived state are GitHub's to judge, as with `raw`.
    public func contains(_ repo: Repo) -> Bool { repo.org.caseInsensitiveCompare(owner) == .orderedSame }
}

/// A token read from a stored value, nil when it is not one of heed's tokens any more (`topic`, `team`).
struct LossyToken: Decodable {
    let token: BrowseToken?

    init(from decoder: Decoder) throws {
        token = try? BrowseToken(from: decoder)
    }
}

/// What the builder's live look at an org needs to know about a repo: only to count what GitHub would search.
public struct BrowseRepoInfo: Hashable, Sendable, Codable {
    public var slug: String
    public var language: String?
    public var isArchived: Bool

    public init(slug: String, language: String? = nil, isArchived: Bool = false) {
        self.slug = slug
        self.language = language
        self.isArchived = isArchived
    }

    public static func listArguments(owner: String, limit: Int = 1000) -> [String] {
        ["repo", "list", owner, "--limit", "\(limit)", "--json", "nameWithOwner,primaryLanguage,isArchived"]
    }

    /// `gh repo list --json nameWithOwner,primaryLanguage,isArchived`, read back.
    public static func parse(_ data: Data) -> [BrowseRepoInfo]? {
        struct Raw: Decodable {
            struct Language: Decodable { let name: String? }
            let nameWithOwner: String
            let primaryLanguage: Language?
            let isArchived: Bool?
        }
        guard let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return nil }
        return raws.map {
            BrowseRepoInfo(
                slug: $0.nameWithOwner,
                language: $0.primaryLanguage?.name,
                isArchived: $0.isArchived ?? false
            )
        }
    }
}

public enum BrowseOrgViews {
    /// The repos a view's filters keep, for the builder's live count (a look at the org now, never stored). No
    /// `archived` token hides archived repos, as the view's `archived:false` does.
    public static func repos(matching filters: [BrowseToken], in infos: [BrowseRepoInfo]) -> [String] {
        var language: String?
        var archived = false
        for filter in filters {
            switch filter {
            case let .language(value): language = value.lowercased()
            case let .archived(value): archived = value
            default: break
            }
        }
        return infos.filter { info in
            if info.isArchived != archived { return false }
            if let language, (info.language ?? "").lowercased() != language { return false }
            return true
        }
        .map(\.slug)
        .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// How many repos have each language, for the picker.
    public static func languages(_ infos: [BrowseRepoInfo]) -> [String: Int] {
        var languages: [String: Int] = [:]
        for info in infos {
            if let language = info.language { languages[language, default: 0] += 1 }
        }
        return languages
    }

    /// A name for a view from its filters: `C#`, `archived`, `C# · archived`.
    public static func name(for filters: [BrowseToken], owner: String) -> String {
        let parts = filters.compactMap { token -> String? in
            switch token {
            case let .language(value): value
            case .archived(true): "archived"
            default: nil
            }
        }
        return parts.isEmpty ? "\(owner) view" : parts.joined(separator: " · ")
    }
}
