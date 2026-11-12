import HeedCore
import SwiftUI

/// Settings › Agents: Orgs & repos' two panes for agents. The list has Every agent (what they share, on the pages it
/// lives on) and each agent with what it is (✓ ready, ○ not installed, ! broken and why) and how many settings it
/// changes; the detail has its name, a status line and two tabs, Sessions and Model calls, each with its count.
struct AgentsPage: View {
    @Environment(AppModel.self) private var model
    /// The agent shown; "" is Every agent.
    @State private var selected = "claude"
    @State private var query = ""

    static let every = ""

    var body: some View {
        let counts = SettingsCatalog.counts(in: model.config, problems: model.configProblems)
        let onlyModified = model.settingsFilter.onlyModified
        // Only modified keeps the agents with a change; Every agent holds none of its own.
        let agents = model.config.work.agents.filter { agent in
            !onlyModified || counts.isChanged(.target(.agents, .agent(agent.name)))
        }
        let shown = if agents.contains(where: { $0.name == selected }) || (selected == Self.every && !onlyModified) {
            selected
        } else {
            onlyModified ? agents.first?.name ?? Self.every : Self.every
        }
        HStack(alignment: .top, spacing: 0) {
            ScopeList(query: $query, items: items(agents, counts: counts), selected: shown) { selected = $0 }
                .frame(width: ScopeList.width)
            Theme.line.frame(width: 1)
            Group {
                if let agent = agents.first(where: { $0.name == shown }) {
                    AgentDetail(agent: agent, counts: counts)
                } else if onlyModified {
                    Text("No agent's settings are modified.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                } else {
                    EveryAgentDetail()
                }
            }
            .padding(.leading, 18)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: takeRequestedAgent)
        .onChange(of: model.settingsAgent) { takeRequestedAgent() }
        .task {
            guard !model.isFixture else { return }
            await model.refreshLLMStatuses()
        }
    }

    private func takeRequestedAgent() {
        guard let agent = model.settingsAgent else { return }
        selected = agent
        model.settingsAgent = nil
    }

    private func items(_ agents: [AgentProfile], counts: SettingsCounts) -> [ScopeList.Item] {
        let words = query.lowercased()
        var items: [ScopeList.Item] = []
        if words.isEmpty || "every agent".contains(words), !model.settingsFilter.onlyModified {
            items.append(.init(
                id: Self.every, title: "Every agent", leading: .glyph("≡", Theme.fg3),
                help: "What every agent shares: the default agent, and model calls' switch and limits"
            ))
        }
        for agent in agents where words.isEmpty || agent.name.lowercased().contains(words) {
            let target = SettingTarget.agent(agent.name)
            let readiness = model.agentReadiness(agent)
            let color: Color = switch readiness {
            case .ready: Theme.done
            case .notInstalled, .unchecked: Theme.fg3
            case .broken: Theme.err
            }
            items.append(.init(
                id: agent.name, title: agent.name, mono: true, leading: .glyph(readiness.glyph, color),
                note: readiness.note, noteColor: readiness == .notInstalled ? Theme.fg3 : Theme.fg2,
                count: counts.modified(.target(.agents, target)), problems: counts.problems(.target(.agents, target)),
                dimmed: readiness == .notInstalled
            ))
        }
        return items
    }
}

extension AppModel {
    /// What Settings › Agents says of an agent: detection, and how its last test went.
    func agentReadiness(_ agent: AgentProfile) -> AgentReadiness {
        let status = llmStatuses.first { $0.name == agent.name }
        let test = llmTests[agent.name]
        return AgentReadiness.of(agent, status: status, lastTestFailed: test?.running == false && test?.error != nil)
    }
}

/// What every agent shares. Each lives on one page; this says what it is and leads there.
private struct EveryAgentDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let llm = model.config.llm
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Every agent").font(Theme.ui(15, weight: .semibold))
                Text("What the agents share. Each is set on the page it lives on.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            SettingsCard(title: "Shared") {
                InfoRow(label: "Default agent", detail: "The agent Start work picks when nothing else does.") {
                    HStack(spacing: 10) {
                        Text(model.config.work.defaultAgent).font(Theme.mono(12.5))
                        PageLink(page: .general)
                    }
                }
                InfoRow(label: "Model calls", detail: "heed's own short calls, and which agent takes them.") {
                    HStack(spacing: 10) {
                        Text(
                            llm.enabled ? llm.agent.map { $0 == LLMSettings.auto ? "taking turns" : $0 } ?? "not set up"
                                : "off"
                        )
                        .font(Theme.mono(12.5))
                        PageLink(page: .modelCalls)
                    }
                }
                InfoRow(label: "Limits", detail: "Per agent per day, and for every call.") {
                    HStack(spacing: 10) {
                        Text("\(llm.dailyCalls == 0 ? "no cap" : "\(llm.dailyCalls) calls") · "
                            + "$\(DollarsField.text(llm.dailyDollars)) · \(llm.timeoutSeconds) s")
                            .font(Theme.mono(12.5))
                        PageLink(page: .modelCalls)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Custom agents: add an [agents.<name>] table with a command in config.toml.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                EditInConfigButton(title: "Open config.toml")
            }
        }
    }
}

