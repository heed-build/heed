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
                "worktrees": .cleanup, "keys": .keys, "modes": .keys, "pilot": .pilot,
            ]
            return short[key]
        }

        case general = "General", agents = "Agents", colors = "Orgs & repos", cleanup = "Worktrees & cleanup"
        case pilot = "Pilot", keys = "Keys & modes"

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
                    case .cleanup: CleanupSettings()
                    case .pilot: PilotSettingsView()
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
            }
            Text("Custom agents: add an [agents.<name>] table with a command in config.toml.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
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
                label: "Never remove dirty or unpushed work",
                detail: "Always on. Skipped worktrees show a warning instead."
            ) {
                Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
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
