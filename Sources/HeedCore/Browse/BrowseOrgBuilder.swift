import Foundation

/// "Create <org> view": a language and whether archived repos show, over an org, with a live count of the repos those
/// keep, saved as a pinned scope. The view stores only its filters, which GitHub's search evaluates on every fetch; the
/// count is a look at the org now (`gh repo list`, loaded by the app) and is never saved. Pure state: the app loads
/// `infos` and acts on the action.
public struct BrowseOrgBuilder: Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case language, archived

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public var hint: String {
            switch self {
            case .language: "the repo's main language"
            case .archived: "hidden unless you ask"
            }
        }
    }

    public enum Stage: Equatable, Sendable { case fields, values(Field) }

    public enum Action: Equatable, Sendable {
        case none, changed, close
        case create(BrowseOrgView)
    }

    public let owner: String
    public var infos: [BrowseRepoInfo]
    /// The tokens chosen. No `archived` token means archived repos are hidden.
    public private(set) var filters: [BrowseToken] = []
    public private(set) var stage = Stage.fields
    public private(set) var cursor = 0
    public private(set) var picker: BrowsePicker?
    /// Set when the repo list could not be had, said on the card.
    public var problem: String?
    public private(set) var loading: Bool

    public init(owner: String, infos: [BrowseRepoInfo] = [], filters: [BrowseToken] = []) {
        self.owner = owner
        self.infos = infos
        self.filters = BrowseOrgView.kept(filters)
        loading = infos.isEmpty
    }

    public mutating func loaded(_ infos: [BrowseRepoInfo]) {
        self.infos = infos
        loading = false
    }

    /// The repos the filters keep now: the live count, not stored.
    public var repos: [String] { BrowseOrgViews.repos(matching: filters, in: infos) }

    /// The name the view would be saved under.
    public var name: String { BrowseOrgViews.name(for: filters, owner: owner) }

    /// What the view would be: the org and its filters, with no list of repos.
    public var view: BrowseOrgView { BrowseOrgView(owner: owner, name: name, filters: filters) }

    /// Rows: the fields, then the create row.
    public var rowCount: Int { Field.allCases.count + 1 }
    public var onCreate: Bool { cursor == Field.allCases.count }

    public func summary(of field: Field) -> String {
        let values = filters.compactMap { token -> String? in
            switch (field, token) {
            case let (.language, .language(value)): value
            case (.archived, .archived(true)): "only archived"
            default: nil
            }
        }
        if field == .archived { return values.first ?? "hidden" }
        return values.isEmpty ? "any" : values.joined(separator: ", ")
    }

    func owns(_ field: Field, _ token: BrowseToken) -> Bool {
        switch (field, token) {
        case (.language, .language), (.archived, .archived): true
        default: false
        }
    }

    private func options(for field: Field) -> [BrowsePicker.Option] {
        switch field {
        case .language:
            let counts = BrowseOrgViews.languages(infos.filter { !$0.isArchived })
            return [.init("any", label: "any language", count: infos.count { !$0.isArchived })]
                + BrowseFacets.ranked(counts).map { BrowsePicker.Option($0.name, count: $0.count) }
        case .archived: return [
                .init("hidden", count: infos.count { !$0.isArchived }),
                .init("only", label: "only archived", count: infos.count { $0.isArchived }),
            ]
        }
    }

    private func selection(of field: Field) -> [String] {
        filters.compactMap { token -> String? in
            switch (field, token) {
            case let (.language, .language(value)): value
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
                picker = BrowsePicker(options: options(for: field), multiple: false, selected: selection(of: field))
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
                filters = filters.filter { !owns(field, $0) }
                if let value = picker.selected.first {
                    switch field {
                    case .language: if value != "any" { filters.append(.language(value)) }
                    case .archived: if value == "only" { filters.append(.archived(true)) }
                    }
                }
                stage = .fields
                return .changed
            }
        }
    }

    /// A view that keeps no repo is not made.
    private func create() -> Action { repos.isEmpty ? .none : .create(view) }
}