/// Search's matches on Agents: at each agent, each tab holding one, that tab's cards with only the matching rows,
/// under `Agents › claude › Sessions`.
struct AgentsSearchResults: View {
    @Environment(AppModel.self) private var model
    let search: SettingsSearch

    var body: some View {
        let matches = search.matches(on: .agents)
        let names = matches.compactMap { match -> String? in
            if case let .agent(name)? = match.target { name } else { nil }
        }
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(names, id: \.self) { name in
            if let agent = model.config.work.agent(name) {
                let tabs = SettingsPage.agents.tabs.filter { tab in
                    matches.contains { $0.target == .agent(name) && $0.entry.tab == tab }
                }
                ForEach(tabs, id: \.self) { tab in
                    Group {
                        switch tab {
                        case .modelCalls:
                            AgentModelCalls(agent: agent, status: model.llmStatuses.first { $0.name == name })
                        default: AgentSessions(agent: agent)
                        }
                    }
                    .environment(\.settingsCrumbs, [SettingsPage.agents.title, name, tab.title])
                    .environment(\.settingsCrumbTarget, .agent(name))
                }
            }
        }
    }
}

/// One agent: its name, what it is, and its two tabs.
private struct AgentDetail: View {
    @Environment(AppModel.self) private var model
    let agent: AgentProfile
    let counts: SettingsCounts

    var body: some View {
        let target = SettingTarget.agent(agent.name)
        let status = model.llmStatuses.first { $0.name == agent.name }
        let readiness = model.agentReadiness(agent)
        let modified = counts.modified(.target(.agents, target))
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(Theme.mono(16, weight: .semibold))
                statusLine(status: status, readiness: readiness, modified: modified)
            }
            let (tabs, tab) = model.settingsFilter.tabs(SettingsPage.agents.tabs, current: model.agentTab) {
                counts.isChanged(.tab(.agents, target, $0))
            }
            SettingsTabStrip(
                tabs: tabs, current: tab,
                count: { counts.modified(.tab(.agents, target, $0)) }, pick: { model.agentTab = $0 }
            )
            switch tab {
            case .modelCalls: AgentModelCalls(agent: agent, status: status)
            default: AgentSessions(agent: agent)
            }
        }
    }

    /// `✓ installed · logged in · full hooks · 2 modified`, the count in amber.
    private func statusLine(status: LLMAgentStatus?, readiness: AgentReadiness, modified: Int) -> some View {
        let color: Color = switch readiness {
        case .ready: Theme.done
        case .notInstalled, .unchecked: Theme.fg3
        case .broken: Theme.err
        }
        let plain = AgentReadiness.statusLine(agent, status: status, readiness: readiness, modified: 0)
        let count = modified > 0 ? Text(" · \(modified) modified").foregroundStyle(Theme.block) : Text("")
        return (Text("\(readiness.glyph) ").foregroundStyle(color) + Text(plain).foregroundStyle(Theme.fg2) + count)
            .font(Theme.ui(12.5))
    }
}

