import HeedCore
import SwiftUI

/// Settings › Orgs & repos: every org and repo heed knows (from the repo list, and those only named in config.toml),
/// the ones that override something marked, and for the selected one each setting with its value and where that value
/// comes from. Changing one writes the override; ↺ removes it.
struct OrgRepoSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: OverrideScope?
    @State private var query = ""
    @State private var onlyOverridden = false

    var body: some View {
        let groups = groups()
        let shown = selected ?? firstOverridden(groups) ?? groups.first.map { OverrideScope.org($0.org) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Orgs & repos").font(Theme.ui(17, weight: .semibold))
            Text("Orgs and repos can override the defaults: color, issues, goal trackers, and every Pilot setting. A "
                + "repo takes its org's values unless it sets its own. Marked ones override something.")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 0) {
                list(groups, shown: shown).frame(width: Self.listWidth)
                Theme.line.frame(width: 1)
                if let scope = shown {
                    // Takes what the list leaves, never more: rows fold to one column when it is narrow.
                    ScopeDetail(scope: scope).padding(.leading, 18)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Repos appear here once the repo scan finds them.").foregroundStyle(Theme.fg3).padding(18)
                }
            }
        }
        // `:setup.edit` opens the page on a repo.
        .onAppear(perform: takeRequestedScope)
        .onChange(of: model.settingsScope) { takeRequestedScope() }
    }

    /// Wide enough for most repo names; longer ones are cut in the middle, the full name on hover.
    static let listWidth: CGFloat = 210

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
                        && (!onlyOverridden || count(.repo(repo)) > 0)
                }
            let orgMatches = (words.isEmpty || org.lowercased().contains(words))
                && (!onlyOverridden || count(.org(org)) > 0)
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

    private func list(_ groups: [Group], shown: OverrideScope?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder).font(Theme.ui(12))
            Toggle("Only overridden", isOn: $onlyOverridden).font(Theme.ui(12)).padding(.vertical, 6)
            ForEach(groups, id: \.org) { group in
                row(.org(group.org), indent: 0, cloned: true, shown: shown)
                ForEach(group.repos, id: \.slug) { repo in
                    row(.repo(repo), indent: 16, cloned: group.cloned.contains(repo.slug), shown: shown)
                }
            }
        }
        .padding(.trailing, 12)
    }

    private func row(_ scope: OverrideScope, indent: CGFloat, cloned: Bool, shown: OverrideScope?) -> some View {
        let overrides = count(scope)
        let isSelected = shown == scope
        return HStack(spacing: 6) {
            switch scope {
            case let .org(name):
                OrgTile(org: name, color: Palette.shared.color(for: Repo(org: name, name: "")), size: 14)
                Text(name).font(Theme.ui(12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            case let .repo(repo):
                Text(repo.name).font(Theme.mono(12)).foregroundStyle(cloned ? Theme.fg : Theme.fg3)
                    .lineLimit(1).truncationMode(.middle)
                if !cloned {
                    Text("not cloned").font(Theme.ui(10.5)).foregroundStyle(Theme.fg3).fixedSize()
                }
            }
            Spacer(minLength: 4)
            if overrides > 0 {
                Text("● \(overrides)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.block)
                    .help("\(overrides) override\(overrides == 1 ? "" : "s")")
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.bg3 : .clear))
        .contentShape(Rectangle())
        .help(scope.title)
        .onTapGesture { selected = scope }
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
            let keys = Overrides.keys(for: scope)
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                if index == 0 || keys[index - 1].group != key.group {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: key.group)
                        Theme.line.frame(height: 1)
                    }
                    .padding(.top, index == 0 ? 0 : 10)
                }
                OverrideRow(scope: scope, key: key)
                if key.id == "setup", case let .repo(repo) = scope, let proposal = model.setupProposal(for: repo) {
                    SetupProposalLine(repo: repo, proposal: proposal)
                }
            }
            if case let .repo(repo) = scope, let tasks = config.repos[repo.slug]?.tasks, !tasks.isEmpty {
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

private struct OverrideRow: View {
    @Environment(AppModel.self) private var model
    let scope: OverrideScope
    let key: OverrideKey

    var body: some View {
        let (value, source) = Overrides.effective(key, at: scope, in: model.config)
        let own = Overrides.value(key, at: scope, in: model.config) != nil
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
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if own { Theme.block.frame(width: 2).offset(x: -10) }
        }
    }

    private func label(source: OverrideSource, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(key.label).font(Theme.ui(13)).foregroundStyle(own ? Theme.fg : Theme.fg2)
                Text(source.rawValue)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(own ? Theme.block : Theme.fg3)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(own ? Theme.block.opacity(0.16) : Theme.chip))
            }
            Text(key.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private func editor(_ value: OverrideValue) -> some View {
        switch key.kind {
        case .bool:
            Toggle("", isOn: Binding(
                get: { if case let .bool(on) = value { on } else { false } },
                set: { model.setConfig(path, .bool($0)) }
            )).labelsHidden()
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
