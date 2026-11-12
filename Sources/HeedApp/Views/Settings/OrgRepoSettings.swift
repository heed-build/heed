import HeedCore
import SwiftUI

/// Settings › Orgs & repos: every org and repo heed knows (from the repo list, and those only named in config.toml),
/// the ones that override something marked, and for the selected one each setting with its value and where that value
/// comes from. Changing one writes the override; ↺ removes it.
struct OrgRepoSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: OverrideScope?
    @State private var query = ""
    /// Only modified: the list keeps the orgs and repos that override something here, or have a value heed refused.
    private var onlyModified: Bool { model.settingsFilter.onlyModified }

    var body: some View {
        let groups = groups()
        let listed = groups.flatMap { [OverrideScope.org($0.org)] + $0.repos.map(OverrideScope.repo) }
        let shown = selected.flatMap { scope in !onlyModified || listed.contains(scope) ? scope : nil }
            ?? firstOverridden(groups) ?? groups.first.map { OverrideScope.org($0.org) }
        HStack(alignment: .top, spacing: 0) {
            ScopeList(query: $query, items: items(groups), selected: shown?.title) { title in
                selected = groups.flatMap { [OverrideScope.org($0.org)] + $0.repos.map(OverrideScope.repo) }
                    .first { $0.title == title }
            }
            .frame(width: ScopeList.width)
            Theme.line.frame(width: 1)
            if let scope = shown {
                // Takes what the list leaves, never more: rows fold to one column when it is narrow.
                ScopeDetail(scope: scope).padding(.leading, 18)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Repos appear here once the repo scan finds them.").foregroundStyle(Theme.fg3).padding(18)
            }
        }
        // `:setup.edit` opens the page on a repo.
        .onAppear(perform: takeRequestedScope)
        .onChange(of: model.settingsScope) { takeRequestedScope() }
    }

    private func takeRequestedScope() {
        guard let scope = model.settingsScope else { return }
        selected = scope
        model.settingsScope = nil
    }

    private struct Group {
        let org: String
        let repos: [Repo]
        let cloned: Set<String>
    }

    /// Orgs with their repos: cloned ones (local and on hosts, once each) and ones only config.toml names.
    private func groups() -> [Group] {
        var repos: [String: Repo] = [:]
        for record in model.repos {
            repos[record.repo.slug] = record.repo
        }
        let cloned = Set(repos.keys)
        var orgs = Set(repos.values.map(\.org))
        for scope in Overrides.configuredScopes(in: model.config) {
            switch scope {
            case let .org(name): orgs.insert(name)
            case let .repo(repo):
                orgs.insert(repo.org)
                if repos[repo.slug] == nil { repos[repo.slug] = repo }
            }
        }
        let words = query.lowercased()
        return orgs.sorted { $0.lowercased() < $1.lowercased() }.compactMap { org in
            let members = repos.values.filter { $0.org == org }.sorted { $0.name.lowercased() < $1.name.lowercased() }
                .filter { repo in
                    (words.isEmpty || repo.slug.lowercased().contains(words))
                        && (!onlyModified || isChanged(.repo(repo)))
                }
            let orgMatches = (words.isEmpty || org.lowercased().contains(words))
                && (!onlyModified || isChanged(.org(org)))
            guard orgMatches || !members.isEmpty else { return nil }
            return Group(org: org, repos: members, cloned: cloned)
        }
    }

    /// Where the page opens: the first repo that overrides something, else the first such org.
    private func firstOverridden(_ groups: [Group]) -> OverrideScope? {
        let repos = groups.flatMap(\.repos).map(OverrideScope.repo)
        let orgs = groups.map { OverrideScope.org($0.org) }
        return (repos + orgs).first { count($0) > 0 }
    }

    private func count(_ scope: OverrideScope) -> Int {
        Overrides.setKeys(at: scope, in: model.config).count
    }

    /// Overrides something, or has a value heed refused.
    private func isChanged(_ scope: OverrideScope) -> Bool {
        count(scope) > 0 || SettingsCatalog.counts(in: model.config, problems: model.configProblems)
            .problems(.target(.orgsAndRepos, scope.target)) > 0
    }

    /// The list: each org, then its repos (cut in the middle when long, the whole name on hover), with the
    /// overrides each holds and a red ! where config.toml has a value heed refused there.
    private func items(_ groups: [Group]) -> [ScopeList.Item] {
        let counts = SettingsCatalog.counts(in: model.config, problems: model.configProblems)
        return groups.flatMap { group -> [ScopeList.Item] in
            let org = OverrideScope.org(group.org)
            return [ScopeList.Item(
                id: org.title, title: group.org, bold: true, leading: .org(group.org), count: count(org),
                problems: counts.problems(.target(.orgsAndRepos, .org(group.org)))
            )] + group.repos.map { repo in
                let cloned = group.cloned.contains(repo.slug)
                return ScopeList.Item(
                    id: OverrideScope.repo(repo).title, title: repo.name, mono: true, indent: 16,
                    note: cloned ? nil : "not cloned", count: count(.repo(repo)),
                    problems: counts.problems(.target(.orgsAndRepos, .repo(repo.slug))), dimmed: !cloned,
                    help: repo.slug
                )
            }
        }
    }
}