/// Sessions: how the agent runs in a pane.
private struct AgentSessions: View {
    @Environment(AppModel.self) private var model
    let agent: AgentProfile

    var body: some View {
        let target = SettingTarget.agent(agent.name)
        let path = ["agents", agent.name]
        let builtIn = AgentProfile.builtIn.contains { $0.name == agent.name }
        SettingsCard(title: "Starting") {
            SettingRow("agent.command", target: target, resettable: builtIn) {
                ConfigTextField(path: path + ["command"], value: agent.command, width: 200)
            }
            SettingRow("agent.prompt", target: target) {
                SegmentedChoice(
                    path: path + ["prompt"], value: agent.prompt,
                    options: PromptDelivery.allCases.map { ($0, $0.rawValue) }, name: \.rawValue, width: 270
                )
            }
            if agent.modelFlag != nil || agent.effortFlag != nil {
                SettingRow(
                    "agent.model", "agent.effort", target: target, label: "Model and effort",
                    detail: "What its sessions start on when nothing else picks one (Start work, a swarm, a handoff).",
                    defaultText: "the agent's own"
                ) {
                    ConfigModelPicker(
                        agent: agent.name, modelPath: path + ["model"], modelValue: agent.model,
                        effortPath: agent.effortFlag == nil ? nil : path + ["effort"], effortValue: agent.effort,
                        defaultLabel: "\(agent.name)'s own default", effortDefaultLabel: "its own default"
                    )
                }
            }
            SettingRow("agent.plan", target: target) {
                ConfigTextField(path: path + ["plan"], value: agent.planArguments ?? "", width: 200)
            }
            SettingRow("agent.resume", target: target) {
                ConfigTextField(path: path + ["resume"], value: agent.resumeArguments ?? "", width: 200)
            }
        }
        SettingsCard(title: "Command line") {
            SettingRow("agent.model_flag", target: target) {
                ConfigTextField(path: path + ["model_flag"], value: agent.modelFlag ?? "", width: 200)
            }
            SettingRow("agent.effort_flag", target: target) {
                ConfigTextField(path: path + ["effort_flag"], value: agent.effortFlag ?? "", width: 200)
            }
            SettingRow("agent.profiles", target: target) {
                TableSummary(count: agent.profiles.count, noun: "profile")
            }
            SettingRow("agent.patterns", target: target) {
                TableSummary(count: agent.patterns.count, noun: "pattern")
            }
        }
        SettingsCard(title: "State") {
            InfoRow(
                label: "Hooks",
                detail: "Passed per run where the agent takes them; your own agent config is never "
                    + "edited."
            ) {
                Text(Self.hooks(agent.name)).font(Theme.mono(12))
                    .foregroundStyle(AgentReadiness.hooks(agent.name) == "reads the screen" ? Theme.fg2 : Theme
                        .done)
            }
        }
    }

    static func hooks(_ name: String) -> String {
        switch name {
        case "claude": "full hooks (--settings) ✓"
        case "codex": "hooks (-c) ✓"
        case "cursor": "project hooks (in the worktree) ✓"
        case "pi": "extension (-e) ✓"
        case "opencode": "plugin (OPENCODE_CONFIG_CONTENT) ✓"
        default: "read from the terminal"
        }
    }
}

/// A table of your own keys Settings only counts: how many, and where to edit them.
struct TableSummary: View {
    let count: Int
    let noun: String

    var body: some View {
        HStack(spacing: 10) {
            Text(count == 0 ? "none" : "\(count) \(noun)\(count == 1 ? "" : "s")").font(Theme.mono(12))
                .foregroundStyle(count == 0 ? Theme.fg3 : Theme.fg)
            EditInConfigButton()
        }
    }
}

