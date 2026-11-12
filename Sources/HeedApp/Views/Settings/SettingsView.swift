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
    @FocusState private var focus: SettingsFocus?
    /// The search pane's rows, top to bottom, and the one ↑ ↓ are on (nil: none yet, ↩ opens the first).
    @State private var spots: [SettingsSearchSpot] = []
    @State private var resultCursor: String?
    /// The row just opened from the search, flashed on its page, and its section, scrolled to first.
    @State private var flashed: String?
    @State private var spotSection: String?

    static let scrollSpace = "settingsPage"

    /// Opens on `section` (General; screenshots open others).
    init(section: SettingsPage = .general) {
        _tree = State(initialValue: SettingsTree(page: section))
        _cursor = State(initialValue: .page(section))
    }

    var body: some View {
        let counts = SettingsCatalog.counts(in: model.config, problems: model.configProblems)
        let search = currentSearch
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsSearchField(focused: $focus, move: moveResult, open: openResult, clear: clearSearch)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                SettingsSidebar(
                    tree: $tree, cursor: $cursor, focus: $focus, inView: inView, counts: counts, search: search,
                    pickMatch: { page in resultCursor = spots.first { $0.page == page }?.key },
                    picked: { node in
                        if case let .section(_, title) = node { scrollTarget = title }
                    }
                )
            }
            .background(Theme.bg2)
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
                        if let search {
                            SettingsSearchPane(search: search).id("top")
                                .environment(\.settingsMarkedRow, resultCursor)
                        } else if let kept = tree.kept, !kept.contains(.page(tree.page)) {
                            NothingModified(page: kept.isEmpty ? nil : tree.page).id("top")
                        } else {
                            SettingsPageHeader(page: tree.page).id("top")
                            SettingsPageBody(page: tree.page).environment(\.settingsPage, tree.page)
                                .environment(\.settingsMarkedRow, flashed)
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
                .onPreferenceChange(SettingsSearchSpotsKey.self) { found in
                    let ordered = found.sorted { $0.minY < $1.minY }
                    if ordered.map(\.key) != spots.map(\.key) { spots = ordered }
                }
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
                .onChange(of: tree.page) { proxy.scrollTo("top", anchor: .top) }
                .onChange(of: resultCursor) {
                    guard let key = resultCursor else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
                }
                .onChange(of: model.settingsQuery) {
                    resultCursor = nil
                    proxy.scrollTo("top", anchor: .top)
                }
                // A row opened from the search: its section first (in case the row is not drawn there), then the row,
                // once the page is laid out; then the flash fades.
                .onChange(of: flashed) {
                    guard let key = flashed else { return }
                    let section = spotSection
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        if let section { proxy.scrollTo(section, anchor: .top) }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .center) }
                        try? await Task.sleep(for: .milliseconds(1400))
                        if flashed == key { flashed = nil }
                    }
                }
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
        // ⌘F while the Settings window is key: the search field (the main window never sees Settings' keys).
        .background {
            Button("") { focus = .search }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
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
                model.settingsQuery = ""
                tree.show(.page(asked))
                cursor = .page(asked)
                model.settingsPage = nil
            }
        }
        // `:settings.find` fills the field: the keyboard goes there, as ⌘F would.
        .onChange(of: model.settingsQuery, initial: true) { _, query in
            if !query.isEmpty, focus != .search, !ShotMode.active { focus = .search }
        }
        // A breadcrumb: the first of its card's rows, on its page.
        .onChange(of: model.settingsReveal) { _, asked in
            guard let asked else { return }
            model.settingsReveal = nil
            let spot = spots.first { spot in
                spot.page == asked.page && (asked.card == nil || spot.card == asked.card)
                    && (asked.target == nil || spot.target == asked.target)
            }
            if let spot { open(spot) } else { reveal(page: asked.page, entry: nil, target: asked.target) }
        }
    }

    /// The search the field holds; nil when it is empty.
    private var currentSearch: SettingsSearch? {
        let query = model.settingsQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        // The orgs and repos Orgs & repos lists, for an org or repo setting set nowhere yet.
        let repos = model.repos.map(\.repo)
        let orgs = Set(repos.map(\.org)).sorted { $0.lowercased() < $1.lowercased() }
        let known = orgs.map(SettingTarget.org) + repos.map { SettingTarget.repo($0.slug) }
        return SettingsCatalog.search(
            query, in: model.config, problems: model.configProblems,
            onlyModified: model.settingsFilter.onlyModified, known: known
        )
    }

    private func moveResult(_ offset: Int) {
        guard !spots.isEmpty else { return }
        let index = resultCursor.flatMap { key in spots.firstIndex { $0.key == key } }
        let next = index.map { min(max($0 + offset, 0), spots.count - 1) } ?? (offset > 0 ? 0 : spots.count - 1)
        resultCursor = spots[next].key
    }

    /// ↩: the row the cursor is on (the first when it has not moved), on its page.
    private func openResult() {
        guard let spot = spots.first(where: { $0.key == resultCursor }) ?? spots.first else { return }
        open(spot)
    }

    /// ⎋: the search goes, the tree has the keyboard.
    private func clearSearch() {
        model.settingsQuery = ""
        focus = .tree
    }

    private func open(_ spot: SettingsSearchSpot) {
        reveal(page: spot.page, entry: SettingsCatalog.entry(spot.ids[0]), target: spot.target)
        flashed = spot.key
    }

    /// Turns to a row's page: its tab, its agent, org or repo; Show advanced on when the row is advanced and would be
    /// hidden there. The search is cleared.
    private func reveal(page: SettingsPage, entry: SettingsEntry?, target: SettingTarget?) {
        if let entry {
            switch (page, target) {
            case let (.agents, .agent(name)?):
                model.settingsAgent = name
                if let tab = entry.tab { model.agentTab = tab }
            case (.pilot, _):
                if let tab = entry.tab { model.pilotTab = tab }
            case let (.orgsAndRepos, target?):
                if let scope = target.overrideScope { model.settingsScope = scope }
                if let tab = entry.tab?.overrideTab { model.orgRepoTab = tab }
            default:
                break
            }
            let ids = spots.first { $0.ids.contains(entry.id) }?.ids ?? [entry.id]
            if !model.settingsFilter.showAdvanced, !model.settingsFilter.onlyModified,
               SettingsCatalog.visibility(
                   ids, at: target ?? .global, in: model.config, problems: model.configProblems,
                   filter: model.settingsFilter
               ) == .hiddenAdvanced
            {
                model.settingsFilter.showAdvanced = true
            }
            spotSection = page.sections.contains(entry.section) ? entry.section : nil
        }
        model.settingsQuery = ""
        tree.show(.page(page))
        cursor = .page(page)
        focus = .tree
    }

    /// The section at the top of the pane: the last one whose name has scrolled up to it, else the first.
    static func inView(_ offsets: [String: CGFloat], sections: [String]) -> String? {
        sections.last { (offsets[$0] ?? .infinity) <= 60 } ?? sections.first
    }
}

