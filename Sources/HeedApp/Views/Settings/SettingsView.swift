import HeedCore
import SwiftUI

/// Settings (⌘,): a view of config.toml that writes single values back into it, comments and layout kept. The
/// sidebar is the catalog's tree (group ▸ page ▸ the page's sections); every row carries the catalog's modified and
/// refused marks, and the counts roll up to the tree. Key bindings are shown but edited only in the file.
struct SettingsView: View {
    /// The names Settings had before its pages; `:settings.open` still takes them (`SettingsPage.named`).
    typealias Section = SettingsPage

    @Environment(AppModel.self) private var model
    @State private var tree: SettingsTree
    @State private var cursor: SettingsNode
    /// The section at the top of the pane, which the tree marks.
    @State private var inView: String?
    /// A section the tree asked to scroll to.
    @State private var scrollTarget: String?

    static let scrollSpace = "settingsPage"

    /// Opens on `section` (General; screenshots open others).
    init(section: SettingsPage = .general) {
        _tree = State(initialValue: SettingsTree(page: section))
        _cursor = State(initialValue: .page(section))
    }

    var body: some View {
        let counts = SettingsCatalog.counts(in: model.config, problems: model.configProblems)
        HStack(spacing: 0) {
            SettingsSidebar(tree: $tree, cursor: $cursor, inView: inView, counts: counts) { node in
                if case let .section(_, title) = node { scrollTarget = title }
            }
            .frame(width: 220)
            Theme.line.frame(width: 1)
            ScrollViewReader { proxy in
                ListScroll {
                    VStack(alignment: .leading, spacing: 22) {
                        let unmatched = SettingsCatalog.problems(model.configProblems).unmatched
                        if !unmatched.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(unmatched, id: \.description) { problem in
                                    Text("config.toml: \(problem.description)")
                                }
                            }
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.err)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.err.opacity(0.1)))
                        }
                        if let kept = tree.kept, !kept.contains(.page(tree.page)) {
                            NothingModified(page: kept.isEmpty ? nil : tree.page).id("top")
                        } else {
                            SettingsPageHeader(page: tree.page).id("top")
                            page(tree.page).environment(\.settingsPage, tree.page)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(SectionOffsetsKey.self) { offsets in
                    let shown = Self.inView(offsets, sections: tree.page.sections)
                    if shown != inView { inView = shown }
                }
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
                .onChange(of: tree.page) { proxy.scrollTo("top", anchor: .top) }
            }
            // A page taller than the window starts at its top (shots draw it unscrolled, cut at the foot).
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        // Sized by the window, not by the page: the page scrolls inside it.
        .frame(
            minWidth: 820,
            idealWidth: 1080,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
        .onAppear { tree.folded = model.settingsFolded.subtracting([.group(tree.page.group)]) }
        .onChange(of: tree.folded) { model.settingsFolded = tree.folded }
        // Only modified keeps the lines with a change; the page shown moves to one that has one.
        .onChange(of: model.settingsFilter.onlyModified ? counts.changedNodes : nil, initial: true) { _, kept in
            tree.kept = kept
            if let page = tree.keptPage, page != tree.page {
                tree.show(.page(page))
                cursor = .page(page)
            }
        }
        // `:settings.open agents` turns the window to that page, open or not.
        .onChange(of: model.settingsPage, initial: true) { _, asked in
            if let asked {
                tree.show(.page(asked))
                cursor = .page(asked)
                model.settingsPage = nil
            }
        }
    }

