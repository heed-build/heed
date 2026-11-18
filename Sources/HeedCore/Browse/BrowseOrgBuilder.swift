import Foundation

/// "Create <org> view": topic, team, language and archived filters over an org's repos, with the count of repos they
/// keep live, saved as a pinned scope. Pure state: the app loads `infos` (`gh repo list`), `teams` and each team's
/// repos, and acts on the action.
public struct BrowseOrgBuilder: Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case topic, team, language, archived

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public var hint: String {
            switch self {
            case .topic: "repos with a topic, like docs"
            case .team: "repos a team maintains"
            case .language: "the repo's main language"
            case .archived: "hidden unless you ask"
            }
        }
    }

    public enum Stage: Equatable, Sendable { case fields, values(Field) }

    public enum Action: Equatable, Sendable {
        case none, changed, close
        /// Load this team's repos (`gh api orgs/<org>/teams/<team>/repos`).
        case loadTeam(String)
        case create(BrowseOrgView)
    }

    public let owner: String
    public var infos: [BrowseRepoInfo]
    /// The team slugs the org has, when GitHub said.
    public var teams: [String]
    public var teamRepos: [String: Set<String>] = [:]
    /// The tokens chosen. No `archived` token means archived repos are hidden.
    public private(set) var filters: [BrowseToken] = []
    public private(set) var stage = Stage.fields
    public private(set) var cursor = 0
    public private(set) var picker: BrowsePicker?
    /// Set when the repo list or the teams could not be had, said on the card.
    public var problem: String?
    public private(set) var loading: Bool

    public init(owner: String, infos: [BrowseRepoInfo] = [], teams: [String] = [], filters: [BrowseToken] = []) {
        self.owner = owner
        self.infos = infos
        self.teams = teams
        self.filters = filters
        loading = infos.isEmpty
    }

    public mutating func loaded(_ infos: [BrowseRepoInfo], teams: [String]) {
        self.infos = infos
        self.teams = teams
        loading = false
    }

    public mutating func loadedTeam(_ slug: String, repos: Set<String>) { teamRepos[slug.lowercased()] = repos }

    /// The repos the filters keep.
    public var repos: [String] { BrowseOrgViews.repos(matching: filters, in: infos, teams: teamRepos) }

    /// The name the view would be saved under.
    public var name: String { BrowseOrgViews.name(for: filters, owner: owner) }

    /// What the view would be.
    public var view: BrowseOrgView { BrowseOrgView(owner: owner, name: name, filters: filters, repos: repos) }

    /// Rows: the four fields, then the create row.
    public var rowCount: Int { Field.allCases.count + 1 }
    public var onCreate: Bool { cursor == Field.allCases.count }

    public func summary(of field: Field) -> String {
        let values = filters.compactMap { token -> String? in
            switch (field, token) {
            case let (.topic, .topic(value)), let (.team, .team(value)), let (.language, .language(value)): value
            case (.archived, .archived(true)): "only archived"
            default: nil
            }
        }
        if field == .archived { return values.first ?? "hidden" }
        return values.isEmpty ? "any" : values.joined(separator: ", ")
    }

    func owns(_ field: Field, _ token: BrowseToken) -> Bool {
        switch (field, token) {
        case (.topic, .topic), (.team, .team), (.language, .language), (.archived, .archived): true
        default: false
        }
    }

    private func options(for field: Field) -> [BrowsePicker.Option] {
        let live = infos.filter { !$0.isArchived }
        let facets = BrowseOrgViews.facets(live)
        func ranked(_ counts: [String: Int]) -> [BrowsePicker.Option] {
            BrowseFacets.ranked(counts).map { BrowsePicker.Option($0.name, count: $0.count) }
        }
        switch field {
        case .topic: return ranked(facets.topics)
        case .language: return ranked(facets.languages)
        case .team: return teams.sorted().map { BrowsePicker.Option($0, count: teamRepos[$0.lowercased()]?.count) }
        case .archived: return [
                .init("hidden", count: infos.count { !$0.isArchived }),
                .init("only", label: "only archived", count: infos.count { $0.isArchived }),
            ]
        }
    }

    private func selection(of field: Field) -> [String] {
        filters.compactMap { token -> String? in
            switch (field, token) {
            case let (.topic, .topic(value)), let (.team, .team(value)), let (.language, .language(value)): value
            case (.archived, .archived(true)): "only"
            default: nil
            }
        }
    }

    public mutating func handle(_ stroke: KeyStroke) -> Action {
        switch stage {
        case .fields:
            switch stroke {
            case .escape: return .close
            case KeyStroke("Down"), KeyStroke("n", .control), KeyStroke("j", .control):
                cursor = min(cursor + 1, rowCount - 1)
            case KeyStroke("Up"), KeyStroke("p", .control), KeyStroke("k", .control):
                cursor = max(cursor - 1, 0)
            case KeyStroke("CR", .command): return create()
            case KeyStroke("CR"):
                if onCreate { return create() }
                let field = Field.allCases[cursor]
                stage = .values(field)
                picker = BrowsePicker(
                    options: options(for: field),
                    multiple: field != .archived,
                    selected: selection(of: field)
                )
            default: return .none
            }
            return .changed
        case let .values(field):
            guard var picker else { return .none }
            let action = picker.handle(stroke)
            self.picker = picker
            switch action {
            case .none: return .none
            case .changed: return .changed
            case .cancel:
                stage = .fields
                return .changed
            case .done:
                let others = filters.filter { !owns(field, $0) }
                filters = others
                for value in picker.selected {
                    switch field {
                    case .topic: filters.append(.topic(value))
                    case .team: filters.append(.team(value))
                    case .language: filters.append(.language(value))
                    case .archived: if value == "only" { filters.append(.archived(true)) }
                    }
                }
                stage = .fields
                if field == .team, let missing = picker.selected.first(where: { teamRepos[$0.lowercased()] == nil }) {
                    return .loadTeam(missing)
                }
                return .changed
            }
        }
    }

    /// A view that keeps no repo is not made.
    private func create() -> Action { repos.isEmpty ? .none : .create(view) }
}
