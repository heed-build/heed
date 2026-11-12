import HeedCore
import SwiftUI

// Settings' search: the field at the top of the tree, and the pane that lists what it found. The pane draws each
// matching page's own rows (so a match is edited where it is, with its modified and refused marks and ↺), under
// breadcrumbs that open the row on its page. What matched is HeedCore's (`SettingsCatalog.search`); the rows know it
// through the environment and draw only when they are one of the matches.

extension EnvironmentValues {
    /// The search shown; nil on a page.
    @Entry var settingsSearch: SettingsSearch?
    /// What a card's breadcrumb starts with while searching: the page, then an agent, org or repo and its tab.
    @Entry var settingsCrumbs: [String] = []
    /// The agent, org or repo the cards below are about, for their breadcrumbs; nil: any.
    @Entry var settingsCrumbTarget: SettingTarget?
    /// The card a row is in, for what its breadcrumb opens.
    @Entry var settingsCardTitle: String?
    /// The row marked: the search's cursor, or the row just opened on its page (flashed).
    @Entry var settingsMarkedRow: String?
}

/// A row of the search pane, where it is: what ↑ ↓ move over in the order they are drawn, and what ↩ opens.
struct SettingsSearchSpot: Equatable {
    /// `SettingsSearchSpot.key(ids[0], target)`.
    let key: String
    let ids: [String]
    let target: SettingTarget
    let page: SettingsPage
    let card: String?
    let minY: CGFloat

    /// The row's identity, for scrolling to it and marking it.
    static func key(_ id: String, _ target: SettingTarget) -> String { "row:\(id)@\(target.description)" }
}

struct SettingsSearchSpotsKey: PreferenceKey {
    static let defaultValue: [SettingsSearchSpot] = []

    static func reduce(value: inout [SettingsSearchSpot], nextValue: () -> [SettingsSearchSpot]) {
        value += nextValue()
    }
}

/// A card's breadcrumb's or a row's ask to be opened on its page; SettingsView does it.
struct SettingsReveal: Equatable {
    let page: SettingsPage
    let card: String?
    let target: SettingTarget?
}

extension View {
    /// What every setting row does for search: an identity to scroll to, the cursor's and the flash's mark, and,
    /// while searching, where it is in the pane.
    func settingsSearchRow(_ ids: [String], target: SettingTarget) -> some View {
        modifier(SettingsSearchRow(ids: ids, target: target))
    }
}

private struct SettingsSearchRow: ViewModifier {
    @Environment(\.settingsSearch) private var search
    @Environment(\.settingsPage) private var page
    @Environment(\.settingsCardTitle) private var card
    @Environment(\.settingsMarkedRow) private var marked
    let ids: [String]
    let target: SettingTarget

    func body(content: Content) -> some View {
        let key = SettingsSearchSpot.key(ids[0], target)
        content
            .background(marked == key ? Theme.selected : .clear)
            .animation(.easeOut(duration: 0.6), value: marked == key)
            .background {
                if search != nil, let page {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SettingsSearchSpotsKey.self, value: [SettingsSearchSpot(
                            key: key, ids: ids, target: target, page: page, card: card,
                            minY: geometry.frame(in: .named(SettingsView.scrollSpace)).minY
                        )])
                    }
                }
            }
            .id(key)
    }
}

/// Text with the query's words marked, while searching.
func searchHighlighted(_ text: String, _ search: SettingsSearch?) -> AttributedString {
    var attributed = AttributedString(text)
    guard let search else { return attributed }
    for range in search.ranges(in: text) {
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { continue }
        attributed[lower ..< upper].backgroundColor = Theme.block.opacity(0.3)
        attributed[lower ..< upper].foregroundColor = Theme.fg
    }
    return attributed
}

/// What a matched row says beside its label: `advanced` (found although Show advanced hides it on its page).
struct AdvancedTag: View {
    var body: some View {
        Text("advanced").font(Theme.ui(10)).foregroundStyle(Theme.fg3)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
            .fixedSize()
            .help("An advanced setting: its page shows it with Show advanced on, or once it is set")
    }
}

/// The field at the top of the tree: ⌘F focuses it, ↑ ↓ move through what it found, ↩ opens the row on its page, ⎋
/// clears it.
struct SettingsSearchField: View {
    @Environment(AppModel.self) private var model
    var focused: FocusState<SettingsFocus?>.Binding
    let move: (Int) -> Void
    let open: () -> Void
    let clear: () -> Void

    var body: some View {
        let isFocused = focused.wrappedValue == .search
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg3)
            TextField("Search settings", text: Bindable(model).settingsQuery)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .focused(focused, equals: .search)
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    clear()
                    return .handled
                }
                .onSubmit(open)
            Text(model.settingsQuery.isEmpty ? "⌘F" : "esc").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            isFocused || !model.settingsQuery.isEmpty ? Theme.fg3 : Theme.keyCapBorder
        ))
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = .search }
    }
}

/// Where the keyboard is in Settings: the search field or the tree.
enum SettingsFocus: Hashable {
    case search, tree
}