/// The tree: groups that fold (▸ ▾), their pages, and the shown page's sections, each with the modified count
/// (`● 3`, a folded group too) and a red ! where config.toml has a value heed refused. Click a page to show it, a
/// section to scroll to it; with the tree focused ↑ ↓ move and ← → fold.
struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var tree: SettingsTree
    @Binding var cursor: SettingsNode
    var focus: FocusState<SettingsFocus?>.Binding
    let inView: String?
    let counts: SettingsCounts
    /// While searching: the tree keeps the pages with matches, each with how many, and a page picked moves the
    /// search's cursor to its first row.
    let search: SettingsSearch?
    let pickMatch: (SettingsPage) -> Void
    /// A line was picked (clicked or reached with the keys).
    let picked: (SettingsNode) -> Void

    private var focused: Bool { focus.wrappedValue == .tree }

    /// The tree drawn: the search's (its fold state untouched), else the tree.
    private var shown: SettingsTree { search.map { tree.searching($0) } ?? tree }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown.visible, id: \.self) { node in
                        line(node)
                    }
                    if search?.isEmpty == true {
                        Text("No matches.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    } else if search == nil, tree.kept?.isEmpty == true {
                        Text("Nothing is modified.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: .tree)
            .onKeyPress(.upArrow) { search == nil ? go(tree.move(cursor, by: -1)) : step(-1) }
            .onKeyPress(.downArrow) { search == nil ? go(tree.move(cursor, by: 1)) : step(1) }
            .onKeyPress(.leftArrow) { search == nil ? go(tree.left(cursor)) : .ignored }
            .onKeyPress(.rightArrow) { search == nil ? go(tree.right(cursor)) : .ignored }
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
    }

    private func go(_ node: SettingsNode) -> KeyPress.Result {
        cursor = node
        picked(node)
        return .handled
    }

    /// ↑ ↓ over the search's tree: its pages, each moving the search's cursor there.
    private func step(_ offset: Int) -> KeyPress.Result {
        let pages = shown.visible.filter { $0.page != nil && !$0.isSection }
        guard !pages.isEmpty else { return .handled }
        let index = pages.firstIndex(of: cursor).map { min(max($0 + offset, 0), pages.count - 1) } ?? 0
        cursor = pages[index]
        if let page = pages[index].page { pickMatch(page) }
        return .handled
    }

    private func line(_ node: SettingsNode) -> some View {
        let isCursor = focused && cursor == node
        return HStack(spacing: 6) {
            switch node {
            case let .group(group):
                Image(systemName: shown.folded.contains(node) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 10)
                Text(group.title).font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.fg2)
                Spacer(minLength: 4)
                if search == nil {
                    marks(modified: counts.modified(.group(group)), problems: counts.problems(.group(group)))
                }
            case let .page(page):
                Text(page.title).font(Theme.ui(13))
                    .foregroundStyle(tree.page == page && search == nil ? Theme.fg : Theme.fg2)
                    .padding(.leading, 16)
                Spacer(minLength: 4)
                if let search {
                    Text("\(search.count(page))").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        .help("\(search.count(page)) matching setting\(search.count(page) == 1 ? "" : "s")")
                } else {
                    marks(modified: counts.modified(.page(page)), problems: counts.problems(.page(page)))
                }
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
        .padding(.top, node.isGroup && node != shown.visible.first ? 8 : 0)
        .background(RoundedRectangle(cornerRadius: 5).fill(background(node)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isCursor ? Theme.keyCapBorder : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if let search {
                // Searching, a page moves the search's cursor to its first match; groups stay open.
                guard !node.isGroup, let page = node.page, search.count(page) > 0 else { return }
                cursor = node
                pickMatch(page)
                return
            }
            focus.wrappedValue = .tree
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
        if search == nil, case let .page(page) = node, page == tree.page { return Theme.bg3 }
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
