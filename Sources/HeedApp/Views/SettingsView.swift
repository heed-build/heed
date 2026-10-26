import HeedCore
import SwiftUI

/// Settings (⌘,): a view of config.toml that writes single values back into it, comments and layout kept. Key
/// bindings are shown but edited only in the file. design/screens/Agents.png, Colors.png.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section

    /// Opens on `section` (General; screenshots open others).
    init(section: Section = .general) {
        _section = State(initialValue: section)
    }

    enum Section: String, CaseIterable, Identifiable {
        /// `:settings.open <name>`: the first word of the section's title, or a short name.
        static func named(_ name: String) -> Section? {
            let key = name.lowercased()
            let short: [String: Section] = [
                "general": .general, "agents": .agents, "colors": .colors, "repos": .colors, "orgs": .colors,
                "cleanup": .cleanup,
                "worktrees": .cleanup, "keys": .keys, "modes": .keys, "pilot": .pilot, "attention": .attention,
                "rules": .attention, "hosts": .hosts, "ssh": .hosts,
            ]
            return short[key]
        }

        case general = "General", agents = "Agents", colors = "Orgs & repos", hosts = "Hosts"
        case cleanup = "Worktrees & cleanup", pilot = "Pilot", attention = "Attention", keys = "Keys & modes"

        var id: String { rawValue }
    }

    var body: some View {
        content
            // `:settings.open agents` turns the window to that section, open or not.
            .onChange(of: model.settingsSection, initial: true) { _, asked in
                if let asked {
                    section = asked
                    model.settingsSection = nil
                }
            }
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { item in
                    Text(item.rawValue)
                        .font(Theme.ui(13))
                        .foregroundStyle(section == item ? Theme.fg : Theme.fg2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(section == item ? Theme.bg3 : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { section = item }
                }
                Spacer()
                Button("Open config.toml") { NSWorkspace.shared.open(model.configFile) }
                    .buttonStyle(.link)
                    .padding(14)
                Text(Paths.abbreviate(model.configFile.path)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .padding(.top, 14)
            .frame(width: 190)
            .background(Theme.bg2)
            Theme.line.frame(width: 1)
            ListScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if let problem = model.configProblems.first {
                        Text("config.toml: \(problem.description)")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.err)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.err.opacity(0.1)))
                    }
                    switch section {
                    case .general: GeneralSettings()
                    case .agents: AgentSettings()
                    case .colors: OrgRepoSettings()
                    case .hosts: HostSettings()
                    case .cleanup: CleanupSettings()
                    case .pilot: PilotSettingsView()
                    case .attention: AttentionRuleSettings()
                    case .keys: KeySettings()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Sized by the window, not by the page: the page scrolls inside it.
        .frame(
            minWidth: 780,
            idealWidth: 1000,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}

/// A group of settings on a page: its name over a rule.
private struct GroupLabel: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            Theme.line.frame(height: 1)
        }
        .padding(.top, 10)
    }
}

/// A labelled row.
private struct Field<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 170, alignment: .leading).padding(
                .top,
                4
            )
            VStack(alignment: .leading, spacing: 4) {
                content
                if let detail {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
        }
    }
}

/// A text field that writes to config.toml when you press return or leave it.
private struct ConfigTextField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != value else { return }
        model.setConfig(path, .string(text))
    }
}