/// Model calls: the agent's part in heed's own calls (`[llm]`): on or off, its login, its model, and a Test.
private struct AgentModelCalls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsSearch) private var search
    let agent: AgentProfile
    let status: LLMAgentStatus?

    var body: some View {
        let target = SettingTarget.agent(agent.name)
        let settings = model.config.llm
        if LLMDialect.of(agent) == nil, search == nil {
            Text("Custom agents take no part in heed's own model calls (summaries, decisions).")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        } else {
            SettingsCard(title: "Model calls") {
                SettingRow("agent.llm", target: target) {
                    ConfigSwitch(path: ["agents", agent.name, "llm"], isOn: settings.isEnabled(agent.name))
                        .disabled(!settings.enabled)
                }
                InfoRow(label: "Login", detail: loginDetail) {
                    HStack(spacing: 10) {
                        Text(loginText).font(Theme.mono(12)).foregroundStyle(loginColor)
                        Button("Check again") { Task { await model.refreshLLMStatuses(force: true) } }
                            .buttonStyle(.link)
                            .font(Theme.ui(12))
                    }
                }
                SettingRow(
                    "agent.llm_model", target: target,
                    defaultText: status?.detectedModel.map { "\($0), detected" } ?? "the agent's own"
                ) {
                    ConfigModelPicker(
                        agent: agent.name, modelPath: ["agents", agent.name, "llm_model"],
                        modelValue: settings.model(for: agent.name),
                        defaultLabel: status?.detectedModel.map { "detected (\($0))" }
                    )
                }
                InfoRow(label: "Test", detail: "One tiny call to this agent alone; it shows in :log.") {
                    TestResult(agent: agent.name)
                }
                if !settings.enabled {
                    CardNote {
                        Text("Model calls are off for every agent: heed makes none at all.")
                            .foregroundStyle(Theme.block)
                        PageLink(page: .modelCalls)
                    }
                }
            }
        }
    }

    private var loginText: String {
        switch status?.login {
        case .loggedIn: "logged in"
        case .loggedOut: "not logged in"
        case .unknown: "installed (no login check: a failed call says)"
        case .notInstalled: "\(agent.command.split(separator: " ").first.map(String.init) ?? agent.command) not found"
        case nil: "checking…"
        }
    }

    private var loginColor: Color {
        switch status?.login {
        case .loggedIn: Theme.done
        case .unknown: Theme.fg2
        case .loggedOut, .notInstalled: Theme.block
        case nil: Theme.fg3
        }
    }

    private var loginDetail: String {
        switch status?.login {
        case .notInstalled:
            "heed runs it without your shell, so an alias or shell function does not count: set Command to its path, "
                + "or add its folder to [tools] path."
        case .loggedOut: "Log in with the agent itself; heed only uses logins you already have."
        default: status?.path.map(Paths.abbreviate) ?? ""
        }
    }
}

/// The Test button, and how the last test went.
private struct TestResult: View {
    @Environment(AppModel.self) private var model
    let agent: String

    var body: some View {
        let test = model.llmTests[agent]
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let test, !test.running {
                if let error = test.error {
                    Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err).lineLimit(2)
                        .frame(maxWidth: 260, alignment: .trailing)
                } else {
                    Text(summary(test)).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                }
            }
            Button(test?.running == true ? "Testing…" : "Test") { model.testLLM(agent: agent) }
                .disabled(test?.running == true)
        }
    }

    private func summary(_ test: LLMTest) -> String {
        var parts = ["“\(test.answer ?? "")”"]
        if let model = test.model { parts.append(model) }
        if let seconds = test.seconds { parts.append(String(format: "%.1fs", seconds)) }
        // A test costs a fraction of a cent: shown to four places, not as <$0.01.
        if let cost = test.cost { parts.append(cost < 0.01 ? String(format: "$%.4f", cost) : AgentUsage.dollars(cost)) }
        return parts.joined(separator: " · ")
    }
}