    /// The section at the top of the pane: the last one whose name has scrolled up to it, else the first.
    static func inView(_ offsets: [String: CGFloat], sections: [String]) -> String? {
        sections.last { (offsets[$0] ?? .infinity) <= 60 } ?? sections.first
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
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

/// The tree: groups that fold (▸ ▾), their pages, and the shown page's sections, each with the modified count
/// (`● 3`, a folded group too) and a red ! where config.toml has a value heed refused. Click a page to show it, a
/// section to scroll to it; with the tree focused ↑ ↓ move and ← → fold.
struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var tree: SettingsTree
    @Binding var cursor: SettingsNode
    let inView: String?
    let counts: SettingsCounts
    /// A line was picked (clicked or reached with the keys).
    let picked: (SettingsNode) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tree.visible, id: \.self) { node in
                        line(node)
                    }
                    if tree.kept?.isEmpty == true {
                        Text("Nothing is modified.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { go(tree.move(cursor, by: -1)) }
            .onKeyPress(.downArrow) { go(tree.move(cursor, by: 1)) }
            .onKeyPress(.leftArrow) { go(tree.left(cursor)) }
            .onKeyPress(.rightArrow) { go(tree.right(cursor)) }
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                FootSwitch(
                    title: "Only modified", isOn: Bindable(model).settingsFilter.onlyModified,
                    help: "Only what differs from heed's defaults, or that config.toml has and heed refused "
                        + "(:settings.modified)"
                )
                FootSwitch(
                    title: "Show advanced", isOn: Bindable(model).settingsFilter.showAdvanced,
                    help: model.settingsFilter.onlyModified
                        ? "Only modified shows every changed setting, advanced or not"
                        : "Tuning: timeouts, limits, retention, tool paths, command lines. A set one always shows "
                        + "(:settings.advanced)"
                )
                .disabled(model.settingsFilter.onlyModified)
                Button("Open config.toml") { NSWorkspace.shared.open(model.configFile) }
                    .buttonStyle(.link)
                    .font(Theme.ui(12.5))
                Text(Paths.abbreviate(model.configFile.path)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(14)
        }
        .background(Theme.bg2)
    }

    private func go(_ node: SettingsNode) -> KeyPress.Result {
        cursor = node
        picked(node)
        return .handled
    }

    private func line(_ node: SettingsNode) -> some View {
        let isCursor = focused && cursor == node
        return HStack(spacing: 6) {
            switch node {
            case let .group(group):
                Image(systemName: tree.folded.contains(node) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 10)
                Text(group.title).font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.fg2)
                Spacer(minLength: 4)
                marks(modified: counts.modified(.group(group)), problems: counts.problems(.group(group)))
            case let .page(page):
                Text(page.title).font(Theme.ui(13)).foregroundStyle(tree.page == page ? Theme.fg : Theme.fg2)
                    .padding(.leading, 16)
                Spacer(minLength: 4)
                marks(modified: counts.modified(.page(page)), problems: counts.problems(.page(page)))
            case let .section(page, title):
                let current = inView == title
                Text(title).font(Theme.ui(12, weight: current ? .medium : .regular))
                    .foregroundStyle(current ? Theme.fg : Theme.fg3)
                    .padding(.leading, 30)
                Spacer(minLength: 4)
                marks(
                    modified: counts.modified(.section(page, title)),
                    problems: counts.problems(.section(page, title)), quiet: true
                )
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, node.isSection ? 3 : 5)
        .padding(.top, node.isGroup && node != tree.visible.first ? 8 : 0)
        .background(RoundedRectangle(cornerRadius: 5).fill(background(node)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isCursor ? Theme.keyCapBorder : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            if node.isGroup {
                tree.toggle(node)
            } else {
                tree.show(node)
            }
            cursor = node
            picked(node)
        }
    }

    private func background(_ node: SettingsNode) -> Color {
        if case let .page(page) = node, page == tree.page { return Theme.bg3 }
        return .clear
    }

    @ViewBuilder private func marks(modified: Int, problems: Int, quiet: Bool = false) -> some View {
        HStack(spacing: 6) {
            if modified > 0 {
                Text("● \(modified)").font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.block.opacity(quiet ? 0.75 : 1))
                    .help("\(modified) modified")
            }
            if problems > 0 {
                Text("!").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.err)
                    .help("\(problems) value\(problems == 1 ? "" : "s") config.toml has that heed refused")
            }
        }
    }
}

/// A switch at the foot of the tree: its name left, the switch right.
private struct FootSwitch: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.done)
        .help(help)
        .padding(.bottom, 2)
    }
}

/// Only modified with nothing modified (on the page asked for, or anywhere): every setting is at heed's default.
private struct NothingModified: View {
    @Environment(AppModel.self) private var model
    /// The page asked for; nil: nothing is modified on any page.
    let page: SettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.map { "Nothing on \($0.title) is modified" } ?? "Nothing is modified")
                .font(Theme.ui(17, weight: .semibold))
            Text(page == nil
                ? "Every setting is at heed's default, and config.toml has nothing heed refused."
                : "Its settings are at heed's defaults; the tree lists the pages with changes.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            Button("Show every setting") { model.settingsFilter.onlyModified = false }
                .buttonStyle(.link)
                .font(Theme.ui(12.5))
        }
    }
}

private extension SettingsNode {
    var isGroup: Bool { if case .group = self { true } else { false } }
    var isSection: Bool { if case .section = self { true } else { false } }
}