/// One org or repo: each setting, its value, where it comes from, and ↺ to drop an override.
private struct ScopeDetail: View {
    @Environment(AppModel.self) private var model
    let scope: OverrideScope

    var body: some View {
        let config = model.config
        let set = Overrides.setKeys(at: scope, in: config)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(scope.title).font(Theme.mono(15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .help(scope.title)
                Text(summary(set: set)).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let counts = Overrides.overrideCounts(at: scope, in: config)
            let refused = SettingsCatalog.counts(in: config, problems: model.configProblems)
            // Only modified keeps the tabs holding an override or a refused value, and shows one of them.
            let (tabs, tab) = model.settingsFilter.tabs(OverrideTab.allCases, current: model.orgRepoTab) { tab in
                (counts[tab] ?? 0) > 0 || refused.problems(.tab(.orgsAndRepos, scope.target, SettingsTab(tab))) > 0
            }
            OverrideTabStrip(tabs: tabs, current: tab, counts: counts)
            let keys = Overrides.keys(for: scope, on: tab, in: config)
            // Only modified empties a tab only when nothing here is overridden; a repo's tasks count as an override
            // on theirs, so they are not "nothing".
            if tabs.isEmpty {
                Text("Nothing is overridden here.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            OverrideCards(scope: scope, keys: keys)
            if tab == Overrides.tab(of: "tasks"), case let .repo(repo) = scope,
               let tasks = config.repos[repo.slug]?.tasks, !tasks.isEmpty
            {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tasks").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    ForEach(tasks, id: \.0) { name, command in
                        Text("\(name) = \(command)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                    }
                    Text("Edited in config.toml ([repos.\"\(repo.slug)\".tasks]).")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
    }

    private func summary(set: [String]) -> String {
        let own = "\(set.count) override\(set.count == 1 ? "" : "s") here"
        guard case let .repo(repo) = scope else {
            return set.isEmpty ? "Uses the defaults; its repos take what it sets." : own + "; its repos take them."
        }
        let fromOrg = Overrides.setKeys(at: .org(repo.org), in: model.config).count
        return own + (fromOrg > 0 ? " · \(fromOrg) inherited from \(repo.org)" : "")
    }
}

/// A tab's settings at one org or repo, a card per group.
private struct OverrideCards: View {
    @Environment(AppModel.self) private var model
    let scope: OverrideScope
    let keys: [OverrideKey]

    var body: some View {
        let sections = keys.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(sections, id: \.self) { section in
            SettingsCard(title: section) {
                ForEach(keys.filter { $0.group == section }, id: \.id) { key in
                    OverrideRow(scope: scope, key: key)
                    if key.id == "setup", case let .repo(repo) = scope,
                       let proposal = model.setupProposal(for: repo)
                    {
                        SetupProposalLine(repo: repo, proposal: proposal)
                    }
                }
            }
        }
    }
}

/// Search's matches on Orgs & repos: at each org or repo, each tab holding one, that tab's cards with only the
/// matching rows, under `Orgs & repos › acme › Get it green`.
struct OrgRepoSearchResults: View {
    @Environment(AppModel.self) private var model
    let search: SettingsSearch

    var body: some View {
        let matches = search.matches(on: .orgsAndRepos).filter { !SettingsSearchPane.hasNoRow($0) }
        let scopes = matches.compactMap { $0.target?.overrideScope }
            .reduce(into: [OverrideScope]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(scopes, id: \.title) { scope in
            let tabs = OverrideTab.allCases.filter { tab in
                matches.contains { $0.target == scope.target && $0.entry.tab?.overrideTab == tab }
            }
            ForEach(tabs) { tab in
                OverrideCards(scope: scope, keys: Overrides.keys(for: scope, on: tab, in: model.config))
                    .environment(\.settingsCrumbs, [SettingsPage.orgsAndRepos.title, scope.title, tab.title])
                    .environment(\.settingsCrumbTarget, scope.target)
            }
        }
    }
}

/// The form's tabs, as the title bar draws its views: each with the overrides it holds at this org or repo (`● 2`,
/// as the list marks them), ⌘1–⌘5 to turn to one. Under Only modified only the tabs holding one show. The tab is the
/// same for every org and repo, and kept between launches. A narrow window gets the short names, and at its narrowest
/// they take two lines, so no tab is ever cut off.
private struct OverrideTabStrip: View {
    @Environment(AppModel.self) private var model
    let tabs: [OverrideTab]
    let current: OverrideTab
    let counts: [OverrideTab: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                strip(tabs, short: false)
                strip(tabs, short: true)
                VStack(alignment: .leading, spacing: 4) {
                    strip(Array(tabs.prefix(3)), short: true)
                    strip(Array(tabs.dropFirst(3)), short: true)
                }
            }
            Theme.line.frame(height: 1)
        }
    }

    private func strip(_ tabs: [OverrideTab], short: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let index = OverrideTab.allCases.firstIndex(of: tab) ?? 0
                // A hairline between tabs: separate without boxing them in.
                if tab != tabs.first { Theme.line.frame(width: 1, height: 14) }
                let count = counts[tab] ?? 0
                Button {
                    model.orgRepoTab = tab
                } label: {
                    TabLabel(
                        title: short ? tab.shortTitle : tab.title,
                        active: current == tab,
                        count: count > 0 ? "● \(count)" : nil
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help(
                    "\(tab.title): \(count == 0 ? "no" : "\(count)") override\(count == 1 ? "" : "s") here (⌘\(index + 1))"
                )
            }
        }
    }
}

private struct OverrideRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsSearch) private var search
    let scope: OverrideScope
    let key: OverrideKey

    private var id: String { "override.\(key.id)" }

    var body: some View {
        let (value, source) = Overrides.effective(key, at: scope, in: model.config)
        let own = Overrides.value(key, at: scope, in: model.config) != nil
        let problems = Self.problems(key, at: scope, in: model.configProblems)
        let visibility: SettingVisibility = if let search {
            search.contains([id], at: scope.target) ? .shown : .hidden
        } else {
            SettingsCatalog.visibility(
                [id], at: scope.target, in: model.config, problems: model.configProblems, filter: model.settingsFilter
            )
        }
        if visibility == .shown {
            row(value: value, source: source, own: own, problems: problems)
                .settingsSearchRow([id], target: scope.target)
                .settingsLine(.shown)
        } else {
            EmptyView().settingsLine(visibility)
        }
    }

    private func row(value: OverrideValue, source: OverrideSource, own: Bool, problems: [SettingProblem])
        -> some View
    {
        // Label beside the control when the pane is wide enough; else the control under the label, as wide as the
        // pane allows. Nothing is ever wider than the pane.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                label(source: source, own: own).frame(width: 240, alignment: .leading)
                editor(value)
                Spacer(minLength: 0)
                reset(own: own)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    label(source: source, own: own).frame(maxWidth: .infinity, alignment: .leading)
                    reset(own: own)
                }
                editor(value)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if !problems.isEmpty {
                Theme.err.frame(width: 3)
            } else if own {
                Theme.block.frame(width: 3)
            }
        }
    }

    /// The values config.toml has for this key here that heed refused, from the catalog.
    static func problems(_ key: OverrideKey, at scope: OverrideScope, in problems: [ConfigProblem])
        -> [SettingProblem]
    {
        guard let entry = SettingsCatalog.entry("override.\(key.id)") else { return [] }
        return SettingsCatalog.problems(for: entry, at: scope.target, in: problems)
    }

    private func label(source: OverrideSource, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(searchHighlighted(key.label, search)).font(Theme.ui(13))
                    .foregroundStyle(own ? Theme.fg : Theme.fg2)
                if search != nil, SettingsCatalog.entry(id)?.level == .advanced { AdvancedTag() }
                Text(source.rawValue)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(own ? Theme.block : Theme.fg3)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(own ? Theme.block.opacity(0.16) : Theme.chip))
            }
            if let search, let entry = SettingsCatalog.entry(id), search.matchesKey(entry) {
                Text(searchHighlighted(SettingsCatalog.keyText(scope.path + [key.id]), search)).font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
            }
            Text(searchHighlighted(key.detail, search)).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.problems(key, at: scope, in: model.configProblems), id: \.self) { problem in
                Text("config.toml: \(problem.reason). Like \(problem.example)")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reset(own: Bool) -> some View {
        Button {
            model.unsetConfig(scope.path + [key.id])
        } label: {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(own ? Theme.fg2 : Theme.fg3.opacity(0.3))
        .disabled(!own)
        .help(own ? "Use the inherited value" : "Not overridden here")
    }

    private var path: [String] { scope.path + [key.id] }

    private func text(_ value: OverrideValue) -> String? {
        if case let .text(text) = value, !text.isEmpty { text } else { nil }
    }

    @ViewBuilder private func editor(_ value: OverrideValue) -> some View {
        switch key.kind {
        case .bool:
            Toggle("", isOn: Binding(
                get: { if case let .bool(on) = value { on } else { false } },
                set: { model.setConfig(path, .bool($0)) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.done)
            .labelsHidden()
        case let .choice(options):
            Picker("", selection: Binding(
                get: { if case let .text(text) = value { text } else { "" } },
                // Empty (default, the session's) is the override removed: the value inherits.
                set: { $0.isEmpty ? model.unsetConfig(path) : model.setConfig(path, .string($0)) }
            )) {
                ForEach(options, id: \.self) { Text($0.isEmpty ? "default" : $0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 160)
        case .agent:
            Picker("", selection: Binding(
                get: { if case let .text(text) = value { text } else { "" } },
                // Empty (default, the session's) is the override removed: the value inherits.
                set: { $0.isEmpty ? model.unsetConfig(path) : model.setConfig(path, .string($0)) }
            )) {
                Text("the session's").tag("")
                ForEach(model.settings.agents.map(\.name), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 160)
        case let .model(agentKey):
            let agent = Overrides.pickerAgent(agentKey, at: scope, in: model.config)
            ModelMenuPicker(
                catalog: model.modelCatalog(agent), value: text(value),
                // The default is the override removed: the value inherits.
                set: { $0.map { model.setConfig(path, .string($0)) } ?? model.unsetConfig(path) }
            )
        case let .effort(agentKey, modelKey):
            let agent = Overrides.pickerAgent(agentKey, at: scope, in: model.config)
            let catalog = model.modelCatalog(agent)
            if ModelPicker.efforts(catalog, model: nil).isEmpty, text(value) == nil {
                Text("\(agent) takes no effort").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            } else {
                EffortMenuPicker(
                    catalog: catalog, model: Overrides.pickerModel(modelKey, at: scope, in: model.config),
                    value: text(value),
                    set: { $0.map { model.setConfig(path, .string($0)) } ?? model.unsetConfig(path) }
                )
            }
        case let .integer(range):
            let current = if case let .integer(number) = value { number } else { range.lowerBound }
            Stepper(value: Binding(get: { current }, set: { model.setConfig(path, .integer($0)) }), in: range) {
                Text("\(current)").font(Theme.mono(12.5))
            }
        case .list, .text:
            OverrideTextField(path: path, value: value, list: key.kind == .list)
        case .repoSlug:
            OverrideTextField(path: path, value: value, list: false, placeholder: "org/name", emptyInherits: true)
        case .instructions:
            InstructionsField(path: path, value: { if case let .text(text) = value { text } else { "" } }(), width: 300)
        case .color:
            let current = if case let .text(text) = value { text } else { "" }
            HStack(spacing: 8) {
                ForEach(OrgPalette.allCases, id: \.self) { palette in
                    Circle()
                        .fill(palette.swatch)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Theme.fg, lineWidth: current == palette.rawValue ? 2 : 0)
                            .padding(-3))
                        .onTapGesture { model.setConfig(path, .string(palette.rawValue)) }
                }
            }
        }
    }
}

/// A repo whose setup is unset, and what heed detected for it: approve it, or never run any.
private struct SetupProposalLine: View {
    @Environment(AppModel.self) private var model
    let repo: Repo
    let proposal: SetupProposal

    var body: some View {
        HStack(spacing: 10) {
            Text("detected: \(proposal.commands.joined(separator: " && "))")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(2).truncationMode(.middle)
                .help(proposal.lines.joined(separator: "\n"))
            Button("Approve") { model.setConfig(
                ["repos", repo.slug, "setup"],
                .array(proposal.commands.map { .string($0) })
            ) }
            Button("Never") { model.setConfig(["repos", repo.slug, "setup"], .array([])) }
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Text and list overrides: written when you press return or leave the field.
private struct OverrideTextField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: OverrideValue
    let list: Bool
    var placeholder: String?
    /// Emptied, the override is removed (the value inherits) rather than set to "".
    var emptyInherits = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: String {
        switch value {
        case let .list(values): values.joined(separator: ", ")
        case let .text(text): text
        default: ""
        }
    }

    var body: some View {
        TextField(placeholder ?? (list ? "comma separated" : ""), text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12))
            .frame(minWidth: 120, idealWidth: 220, maxWidth: 220)
            .focused($focused)
            .onAppear { text = shown }
            .onChange(of: shown) { if !focused { text = shown } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != shown else { return }
        if list {
            let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            model.setConfig(path, .array(values.map { .string($0) }))
        } else if emptyInherits, text.trimmingCharacters(in: .whitespaces).isEmpty {
            model.unsetConfig(path)
            text = shown
        } else {
            model.setConfig(path, .string(text))
        }
    }
}

extension OverrideScope {
    /// The org or repo as the catalog has it.
    var target: SettingTarget {
        switch self {
        case let .org(name): .org(name)
        case let .repo(repo): .repo(repo.slug)
        }
    }
}