/// The pane while searching: how many settings match, then each page's matching rows under their breadcrumbs, the
/// page with the best match first. Nothing found says so, and points at Only modified when it is on.
struct SettingsSearchPane: View {
    @Environment(AppModel.self) private var model
    let search: SettingsSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ForEach(search.pages) { page in
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case .agents: AgentsSearchResults(search: search)
                    case .pilot: PilotSearchResults(search: search)
                    case .orgsAndRepos: OrgRepoSearchResults(search: search)
                    default: SettingsPageBody(page: page).environment(\.settingsCrumbs, [page.title])
                    }
                    let rowless = search.matches(on: page).filter(Self.hasNoRow)
                    if !rowless.isEmpty {
                        SettingsCard(title: rowless[0].entry.section) {
                            ForEach(rowless, id: \.self) { SearchPlainRow(match: $0) }
                        }
                        .environment(\.settingsCrumbs, [page.title])
                    }
                }
                .environment(\.settingsPage, page)
            }
        }
        .environment(\.settingsSearch, search)
    }

    /// Settings found that no page draws a row for: a scoped one with nowhere to be set yet (a host setting with no
    /// host), and the two tables Orgs & repos lists without a row (a repo's tasks, an org's standup questions).
    static func hasNoRow(_ match: SettingMatch) -> Bool {
        match.target == nil || ["repo.tasks", "org.standup_questions"].contains(match.entry.id)
    }

    @ViewBuilder private var header: some View {
        let quoted = "“\(search.query.trimmingCharacters(in: .whitespaces))”"
        VStack(alignment: .leading, spacing: 4) {
            if search.isEmpty {
                Text("No settings match \(quoted)").font(Theme.ui(17, weight: .semibold))
                if model.settingsFilter.onlyModified {
                    HStack(spacing: 4) {
                        Text("Only modified is on: it finds only what differs from heed's defaults.")
                            .foregroundStyle(Theme.fg2)
                        Button("Turn off Only modified") { model.settingsFilter.onlyModified = false }
                            .buttonStyle(.link)
                    }
                    .font(Theme.ui(12.5))
                } else {
                    Text("Every word must match a setting's name, its description, its page, or its config key "
                        + "(grace_seconds, llm.timeout_seconds).")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let count = search.matches.count
                Text("\(count) setting\(count == 1 ? "" : "s")\(model.settingsFilter.onlyModified ? " modified" : "") "
                    + "match\(count == 1 ? "es" : "") \(quoted)")
                    .font(Theme.ui(17, weight: .semibold))
                Text("↑↓ move · ↩ opens it on its page · esc clears").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
        }
    }
}

/// A card's name while searching: where its rows are (`Model calls › Limits`, `Agents › claude › Sessions ›
/// Starting`); a click opens the first of them on its page.
struct SettingsBreadcrumb: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsPage) private var page
    @Environment(\.settingsCrumbs) private var crumbs
    @Environment(\.settingsCrumbTarget) private var target
    let title: String

    var body: some View {
        let parts = (crumbs + [title]).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        Button {
            if let page { model.settingsReveal = SettingsReveal(page: page, card: title, target: target) }
        } label: {
            HStack(spacing: 5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text("›").foregroundStyle(Theme.fg3) }
                    Text(part).foregroundStyle(index == parts.count - 1 ? Theme.fg2 : Theme.fg3)
                }
            }
            .font(Theme.ui(12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open it on its page")
    }
}

/// A match no page has a row for: what it is, its key, and its value (or that there is nowhere to set it yet).
private struct SearchPlainRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsSearch) private var search
    let match: SettingMatch

    var body: some View {
        let entry = match.entry
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(searchHighlighted(entry.label, search)).font(Theme.ui(13))
                    if entry.level == .advanced { AdvancedTag() }
                }
                Text(entry.keyTexts.joined(separator: ", ")).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                Text(searchHighlighted(entry.detail, search)).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let target = match.target {
                Text(SettingsCatalog.value(entry, at: target, in: model.config)?.description ?? "unset")
                    .font(Theme.mono(12)).foregroundStyle(Theme.fg2).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
            } else {
                Text(nowhere(entry)).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            EditInConfigButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchRow([entry.id], target: match.target ?? .global)
        .settingsLine(.shown)
    }

    private func nowhere(_ entry: SettingsEntry) -> String {
        switch entry.scope {
        case .host: "no host yet"
        case .agent: "no agent"
        default: "no org or repo yet"
        }
    }
}

/// A page's own rows and cards, as the page shows them (and as search draws them, filtered).
struct SettingsPageBody: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .general: GeneralPage()
        case .notifications: NotificationsPage()
        case .updates: UpdatesPage()
        case .agents: AgentsPage()
        case .modelCalls: ModelCallsPage()
        case .decisions: DecisionsPage()
        case .worktrees: WorktreesPage()
        case .goals: GoalsPage()
        case .history: HistoryPage()
        case .github: GitHubPage()
        case .pilot: PilotPage()
        case .orgsAndRepos: OrgRepoSettings()
        case .attention: AttentionRuleSettings()
        case .hosts: HostsPage()
        case .tools: ToolsPage()
        case .keys: KeysPage()
        }
    }
}