/// Instructions added to a prompt: several lines, written when you leave the field (⌘↩ too).
struct InstructionsField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    /// nil: as wide as the row allows.
    var width: CGFloat?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("none", text: $text, axis: .vertical)
            .lineLimit(2 ... 6)
            .textFieldStyle(.roundedBorder)
            .font(Theme.ui(12.5))
            .frame(maxWidth: width ?? .infinity)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != value else { return }
        model.setConfig(path, .string(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.config.work
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(Theme.ui(17, weight: .semibold))
            GroupLabel(title: "Sessions")
            Field(label: "Default agent") {
                Picker("", selection: Binding(
                    get: { work.defaultAgent }, set: { model.setConfig(["sessions", "default_agent"], .string($0)) }
                )) {
                    ForEach(work.agents) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(
                label: "Resume on launch",
                detail: "Ask lists the sessions that were open; Always resumes them; Never starts empty."
            ) {
                Picker("", selection: Binding(
                    get: { work.resumeOnLaunch },
                    set: { model.setConfig(["sessions", "resume_on_launch"], .string($0.rawValue)) }
                )) {
                    ForEach(ResumePolicy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            Field(
                label: "Continue prompt",
                detail: "Typed into a resumed session that was mid-turn, once idle. Empty turns it off."
            ) {
                ConfigTextField(path: ["sessions", "continue_prompt"], value: work.continuePrompt)
            }
            Field(label: "Shell split", detail: "New sessions open a shell beside the agent; off is one pane.") {
                Toggle("", isOn: Binding(
                    get: { work.shellSplit }, set: { model.setConfig(["sessions", "shell_split"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Field(
                label: "Persistent panes",
                detail: "Panes run in zmx, so agents keep running when heed quits, restarts or updates, and come back as "
                    + "they were. Auto uses zmx when it is installed and passes its check (Tools, below)."
            ) {
                Picker("", selection: Binding(
                    get: { model.settings.persist },
                    set: { model.setConfig(["sessions", "persist"], .string($0.rawValue)) }
                )) {
                    Text("Auto").tag(PanePersistence.auto)
                    Text("zmx").tag(PanePersistence.zmx)
                    Text("Off").tag(PanePersistence.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            LedgerSettingsGroup()
            GoalsSettingsGroup()
            GroupLabel(title: "Outside the window")
            Field(
                label: "Menu bar item",
                detail: "How many sessions need you, those sessions, Start work and Open Heed. With it on, closing the window keeps Heed running."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.showMenuBarItem }, set: { model.setConfig(["ui", "menu_bar"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Field(
                label: "Dock state",
                detail: "A badge on the Dock icon in the state's colour when sessions need you."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.showDockState }, set: { model.setConfig(["ui", "dock_state"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Field(
                label: "Notifications",
                detail: "A notification when a session starts needing you, unless Heed is in front on it. macOS asks "
                    + "the first time."
            ) {
                HStack(spacing: 14) {
                    Toggle("", isOn: Binding(
                        get: { model.config.notifications.enabled },
                        set: { model.setConfig(["notifications", "enabled"], .bool($0)) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    Toggle("Asking", isOn: Binding(
                        get: { model.config.notifications.asking },
                        set: { model.setConfig(["notifications", "asking"], .bool($0)) }
                    ))
                    .disabled(!model.config.notifications.enabled)
                    Toggle("Blocked", isOn: Binding(
                        get: { model.config.notifications.blocked },
                        set: { model.setConfig(["notifications", "blocked"], .bool($0)) }
                    ))
                    .disabled(!model.config.notifications.enabled)
                }
            }
            Field(
                label: "Grace",
                detail: "How long a session must keep needing you before it notifies, so a prompt that clears itself "
                    + "stays quiet. 0 notifies at once."
            ) {
                Stepper(value: Binding(
                    get: { model.config.notifications.graceSeconds },
                    set: { model.setConfig(["notifications", "grace_seconds"], .integer($0)) }
                ), in: 0 ... 3600, step: 5) {
                    Text("\(model.config.notifications.graceSeconds)s").font(Theme.mono(12.5))
                }
                .frame(width: 160)
                .disabled(!model.config.notifications.enabled)
            }
            Field(
                label: "Reminder",
                detail: "One more notification if it still needs you this long after the first, then none until it "
                    + "comes back."
            ) {
                Stepper(value: Binding(
                    get: { model.config.notifications.reminderMinutes },
                    set: { model.setConfig(["notifications", "reminder_minutes"], .integer($0)) }
                ), in: 0 ... 1440, step: 5) {
                    let minutes = model.config.notifications.reminderMinutes
                    Text(minutes == 0 ? "Off" : "\(minutes) min").font(Theme.mono(12.5))
                }
                .frame(width: 160)
                .disabled(!model.config.notifications.enabled)
            }
            Field(
                label: "Quiet hours",
                detail: "No notifications from start to end, like 22:00-07:00; empty for none. What needed you "
                    + "meanwhile shows in Needs you and on the Dock, not as a notification when they end."
            ) {
                ConfigTextField(path: ["attention", "quiet"], value: model.config.attention.quiet?.description ?? "")
                    .frame(width: 160)
            }
            GroupLabel(title: "GitHub")
            Field(label: "GitHub poll", detail: "Seconds between gh syncs.") {
                Stepper(value: Binding(
                    get: { model.config.githubPollSeconds },
                    set: { model.setConfig(["github", "poll_seconds"], .integer($0)) }
                ), in: 15 ... 3600, step: 15) {
                    Text("\(model.config.githubPollSeconds)s").font(Theme.mono(12.5))
                }
                .frame(width: 160)
            }
            Field(
                label: "Issues",
                detail: "For orgs and repos without their own setting: every open issue, or only yours (assigned or mentioning you)."
            ) {
                Picker("", selection: Binding(
                    get: { model.config.issues.fallback },
                    set: { model.setConfig(["issues", "default"], .string($0.rawValue)) }
                )) {
                    Text("All issues").tag(IssueVisibility.all)
                    Text("Only yours").tag(IssueVisibility.involved)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            CallLogSettings()
            UpdateSettingsGroup()
            GroupLabel(title: "Tools")
            Field(label: "git", detail: "Empty detects it. A path, or a name looked up on the search path.") {
                ConfigTextField(path: ["tools", "git"], value: model.config.tools.git)
            }
            Field(label: "gh", detail: "Empty detects it.") {
                ConfigTextField(path: ["tools", "gh"], value: model.config.tools.gh)
            }
            Field(
                label: "zmx",
                detail: "For persistent panes. Empty detects it (Homebrew, ~/.local/bin, the search path)."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigTextField(path: ["tools", "zmx"], value: model.config.tools.zmx)
                    ZmxStatus(health: model.zmxHealth, setting: model.settings.persist)
                }
            }
            Field(
                label: "tailscale",
                detail: "For hosts on your tailnet. Empty detects it (the search path, then the Tailscale app)."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigTextField(path: ["tools", "tailscale"], value: model.config.tools.tailscale)
                    TailscaleStatusLine(path: model.tailscalePath, tailnet: model.tailnet)
                }
            }
            ToolsList(report: model.tools)
        }
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected = "claude"

    var body: some View {
        let agents = model.config.work.agents
        VStack(alignment: .leading, spacing: 16) {
            Text("Agents").font(Theme.ui(17, weight: .semibold))
            Picker("", selection: $selected) {
                ForEach(agents) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let agent = agents.first(where: { $0.name == selected }) {
                Field(label: "Command") {
                    ConfigTextField(path: ["agents", agent.name, "command"], value: agent.command)
                }
                Field(label: "Prompt delivery", detail: "How Start work hands the prompt over.") {
                    Picker("", selection: Binding(
                        get: { agent.prompt },
                        set: { model.setConfig(["agents", agent.name, "prompt"], .string($0.rawValue)) }
                    )) {
                        ForEach(PromptDelivery.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
                Field(label: "Plan first", detail: "Arguments added when Start work's “Plan first” is on.") {
                    ConfigTextField(path: ["agents", agent.name, "plan"], value: agent.planArguments ?? "")
                }
                Field(
                    label: "Resume",
                    detail: "{id} is the agent's own session id. Empty: sessions start fresh after a restart."
                ) {
                    ConfigTextField(path: ["agents", agent.name, "resume"], value: agent.resumeArguments ?? "")
                }
                Field(label: "State", detail: integration(agent.name)) {
                    Text(stateSource(agent.name)).font(Theme.mono(12)).foregroundStyle(Theme.done)
                }
                ModelCallSettings(agent: agent)
            }
            Text("Custom agents: add an [agents.<name>] table with a command in config.toml.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
            ModelCallLimits()
            UsageSettingsGroup()
            LocalDecisionSettings()
        }
    }

    private func stateSource(_ name: String) -> String {
        switch name {
        case "claude": "full hooks (passed with --settings)"
        case "codex": "hooks (passed with -c)"
        case "cursor": "project hooks (written into the worktree)"
        case "pi": "extension (passed with -e)"
        case "opencode": "plugin (passed with OPENCODE_CONFIG_CONTENT)"
        default: "read from the terminal"
        }
    }

    private func integration(_: String) -> String {
        "Heed never edits your own agent config; hooks are passed per run where the agent allows it."
    }
}

/// One agent's part in heed's own model calls (`[llm]`): on or off, its model, what detection found, and a Test.
private struct ModelCallSettings: View {
    @Environment(AppModel.self) private var model
    let agent: AgentProfile

    var body: some View {
        GroupLabel(title: "Model calls")
        if LLMDialect.of(agent) == nil {
            Text("Custom agents take no part in heed's own model calls (summaries, decisions).")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
        } else {
            let status = model.llmStatuses.first { $0.name == agent.name }
            let settings = model.config.llm
            Field(
                label: "Use for model calls",
                detail: "heed's own short calls (summaries, decisions) take turns over the agents you are logged in "
                    + "to, each with a cheap model. Off leaves this one out."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled(agent.name) },
                    set: { model.setConfig(["agents", agent.name, "llm"], .bool($0)) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!settings.enabled)
            }
            Field(label: "Login", detail: loginDetail(status)) {
                HStack(spacing: 10) {
                    Text(loginText(status)).font(Theme.mono(12)).foregroundStyle(loginColor(status))
                    Button("Check again") { Task { await model.refreshLLMStatuses(force: true) } }
                        .buttonStyle(.link)
                        .font(Theme.ui(12))
                }
            }
            Field(
                label: "Model",
                detail: "Empty: \(status?.detectedModel.map { "\($0), detected" } ?? "the agent's own default")."
            ) {
                ConfigTextField(path: ["agents", agent.name, "llm_model"], value: settings.model(for: agent.name) ?? "")
                    .frame(width: 260)
            }
            Field(label: "Test", detail: "One tiny call to this agent alone; it shows in :log.") {
                TestResult(agent: agent.name)
            }
            if !settings.enabled {
                HStack(spacing: 8) {
                    Text("Model calls are off for every agent ([llm] enabled = false): heed makes none at all.")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.block)
                    Button("Turn them on") { model.setConfig(["llm", "enabled"], .bool(true)) }
                        .buttonStyle(.link)
                        .font(Theme.ui(11.5))
                }
            }
        }
    }

    private func loginText(_ status: LLMAgentStatus?) -> String {
        switch status?.login {
        case .loggedIn: "logged in"
        case .loggedOut: "not logged in"
        case .unknown: "installed (no login check: a failed call says)"
        case .notInstalled: "\(agent.command.split(separator: " ").first.map(String.init) ?? agent.command) not found"
        case nil: "checking…"
        }
    }

    private func loginColor(_ status: LLMAgentStatus?) -> Color {
        switch status?.login {
        case .loggedIn: Theme.done
        case .unknown: Theme.fg2
        case .loggedOut, .notInstalled: Theme.block
        case nil: Theme.fg3
        }
    }

    private func loginDetail(_ status: LLMAgentStatus?) -> String {
        switch status?.login {
        case .notInstalled:
            "heed runs it without your shell, so an alias or shell function does not count: set Command to its path, "
                + "or add its folder to [tools] path."
        case .loggedOut: "Log in with the agent itself; heed only uses logins you already have."
        default: status?.path.map(Paths.abbreviate) ?? ""
        }
    }
}

/// `[local]`: screen snapshots kept for a local decision model to learn from, and what is kept so far.
private struct LocalDecisionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let local = model.config.local
        GroupLabel(title: "Local decisions")
            .task(id: local.recordScreens) { await model.refreshScreenCounts() }
        Text(
            "Screen snapshots for a local model to learn from: what an agent's pane showed when its hooks said what it "
                + "was doing. Kept in heed.sqlite on this Mac only, never sent anywhere and never in the call log."
        )
        .font(Theme.ui(11.5))
        .foregroundStyle(Theme.fg3)
        .fixedSize(horizontal: false, vertical: true)
        Field(
            label: "Record screens",
            detail: "At each state a hook reports, the cleaned last \(ScreenSnapshot.lines) lines of the agent's pane; "
                + "one every \(Int(ScreenSampler.workingEvery / 60)) minutes while it works; states read from the "
                + "screen, unlabelled. Off by default."
        ) {
            Toggle("", isOn: Binding(
                get: { local.recordScreens }, set: { model.setConfig(["local", "record_screens"], .bool($0)) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        Field(label: "Keep", detail: "Older snapshots go, and the oldest past 64 MB of text.") {
            Stepper(value: Binding(
                get: { local.keepDays }, set: { model.setConfig(["local", "keep_days"], .integer($0)) }
            ), in: 1 ... 365) {
                Text("\(local.keepDays) day\(local.keepDays == 1 ? "" : "s")").font(Theme.mono(12.5))
            }
            .frame(width: 160)
        }
        if let counts = model.screenCounts {
            Field(label: "Labelled", detail: "Per agent and the state its hooks reported.") {
                if counts.labelled.isEmpty {
                    Text("none yet").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                } else {
                    labelled(counts.labelled)
                }
            }
            Field(label: "Unlabelled", detail: "States read from the screen, for agents without hooks for them.") {
                Text(Counts.text(counts.unlabelled)).font(Theme.mono(12))
            }
            Field(label: "Last 7 days") {
                HStack(spacing: 14) {
                    ForEach(counts.days, id: \.day) { day in
                        VStack(spacing: 2) {
                            Text(Self.weekday.string(from: day.day)).font(Theme.ui(11)).foregroundStyle(Theme.fg3)
                            Text(Counts.text(day.count)).font(Theme.mono(12))
                                .foregroundStyle(day.count == 0 ? Theme.fg3 : Theme.fg)
                        }
                    }
                }
            }
            Field(
                label: "Start work",
                detail: "What Start work guessed and what you started with, kept as long as snapshots."
            ) {
                Text("\(Counts.text(model.startOutcomeCount ?? 0)) outcomes").font(Theme.mono(12))
                    .task { await model.refreshStartOutcomeCount() }
            }
            Field(label: "Kept", detail: "Text, in heed.sqlite beside domain.json.") {
                Text("\(Counts.text(counts.total)) snapshots · \(Self.size(counts.bytes))").font(Theme.mono(12))
            }
            Field(label: "Delete all") {
                let outcomes = model.startOutcomeCount ?? 0
                Button("Delete all…") { confirmDelete = true }
                    .disabled(counts.total == 0 && outcomes == 0)
                    .confirmationDialog(
                        "Delete all \(Counts.text(counts.total)) screen snapshots and \(Counts.text(outcomes)) Start "
                            + "work outcomes?",
                        isPresented: $confirmDelete
                    ) {
                        Button("Delete all", role: .destructive) { Task { await model.deleteLocalDecisions() } }
                    } message: {
                        Text("They cannot be brought back. Recording goes on: snapshots if it is on, outcomes always.")
                    }
            }
        }
    }

    private func labelled(_ rows: [ScreenSnapshotCounts.Labelled]) -> some View {
        let agents = rows.map(\.agent).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(agents, id: \.self) { agent in
                HStack(spacing: 12) {
                    Text(agent).font(Theme.mono(12)).frame(width: 80, alignment: .leading)
                    ForEach(AgentState.allCases, id: \.self) { state in
                        if let row = rows.first(where: { $0.agent == agent && $0.state == state }) {
                            HStack(spacing: 5) {
                                StateGlyph(state: state, size: 10)
                                Text(state.rawValue).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                Text(Counts.text(row.count)).font(Theme.mono(12))
                            }
                        }
                    }
                }
            }
        }
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// `1.2 MB`, `340 KB`: the same whatever the Mac's region.
    static func size(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return "\(max(bytes / 1000, bytes > 0 ? 1 : 0)) KB"
    }
}

/// The Test button, and how the last test went.
private struct TestResult: View {
    @Environment(AppModel.self) private var model
    let agent: String

    var body: some View {
        let test = model.llmTests[agent]
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(test?.running == true ? "Testing…" : "Test") { model.testLLM(agent: agent) }
                .disabled(test?.running == true)
            if let test, !test.running {
                if let error = test.error {
                    Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                } else {
                    Text(summary(test)).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                }
            }
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

/// `[pilot]`: the defaults every PR starts from. Orgs and repos override them in config.toml; listed here.
private struct PilotSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pilot = model.config.pilot
        VStack(alignment: .leading, spacing: 16) {
            Text("Pilot").font(Theme.ui(17, weight: .semibold))
            Text("What heed does with the PRs your sessions track. The Watch view (gw) shows them, and what it did.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            GroupLabel(title: "Watching")
            Field(
                label: "Watch PRs",
                detail: "Follow their review threads and failing checks. Read-only, so on; w turns it off for one PR."
            ) {
                Toggle("", isOn: Binding(
                    get: { pilot.defaults.watch }, set: { model.setConfig(["pilot", "watch"], .bool($0)) }
                )).labelsHidden()
            }
            GroupLabel(title: "Get it green")
            Field(
                label: "Get it green",
                detail: "Off shows what a PR collects; Ask waits for you to queue it; Auto sends it once the agent is idle."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.green },
                    set: { model.setConfig(["pilot", "green"], .string($0.configName)) }
                )) {
                    ForEach(AutoFeed.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(label: "Stop after", detail: "Prompts sent without a new approval.") {
                Stepper(value: Binding(
                    get: { pilot.defaults.maxRounds },
                    set: { model.setConfig(["pilot", "max_rounds"], .integer($0)) }
                ), in: 1 ... 20) {
                    Text("\(pilot.defaults.maxRounds) rounds").font(Theme.mono(12.5))
                }
            }
            Field(
                label: "Runs in",
                detail: "Background: each round is an agent in its own tab, worktree and branch (heed/get-it-green/…), "
                    + "all removed when it is done. Session: the session's own agent, once it is idle and you have not "
                    + "typed in it for five minutes."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.runIn },
                    set: { model.setConfig(["pilot", "run_in"], .string($0.configName)) }
                )) {
                    ForEach(RunIn.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(
                label: "Run agent",
                detail: "Which agent background runs use; the session's when unset. Spend tokens of an agent you do "
                    + "not use for real work."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.agent ?? "" },
                    set: { $0.isEmpty ? model.unsetConfig(["pilot", "agent"])
                        : model.setConfig(["pilot", "agent"], .string($0))
                    }
                )) {
                    Text("The session's agent").tag("")
                    ForEach(model.settings.agents.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(
                label: "Run model",
                detail: "Its model (haiku, gpt-5-codex, openai/gpt-5…); the agent's default when empty."
            ) {
                ConfigTextField(path: ["pilot", "model"], value: pilot.defaults.model ?? "")
            }
            Field(
                label: "Conflict agent",
                detail: "Merge conflicts with the base are usually simple: background runs for them can use a cheaper "
                    + "agent. The run agent when unset."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.mergeAgent ?? "" },
                    set: { $0.isEmpty ? model.unsetConfig(["pilot", "merge_agent"])
                        : model.setConfig(["pilot", "merge_agent"], .string($0))
                    }
                )) {
                    Text("The run agent").tag("")
                    ForEach(model.settings.agents.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(
                label: "Conflict model",
                detail: "Its model; the run model when empty (with a conflict agent of its own, that agent's default)."
            ) {
                ConfigTextField(path: ["pilot", "merge_model"], value: pilot.defaults.mergeModel ?? "")
            }
            Field(label: "Run timeout", detail: "A run still working after this long is stopped.") {
                DurationPicker(
                    path: ["pilot", "run_timeout"], options: ["15m", "30m", "1h", "2h"],
                    current: PilotDuration.text(pilot.defaults.runTimeout)
                )
            }
            Field(label: "Pause for", detail: "What zp pauses a PR for.") {
                DurationPicker(
                    path: ["pilot", "pause"], options: ["30m", "1h", "4h", "1d", "forever"],
                    current: pilot.defaults.pause.map(PilotDuration.text) ?? "forever"
                )
            }
            GroupLabel(title: "Get it merged")
            Field(
                label: "Get it merged",
                detail: "Auto turns on GitHub's auto-merge once nothing fails; heed merges itself once its rules hold. zm cycles one PR."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.merge },
                    set: { model.setConfig(["pilot", "merge"], .string($0.configName)) }
                )) {
                    ForEach(MergeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(label: "Quiet for", detail: "heed merges: no new commit or review for this many minutes first.") {
                Stepper(value: Binding(
                    get: { pilot.defaults.quietMinutes },
                    set: { model.setConfig(["pilot", "quiet_minutes"], .integer($0)) }
                ), in: 0 ... 1440) {
                    Text("\(pilot.defaults.quietMinutes) minutes").font(Theme.mono(12.5))
                }
            }
            Field(
                label: "Trusted AI reviewers",
                detail: "heed merges: their review on the last push counts, as an approval does. Comma separated logins."
            ) {
                ListField(path: ["pilot", "trusted_reviewers"], values: pilot.defaults.trustedReviewers)
            }
            Field(
                label: "Gate checks",
                detail: "heed merges: checks that must have passed, required by GitHub or not."
            ) {
                ListField(path: ["pilot", "gate_checks"], values: pilot.defaults.gateChecks)
            }
            Field(label: "Hold labels", detail: "heed merges: a PR with one of these labels waits.") {
                ListField(path: ["pilot", "hold_labels"], values: pilot.defaults.holdLabels)
            }
            Field(
                label: "Self-review",
                detail: "heed merges: a command that reads the diff on stdin and answers APPROVE (e.g. claude -p). Empty: none."
            ) {
                ConfigTextField(path: ["pilot", "self_review"], value: pilot.defaults.selfReview ?? "")
            }
            Field(
                label: "Merge queue runs",
                detail: "How often each repo's queue runs; manual: only when you run it."
            ) {
                DurationPicker(
                    path: ["pilot", "merge_schedule"], options: ["15m", "30m", "1h", "4h", "manual"],
                    current: pilot.defaults.mergeSchedule.map(PilotDuration.text) ?? "manual"
                )
            }
            Field(label: "Merge method", detail: "How PRs are merged; default: the first the repo allows.") {
                Picker("", selection: Binding(
                    get: { pilot.defaults.mergeMethod ?? "" },
                    // Default is the key unset.
                    set: { $0.isEmpty ? model.unsetConfig(["pilot", "merge_method"])
                        : model.setConfig(["pilot", "merge_method"], .string($0))
                    }
                )) {
                    Text("default").tag("")
                    ForEach(["squash", "merge", "rebase"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(label: "Update branches", detail: "Bring queued PRs that fell behind their base up to date.") {
                Toggle("", isOn: Binding(
                    get: { pilot.defaults.updateBranches },
                    set: { model.setConfig(["pilot", "update_branches"], .bool($0)) }
                )).labelsHidden()
            }
            Field(
                label: "Merge now",
                detail: "zM, or merge now on a PR that is ready: ask shows the PR, the method and anything not met first; auto merges at once."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.mergeNow },
                    set: { model.setConfig(["pilot", "merge_now"], .string($0.rawValue)) }
                )) {
                    ForEach(MergeNowConfirm.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Field(
                label: "Force merge",
                detail: "Merging now past required reviews or checks with --admin, offered only where you are an admin: off, ask (lists what is bypassed), auto."
            ) {
                Picker("", selection: Binding(
                    get: { pilot.defaults.forceMerge },
                    set: { model.setConfig(["pilot", "force_merge"], .string($0.rawValue)) }
                )) {
                    ForEach(ForceMerge.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            GroupLabel(title: "Copilot and reviewers")
            Field(
                label: "Copilot: conflicts",
                detail: "Ask GitHub's Copilot coding agent on the PR to resolve merge conflicts, sparing your agent's "
                    + "tokens. Where Copilot can work in the repo."
            ) {
                Toggle("", isOn: Binding(
                    get: { pilot.defaults.copilotConflicts },
                    set: { model.setConfig(["pilot", "copilot_conflicts"], .bool($0)) }
                )).labelsHidden()
            }
            Field(
                label: "Copilot: comments",
                detail: "Ask it to address new review comments too; with both on, one comment asks for both. C asks now."
            ) {
                Toggle("", isOn: Binding(
                    get: { pilot.defaults.copilotComments },
                    set: { model.setConfig(["pilot", "copilot_comments"], .bool($0)) }
                )).labelsHidden()
            }
            Field(
                label: "Reviewers",
                detail: "Asked to review each PR once it is open and ready: logins, org/team, or copilot. Comma separated."
            ) {
                ListField(path: ["pilot", "reviewers"], values: pilot.defaults.reviewers)
            }
            GroupLabel(title: "Extra instructions")
            Text(
                "Added to what heed sends, never replacing it. Per org and per repo too, under Orgs & repos. The agent "
                    + "still reads the repo's own AGENTS.md or CLAUDE.md."
            )
            .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            Field(label: "Get it green", detail: "After the feedback items each run gets.") {
                InstructionsField(path: ["pilot", "green_instructions"], value: pilot.defaults.greenInstructions)
            }
            Field(label: "Self-review", detail: "Added to what heed merge's self-review looks for.") {
                InstructionsField(path: ["pilot", "review_instructions"], value: pilot.defaults.reviewInstructions)
            }
            Field(label: "Start work", detail: "After the issue text Start work begins from.") {
                InstructionsField(path: ["pilot", "start_instructions"], value: pilot.defaults.startInstructions)
            }
            Field(label: "Summaries", detail: "Added to what heed asks its model calls for when it summarizes work.") {
                InstructionsField(path: ["pilot", "summary_instructions"], value: pilot.defaults.summaryInstructions)
            }
            Field(
                label: "Sign off with a summary",
                detail: "Ask claude and codex to end their final message with a heed-summary: line; it becomes the "
                    + "ledger's summary (History, L). Per org and repo too, in Orgs & repos."
            ) {
                Toggle("", isOn: Binding(
                    get: { pilot.defaults.summarySignOff },
                    set: { model.setConfig(["pilot", "summary_sign_off"], .bool($0)) }
                )).labelsHidden().toggleStyle(.switch)
            }
            let orgs = pilot.orgs.count, repos = pilot.repos.count
            HStack(spacing: 6) {
                Text(orgs + repos == 0
                    ? "No org or repo overrides these."
                    : "\(orgs) org\(orgs == 1 ? "" : "s") and \(repos) repo\(repos == 1 ? "" : "s") override these.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                Button("Orgs & repos") { model.settingsSection = .colors }.buttonStyle(.link).font(Theme.ui(12))
            }
        }
    }
}

private struct CleanupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rule = model.config.cleanup
        VStack(alignment: .leading, spacing: 16) {
            Text("Worktrees & cleanup").font(Theme.ui(17, weight: .semibold))
            GroupLabel(title: "Worktrees")
            Field(label: "Worktree root", detail: "New worktrees go to <root>/<repo>/<name>.") {
                ConfigTextField(path: ["worktrees", "root"], value: model.config.work.worktreeRoot)
            }
            Field(label: "Repo roots", detail: "Comma separated; scanned two levels deep.") {
                RootsField(roots: model.config.work.repoRoots)
            }
            Field(
                label: "Offer to trust repos for agents",
                detail: "Once per repo, before its first agent: Claude Code's folder trust, and mise's for [env]."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.work.offerTrust },
                    set: { model.setConfig(["worktrees", "offer_trust"], .bool($0)) }
                )).labelsHidden()
            }
            GroupLabel(title: "Start work")
            Field(
                label: "Smart guesses",
                detail: "The on-device model suggests the repo, the branch name and its prefix as you type; your "
                    + "own picks always win. \(model.isFixture ? "Apple's on-device model is ready." : SmartGuesses.status)"
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.startWork.smartGuesses },
                    set: { model.setConfig(["start_work", "smart_guesses"], .bool($0)) }
                )).labelsHidden()
            }
            GroupLabel(title: "Cleanup")
            Field(
                label: "Remove idle worktrees",
                detail: "No agent output, keystrokes, commits or PR events for this long."
            ) {
                HStack {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { rule.enabled },
                            set: { model.setConfig(["cleanup", "enabled"], .bool($0)) }
                        )
                    )
                    .labelsHidden()
                    Stepper(value: Binding(
                        get: { rule.idleDays }, set: { model.setConfig(["cleanup", "idle_days"], .integer($0)) }
                    ), in: 1 ... 365) {
                        Text("\(rule.idleDays) days").font(Theme.mono(12.5))
                    }
                }
            }
            Field(
                label: "The sweep never removes dirty or unpushed work",
                detail: "Always on. Skipped worktrees show a warning instead."
            ) {
                Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
            }
            Field(
                label: "Keep saved work",
                detail: "Removing a worktree saves its commits and changes as heed/archive/<branch> first; R in History "
                    + "brings it back. Sweeps drop older ones (0: keep them)."
            ) {
                Stepper(value: Binding(
                    get: { rule.keepArchiveDays },
                    set: { model.setConfig(["cleanup", "keep_archive_days"], .integer($0)) }
                ), in: 0 ... 3650, step: 30) {
                    Text(rule.keepArchiveDays == 0 ? "forever" : "\(rule.keepArchiveDays) days")
                        .font(Theme.mono(12.5))
                }
            }
            Field(label: "Delete the local branch too", detail: "The remote branch is left alone.") {
                Toggle("", isOn: Binding(
                    get: { rule.deleteBranch }, set: { model.setConfig(["cleanup", "delete_branch"], .bool($0)) }
                )).labelsHidden()
            }
            Field(label: "Ask before each sweep") {
                Toggle("", isOn: Binding(
                    get: { rule.askBeforeSweep }, set: { model.setConfig(["cleanup", "ask_before_sweep"], .bool($0)) }
                )).labelsHidden()
            }
        }
    }
}

/// A comma-separated list of words, written as a TOML array.
private struct WordsField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let words: [String]
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12))
            .onAppear { text = words.joined(separator: ", ") }
            .onChange(of: words) { text = words.joined(separator: ", ") }
            .onSubmit {
                let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                guard list != words else { return }
                model.setConfig(path, .array(list.map { .string($0) }))
            }
    }
}

/// A comma separated list written to config.toml as an array.
private struct ListField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let values: [String]
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .onAppear { text = values.joined(separator: ", ") }
            .onSubmit {
                let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                model.setConfig(path, .array(list.map { .string($0) }))
            }
    }
}

private struct RootsField: View {
    @Environment(AppModel.self) private var model
    let roots: [String]
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .onAppear { text = roots.joined(separator: ", ") }
            .onSubmit {
                let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                model.setConfig(["worktrees", "repo_roots"], .array(list.map { .string($0) }))
            }
    }
}

private struct KeySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keymap = model.engine.keymaps[.normal] ?? Keymap()
        VStack(alignment: .leading, spacing: 12) {
            Text("Keys & modes").font(Theme.ui(17, weight: .semibold))
            Text(
                "Bindings are edited in config.toml ([keys.normal], [keys.repos], ...): every binding names a command, the same names : completes."
            )
            .font(Theme.ui(12))
            .foregroundStyle(Theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Leave INSERT").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                KeyCap(text: KeyCapText.of(model.config.insertEscape))
            }
            GroupLabel(title: "Global shortcuts")
            Text("They work from any app. One key with ⌃, ⌥ or ⌘; Record takes the next one you press, ⎋ cancels. "
                + "Empty turns one off.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            Field(
                label: "Start work",
                detail: "Opens Start work in a floating panel over any app (window title \"Heed Start Work\")."
            ) {
                ShortcutField(
                    path: ["keys", "global_start_work"], value: model.config.globalStartWork,
                    other: model.config.globalActivate
                )
            }
            Field(label: "Bring Heed forward", detail: "Brings Heed to the front from any app.") {
                ShortcutField(
                    path: ["keys", "global_activate"], value: model.config.globalActivate,
                    other: model.config.globalStartWork
                )
            }
            GroupLabel(title: "Bindings")
            Button("Edit bindings in config.toml") { NSWorkspace.shared.open(model.configFile) }
            ForEach(Array(keymap.bindings.enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 12) {
                    Text(KeyCapText.of(binding.keys)).font(Theme.mono(12)).frame(width: 90, alignment: .leading)
                    Text(binding.command).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                    Text(Commands.spec(CommandInvocation(parsing: binding.command).name)?.summary ?? "")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
            }
        }
    }
}

/// zmx's check, under its field: where it is, its version, whether it works, and what panes do because of it.
private struct ZmxStatus: View {
    let health: ZmxHealth?
    let setting: PanePersistence

    var body: some View {
        let effective = ZmxHealth.decide(setting, health: health)
        VStack(alignment: .leading, spacing: 4) {
            if let health {
                HStack(spacing: 6) {
                    Image(systemName: health.works ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                    if let path = health.path {
                        Text(Paths.abbreviate(path)).font(Theme.mono(11.5))
                        if let version = health.version { Text(version).foregroundStyle(Theme.fg3) }
                    }
                    Text(health.works ? "works" : health.problem ?? "")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                }
                Text(effective == .zmx
                    ? "Panes run in zmx: agents outlive heed."
                    : setting == .none ? "Off: panes end when heed quits." : "Panes are plain shells until zmx works.")
                    .foregroundStyle(Theme.fg3)
                if health.path == nil {
                    Text("Install: " + ZmxInstall.mac.joined(separator: "; ")).font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not checked yet.").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }
}

/// Tailscale's check, under its field: where the CLI is, and whether your tailnet is up.
private struct TailscaleStatusLine: View {
    let path: String?
    let tailnet: Tailnet?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tailnet {
                let (ok, text) = summary(tailnet)
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Theme.done : Theme.block)
                    if let path { Text(Paths.abbreviate(path)).font(Theme.mono(11.5)) }
                    Text(text).foregroundStyle(ok ? Theme.done : Theme.block)
                }
                if tailnet.state == .notInstalled {
                    Text("Optional. Install: " + TailscaleCLI.install.joined(separator: " ")).font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not checked yet.").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }

    private func summary(_ tailnet: Tailnet) -> (Bool, String) {
        switch tailnet.state {
        case .running:
            (true, "on \(tailnet.name ?? "your tailnet") · \(tailnet.machines.count) machines")
        case .notInstalled: (false, "not installed")
        case .off, .starting: (false, "Tailscale is off")
        case .needsLogin: (false, "signed out")
        }
    }
}

/// A duration from a short list, written as text (`"1h"`): a value set in config.toml outside the list shows too.
private struct DurationPicker: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let options: [String]
    let current: String

    var body: some View {
        Picker("", selection: Binding(get: { current }, set: { model.setConfig(path, .string($0)) })) {
            ForEach(options.contains(current) ? options : options + [current], id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 200)
    }
}

/// `[log]`: how long the call log (`:log`) keeps each kind of call, and how many rows at most.
private struct CallLogSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.config.log
        GroupLabel(title: "Call log")
        days("Commands", "Every command heed runs (git, zmx, a check on a host).", "shell_days", log.shellDays)
        days(
            "GitHub reads",
            "Syncs and the PRs' details: many a day, seldom needed long.",
            "github_read_days",
            log.githubReadDays
        )
        days(
            "GitHub writes",
            "Merges, comments, review requests: what heed changed on GitHub.",
            "github_write_days",
            log.githubWriteDays
        )
        days("Model runs", "Summaries and other cheap-model runs, with their tokens and cost.", "llm_days", log.llmDays)
        days("Decisions", "What heed decided, and how sure it was.", "decide_days", log.decideDays)
        Field(label: "At most", detail: "Rows of each kind, newest kept, whatever their age.") {
            Stepper(value: Binding(
                get: { log.maxRows }, set: { model.setConfig(["log", "max_rows"], .integer($0)) }
            ), in: 1000 ... 1_000_000, step: 10000) {
                Text("\(Counts.text(log.maxRows)) rows").font(Theme.mono(12.5))
            }
            .frame(width: 200)
        }
    }

    private func days(_ label: String, _ detail: String, _ key: String, _ value: Int) -> some View {
        Field(label: label, detail: detail) {
            Stepper(value: Binding(
                get: { value }, set: { model.setConfig(["log", key], .integer($0)) }
            ), in: 1 ... 365) {
                Text("\(value) day\(value == 1 ? "" : "s")").font(Theme.mono(12.5))
            }
            .frame(width: 160)
        }
    }
}

/// `[goals]`: what goals do on their own.
private struct GoalsSettingsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupLabel(title: "Goals")
        Field(
            label: "Tell agents their goal",
            detail: "Sessions and chats on a goal start and resume told which goal, to read its GOAL.md first and to "
                + "keep to its Not the goal list (claude, codex)."
        ) {
            Toggle("", isOn: Binding(
                get: { model.config.goals.tellAgents },
                set: { model.setConfig(["goals", "tell_agents"], .bool($0)) }
            )).labelsHidden()
        }
        let attach = model.config.goals.attach
        Field(
            label: "Find new work's goal",
            detail: "When a session or chat starts, gets its first prompt, tracks a PR or gets a ledger entry, heed "
                + "looks for its goal: it attaches when sure, asks in Attention when unsure, else leaves it in "
                + "Unassigned."
        ) {
            Toggle("", isOn: Binding(
                get: { attach.enabled }, set: { model.setConfig(["goals", "attach"], .bool($0)) }
            )).labelsHidden()
        }
        Group {
            threshold(
                "Attach on its own at", "At this confidence or more heed attaches, with undo (u).", "attach_auto",
                attach.auto, range: max(attach.ask, 0.05) ... 1
            )
            threshold(
                "Ask from",
                "From here up to the line above, heed asks with one key (y n m i); below, it leaves the work.",
                "attach_ask", attach.ask, range: 0 ... attach.auto
            )
            Field(
                label: "Ask the model when unsure",
                detail: "A cheap model call (Agents › Model calls) when the signals are between the two lines or two "
                    + "goals are close. Off: signals alone."
            ) {
                Toggle("", isOn: Binding(
                    get: { attach.model }, set: { model.setConfig(["goals", "attach_model"], .bool($0)) }
                )).labelsHidden()
            }
            Field(
                label: "Rules",
                detail: "Your corrections become lines here, and apply before any signal. "
                    + (model.goals.attach.rules.problems.isEmpty ? ""
                        : "\(model.goals.attach.rules.problems.count) line(s) heed cannot read are skipped.")
            ) {
                Text(Paths.tilde(model.goals.files.rules.path))
                    .font(Theme.mono(12)).foregroundStyle(Theme.busy).lineLimit(1).truncationMode(.head)
                    .clickable().onTapGesture { model.openAttachRules() }
                    .help("Open attach.rules in your editor")
            }
        }
        .disabled(!attach.enabled)
        Field(
            label: "Reviewers run on their own",
            detail: "When a goal's work changes (a PR opened, updated or merged, a new GOAL.md version) and nightly, "
                + "for the lenses the goal requires; quiet once at their bar until something new. Off: only when you "
                + "press re-check."
        ) {
            Toggle("", isOn: Binding(
                get: { model.config.goals.autoReview },
                set: { model.setConfig(["goals", "auto_review"], .bool($0)) }
            )).labelsHidden()
        }
        Field(
            label: "Reviewer runs per day",
            detail: "Per goal. Past it, heed asks in Attention; a re-check you press is never held back. Bars per "
                + "lens are in config.toml under [goals.bars], models per reviewer kind under [goals.reviewers]."
        ) {
            Stepper(value: Binding(
                get: { model.config.goals.reviewerRunsPerDay },
                set: { model.setConfig(["goals", "reviewer_runs_per_day"], .integer($0)) }
            ), in: 0 ... 100) {
                Text("\(model.config.goals.reviewerRunsPerDay)").font(Theme.mono(12.5))
            }
            .frame(width: 160)
        }
    }

    private func threshold(
        _ label: String, _ detail: String, _ key: String, _ value: Double, range: ClosedRange<Double>
    ) -> some View {
        Field(label: label, detail: detail) {
            Stepper(value: Binding(
                get: { value }, set: { model.setConfig(["goals", key], .float(($0 * 100).rounded() / 100)) }
            ), in: range, step: 0.05) {
                Text(String(format: "%.2f", value)).font(Theme.mono(12.5))
            }
            .frame(width: 160)
        }
    }
}

/// `[summary] when`, `idle_hours`, `include`: when History's ledger writes a summary, and what it keeps.
private struct LedgerSettingsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ledger = model.config.ledger
        GroupLabel(title: "History ledger")
        Text("A cheap model (Agents › Model calls) writes a short summary of each piece of work; S in the ledger "
            + "writes one any time. Summaries stay on this Mac.")
            .font(Theme.ui(11.5))
            .foregroundStyle(Theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(LedgerTrigger.configurable, id: \.self) { trigger in
            Field(label: "When \(trigger == .idle ? "idle for \(ledger.idleHours) h" : trigger.title)") {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { ledger.when.contains(trigger) },
                        set: { on in
                            var when = ledger.when
                            if on { when.insert(trigger) } else { when.remove(trigger) }
                            let names = LedgerTrigger.configurable.filter(when.contains)
                                .map { TOMLValue.string($0.rawValue) }
                            model.setConfig(["summary", "when"], .array(names))
                        }
                    )).labelsHidden().toggleStyle(.switch)
                    if trigger == .idle {
                        Stepper(value: Binding(
                            get: { ledger.idleHours },
                            set: { model.setConfig(["summary", "idle_hours"], .integer($0)) }
                        ), in: 1 ... 720) { EmptyView() }
                            .labelsHidden()
                    }
                }
            }
        }
        Field(label: "Include", detail: "Files come from git; the rest is what the model writes.") {
            HStack(spacing: 12) {
                ForEach(LedgerPart.allCases, id: \.self) { part in
                    Toggle(part.title, isOn: Binding(
                        get: { ledger.include.contains(part) },
                        set: { on in
                            var include = ledger.include
                            if on { include.insert(part) } else { include.remove(part) }
                            let names = LedgerPart.allCases.filter(include.contains)
                                .map { TOMLValue.string($0.rawValue) }
                            model.setConfig(["summary", "include"], .array(names))
                        }
                    ))
                    .font(Theme.ui(12))
                }
            }
        }
    }
}

/// Settings › Attention: the rules as a list and as text side by side, what an edit would have changed over the last
/// 30 days before it is saved, and quiet hours. Nothing is written until Save.
private struct AttentionRuleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AttentionRuleDraft(lines: [])
    @State private var text = ""
    @State private var newRule = ""
    @State private var loaded = false

    var body: some View {
        let saved = model.config.attention.rules
        let preview = model.attentionPreview(draft.rules)
        VStack(alignment: .leading, spacing: 16) {
            Text("Attention").font(Theme.ui(17, weight: .semibold))
            Text(
                "What matters in Attention, one rule a line: what to match, then boost 1-3, lower, ignore, pin or notify. "
                    + "The first rule that matches an item decides. Ignored items stay under Muted for 30 days."
            )
            .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            GroupLabel(title: "Rules")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "As a list")
                    ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
                        row(index, line, matches: preview.matches[index + 1] ?? 0)
                    }
                    HStack {
                        TextField("mention team:acme/docs-eng boost 2", text: $newRule)
                            .textFieldStyle(.roundedBorder).font(Theme.mono(12))
                            .onSubmit(add)
                        Button("Add", action: add).disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "As text")
                    TextEditor(text: $text)
                        .font(Theme.mono(12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 220)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .onChange(of: text) { if draft.text != text { draft.text = text } }
                    Text("Both edit the same rules. # starts a comment.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupLabel(title: "Try before you save")
            VStack(alignment: .leading, spacing: 8) {
                if draft.saved == saved {
                    Text("These are the rules in use. Edit them to see what would change over the last 30 days.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                } else if preview.changed == 0 {
                    Text("Would have changed none of the \(preview.items) items of the last 30 days.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                } else {
                    Text("Would have changed \(preview.changed) of the \(preview.items) items of the last 30 days:")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    FlowLayout(spacing: 6) {
                        ForEach(preview.moves, id: \.self) { move in
                            ReasonTag(
                                text: "\(move.from.rawValue) → \(move.to.rawValue): \(move.count)",
                                tint: move.to < move.from ? Theme.block : Theme.busy
                            )
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Save to config.toml") {
                        model.setConfig(
                            ["attention", "rules"], .array(draft.saved.map { .string($0) }), multiline: true
                        )
                    }
                    .disabled(draft.saved == saved)
                    Button("Revert") { load(saved) }.disabled(draft.saved == saved)
                    if !draft.rules.problems.isEmpty {
                        Text("Lines with problems are left out when saved rules are read.")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            GroupLabel(title: "Weights")
            VStack(alignment: .leading, spacing: 5) {
                weight("boost 3", "top of the feed when sorted by weight; notifies")
                weight("boost 1-2", "higher when sorted by weight")
                weight("lower", "dimmed, lower, never notifies")
                weight("ignore", "out of the feed, under Muted for 30 days")
                weight("pin", "always at the top")
            }
            GroupLabel(title: "Notifications")
            Field(
                label: "Notify",
                detail: "Items a rule says to notify about (notify, or boost 3); several from one sync come as one."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.notifications.attention },
                    set: { model.setConfig(["notifications", "attention"], .bool($0)) }
                )).labelsHidden()
            }
            Field(label: "Quiet hours", detail: "Local time, 24-hour (\"22:00-07:00\"); empty for none.") {
                ConfigTextField(path: ["attention", "quiet"], value: model.config.attention.quiet?.description ?? "")
                    .frame(width: 160)
            }
        }
        .onAppear { if !loaded { load(model.attention.ruleDraftSeed ?? saved) } }
        .onChange(of: saved) { _, new in if draft.saved == new || !loaded { load(new) } }
    }

    private func load(_ lines: [String]) {
        draft = AttentionRuleDraft(lines: lines)
        text = draft.text
        loaded = true
    }

    private func change(_ body: (inout AttentionRuleDraft) -> Void) {
        body(&draft)
        text = draft.text
    }

    private func add() {
        change { $0.add(newRule) }
        newRule = ""
    }

    private func row(_ index: Int, _ line: String, matches: Int) -> some View {
        let rule = draft.rules.rules.first { $0.line == index + 1 }
        let problem = draft.problem(line: index + 1)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(Theme.mono(11)).foregroundStyle(Theme.fg3).frame(
                    width: 18,
                    alignment: .trailing
                )
                Text(rule?.match ?? line).font(Theme.mono(12)).lineLimit(1)
                    .foregroundStyle(problem == nil ? Theme.fg : Theme.err)
                Spacer(minLength: 6)
                if let rule {
                    ReasonTag(
                        text: rule.action.text, tint: rule.action.ignore ? Theme.err : rule.action.lower ? Theme.busy
                            : Theme.block, filled: true
                    )
                    Text("\(matches) / 30d").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 58, alignment: .trailing)
                }
                Button { change { $0.move(index, by: -1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { change { $0.move(index, by: 1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == draft.lines.count - 1)
                Button { change { $0.remove(at: index) } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if let problem {
                Text(problem).font(Theme.ui(11)).foregroundStyle(Theme.err).padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
    }

    private func weight(_ action: String, _ meaning: String) -> some View {
        HStack(spacing: 10) {
            Text(action).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).frame(width: 80, alignment: .leading)
            Text(meaning).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
    }
}

/// `[updates]`: whether heed looks for a new version, and whether it asks before installing one.
private struct UpdateSettingsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.config.updates
        GroupLabel(title: "Updates")
        Field(
            label: "Check for updates",
            detail: "Once a day, on GitHub, heed's releases. Only what heed's key signed and Apple notarized installs. "
                + ":update checks now either way."
        ) {
            Toggle("", isOn: Binding(
                get: { updates.check }, set: { model.setConfig(["updates", "check"], .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        Field(
            label: "Install",
            detail: "Ask shows what is new and installs when you say so; Auto downloads in the background and installs "
                + "on quit."
        ) {
            Picker("", selection: Binding(
                get: { updates.install },
                set: { model.setConfig(["updates", "install"], .string($0.rawValue)) }
            )) {
                Text("Ask").tag(UpdateSettings.Install.ask)
                Text("Auto").tag(UpdateSettings.Install.auto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .disabled(!updates.check)
        }
    }
}

/// `[llm]`: heed's own model calls for every agent: the switch for all of them, and their limits.
private struct ModelCallLimits: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let llm = model.config.llm
        GroupLabel(title: "Model calls, every agent")
        Field(
            label: "Model calls",
            detail: "heed's own short calls (summaries, decisions), through the agent CLIs you are logged in to. Off: "
                + "heed makes no model calls at all, whatever each agent says."
        ) {
            Toggle("", isOn: Binding(
                get: { llm.enabled }, set: { model.setConfig(["llm", "enabled"], .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        Group {
            Field(label: "Timeout", detail: "A call still running after this long is stopped.") {
                Stepper(value: Binding(
                    get: { llm.timeoutSeconds },
                    set: { model.setConfig(["llm", "timeout_seconds"], .integer($0)) }
                ), in: 10 ... 900, step: 10) {
                    Text("\(llm.timeoutSeconds)s").font(Theme.mono(12.5))
                }
                .frame(width: 160)
            }
            Field(
                label: "At once",
                detail: "Calls running at the same time; more wait, the ones you asked for first."
            ) {
                Stepper(value: Binding(
                    get: { llm.concurrency }, set: { model.setConfig(["llm", "concurrency"], .integer($0)) }
                ), in: 1 ... 8) {
                    Text("\(llm.concurrency)").font(Theme.mono(12.5))
                }
                .frame(width: 160)
            }
            Field(
                label: "Back off",
                detail: "An agent whose call failed is skipped for this long; one rate limited, until its limit resets."
            ) {
                Stepper(value: Binding(
                    get: { llm.backoffMinutes },
                    set: { model.setConfig(["llm", "backoff_minutes"], .integer($0)) }
                ), in: 0 ... 1440, step: 5) {
                    Text("\(llm.backoffMinutes) min").font(Theme.mono(12.5))
                }
                .frame(width: 160)
            }
            Field(
                label: "Daily calls",
                detail: "Per agent per day: background calls stop until tomorrow at this many. 0: no cap."
            ) {
                Stepper(value: Binding(
                    get: { llm.dailyCalls }, set: { model.setConfig(["llm", "daily_calls"], .integer($0)) }
                ), in: 0 ... 100_000, step: 10) {
                    Text(llm.dailyCalls == 0 ? "no cap" : "\(llm.dailyCalls) calls").font(Theme.mono(12.5))
                }
                .frame(width: 200)
            }
            Field(
                label: "Daily dollars",
                detail: "Per agent per day, counted where a cost is known (reported, or estimated from [usage.prices]). "
                    + "0: no cap."
            ) {
                DollarsField(path: ["llm", "daily_dollars"], value: llm.dailyDollars)
            }
        }
        .disabled(!llm.enabled)
    }
}

/// A dollar amount, written as a TOML number when it is one (0 or more); anything else is said, not written.
private struct DollarsField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: Double
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("$").font(Theme.mono(12.5)).foregroundStyle(Theme.fg3)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12.5))
                .frame(width: 90)
                .focused($focused)
                .onAppear { text = Self.text(value) }
                .onChange(of: value) { if !focused { text = Self.text(value) } }
                .onSubmit(save)
                .onChange(of: focused) { if !focused { save() } }
            if let problem { Text(problem).font(Theme.ui(11.5)).foregroundStyle(Theme.err) }
        }
    }

    static func text(_ value: Double) -> String { String(format: "%.2f", value) }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let dollars = Double(trimmed), dollars >= 0 else {
            problem = "a number of dollars, 0 or more"
            return
        }
        problem = nil
        guard dollars != value else { return }
        model.setConfig(path, .float(dollars))
    }
}

/// `[usage] show_cost`, and how many prices `[usage.prices]` sets.
private struct UsageSettingsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.config.usage
        GroupLabel(title: "Usage")
        Field(
            label: "Show cost",
            detail: "The inspector shows each session's model and tokens, and a cost marked ≈: what the agent "
                + "reported, else an estimate from your prices. Off leaves the cost out."
        ) {
            Toggle("", isOn: Binding(
                get: { usage.showCost }, set: { model.setConfig(["usage", "show_cost"], .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        Field(
            label: "Prices",
            detail: "USD per million tokens by model name prefix, in [usage.prices]. None are built in: with none set "
                + "only reported costs show."
        ) {
            HStack(spacing: 10) {
                let count = usage.prices.byPrefix.count
                Text(count == 0 ? "none set" : "\(count) model\(count == 1 ? "" : "s")").font(Theme.mono(12))
                    .foregroundStyle(count == 0 ? Theme.fg3 : Theme.fg)
                Button("Edit in config.toml") { NSWorkspace.shared.open(model.configFile) }
                    .buttonStyle(.link)
                    .font(Theme.ui(12))
            }
        }
    }
}

/// A system-wide shortcut: typed in vim notation, or recorded from the next key pressed. Checked before it is
/// written, so a shortcut that cannot work never reaches config.toml.
private struct ShortcutField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    /// The other global shortcut, which this one may not repeat.
    let other: String
    @State private var text = ""
    @State private var problem: String?
    @State private var recording = false
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("off", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12.5))
                    .frame(width: 150)
                    .focused($focused)
                    .onAppear { text = value }
                    .onChange(of: value) { if !focused, !recording { text = value } }
                    .onSubmit { save(text) }
                    .onChange(of: focused) { if !focused, !recording { save(text) } }
                if !value.isEmpty { KeyCap(text: KeyCapText.of(value)) }
                Button(recording ? "Press a key…" : "Record") { recording ? stop() : record() }
                Button("Off") { save("") }
                    .buttonStyle(.link)
                    .font(Theme.ui(12))
                    .disabled(value.isEmpty)
            }
            if let problem { Text(problem).font(Theme.ui(11.5)).foregroundStyle(Theme.err) }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let stroke = KeyStroke(event: event) else { return nil }
            MainActor.assumeIsolated {
                if stroke == .escape {
                    stop()
                } else {
                    text = stroke.description
                    stop()
                    save(text)
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func save(_ notation: String) {
        let notation = notation.trimmingCharacters(in: .whitespaces)
        if let problem = GlobalShortcut.problem(notation, other: other) {
            self.problem = problem
            return
        }
        problem = nil
        text = notation
        guard notation != value else { return }
        model.setConfig(path, .string(notation))
    }
}

/// Settings › Hosts: the machines in `[hosts.<name>]`, as config.toml has them. Adding and checking one is gH's (it
/// reads ~/.ssh/config and your tailnet); editing one is the file's.
private struct HostSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hosts = model.config.hosts.values.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 16) {
            Text("Hosts").font(Theme.ui(17, weight: .semibold))
            Text(
                "Machines heed drives over your own ssh, or over your tailnet. gH adds them from ~/.ssh/config or your "
                    + "tailnet and checks what each has (git, zmx, agents); each one's settings are edited in config.toml."
            )
            .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Add or check hosts (gH)") {
                    model.activateHeed()
                    model.perform(CommandInvocation(name: "host.open"))
                }
                Button("Edit in config.toml") { NSWorkspace.shared.open(model.configFile) }
            }
            if hosts.isEmpty {
                Text("No hosts yet. gH lists the ones in ~/.ssh/config and on your tailnet to add.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                    .padding(.top, 6)
            }
            ForEach(hosts, id: \.name) { host in
                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "@\(host.name)")
                    row("ssh", host.ssh, key: "ssh")
                    row(
                        "transport",
                        host.transport?.rawValue ?? "unset: the tailnet when the machine is on it",
                        key: "transport"
                    )
                    if let machine = host.tailscale { row("tailscale", machine, key: "tailscale") }
                    if let user = host.user { row("user", user, key: "user") }
                    row(
                        "repo roots", host.repoRoots.joined(separator: ", ")
                            +
                            (host.explicitRepoRoots || host.repoRoots != HostConfig
                                .defaultRepoRoots ? "" : "  (default)"),
                        key: "repo_roots"
                    )
                    row(
                        "worktree root", host.worktreeRoot
                            + (host.explicitWorktreeRoot || host.worktreeRoot != HostConfig.defaultWorktreeRoot
                                ? "" : "  (default)"),
                        key: "worktree_root"
                    )
                    row("color", host.color ?? "picked from the name", key: "color")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 170, alignment: .leading)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.fg).textSelection(.enabled)
            Spacer(minLength: 8)
            Text(key).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
        }
    }
}
