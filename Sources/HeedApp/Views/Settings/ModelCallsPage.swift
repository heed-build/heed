import HeedCore
import SwiftUI

/// Settings › Model calls (`:inference.setup`): where heed's model calls (`[llm]`) and decisions (`[decisions]`)
/// stand, one click to set both up from what this Mac has, the agent, a test, the limits, usage and the reminder.
/// Everything it writes is a single value in config.toml.
struct ModelCallsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.inferenceSetup
        let llm = model.config.llm
        SettingsCard(title: "Set up", bare: true) {
            SetupStatusCard(setup: setup)
        }
        SettingsCard(title: "Model calls") {
            SettingRow("llm.enabled") {
                ConfigSwitch(path: ["llm", "enabled"], isOn: llm.enabled)
            }
            SettingRow(
                "llm.agent",
                detail: "Taking turns: every agent you are logged in to, round-robin. One agent: "
                    + "that one alone. Each with a cheap model.",
                defaultText: "not chosen, taking turns"
            ) {
                AgentChoice(llm: llm, statuses: model.llmStatuses)
            }
            if llm.enabled {
                InfoRow(label: "Detected", detail: "Installed and logged in, as heed runs them (without your shell).") {
                    HStack(spacing: 12) {
                        ForEach(model.llmStatuses) { status in
                            Text(status.name).font(Theme.mono(12))
                                .foregroundStyle(status.usable ? Theme.done : Theme.fg3)
                                .help(AgentChoice.login(status))
                        }
                        Button("Check again") { Task { await model.refreshLLMStatuses(force: true) } }
                            .buttonStyle(.link).font(Theme.ui(12))
                    }
                }
                if let only = llm.only {
                    let detected = model.llmStatuses.first { $0.name == only }?.detectedModel
                    InfoRow(label: "Model", detail: "\(only)'s model for these calls, set on Agents › \(only).") {
                        HStack(spacing: 10) {
                            Text(llm.model(for: only) ?? detected.map { "\($0) (detected)" } ?? "the agent's own")
                                .font(Theme.mono(12))
                            PageLink(page: .agents, title: only) {
                                model.settingsAgent = only
                                model.agentTab = .modelCalls
                            }
                        }
                    }
                }
                InfoRow(label: "Test", detail: testDetail(setup)) {
                    InferenceTestResult(agent: llm.only ?? setup.suggestedAgent, last: model.setupTests.inference)
                }
            }
        }
        SettingsCard(title: "Limits") {
            SettingRow("llm.timeout_seconds", unit: "s") {
                NumberField(
                    path: ["llm", "timeout_seconds"], value: llm.timeoutSeconds, unit: "s", range: 10 ... 900, step: 10
                )
            }
            SettingRow("llm.concurrency", unit: "calls") {
                NumberField(path: ["llm", "concurrency"], value: llm.concurrency, unit: "calls", range: 1 ... 8)
            }
            SettingRow("llm.backoff_minutes", unit: "min") {
                NumberField(
                    path: ["llm", "backoff_minutes"], value: llm.backoffMinutes, unit: "min", range: 0 ... 1440, step: 5
                )
            }
            SettingRow("llm.daily_calls", unit: "calls") {
                NumberField(
                    path: ["llm", "daily_calls"], value: llm.dailyCalls, unit: "calls", range: 0 ... 100_000, step: 10
                )
            }
            SettingRow("llm.daily_dollars", defaultText: "$\(DollarsField.text(HeedConfig.default.llm.dailyDollars))") {
                DollarsField(path: ["llm", "daily_dollars"], value: llm.dailyDollars)
            }
        }
        SettingsCard(title: "Usage") {
            SettingRow("usage.show_cost") {
                ConfigSwitch(path: ["usage", "show_cost"], isOn: model.config.usage.showCost)
            }
            SettingRow("usage.prices", defaultText: "none") {
                TableSummary(count: model.config.usage.prices.byPrefix.count, noun: "model")
            }
        }
        SettingsCard(title: "Reminder") {
            SettingRow("llm.setup_reminder") {
                ConfigSwitch(path: ["llm", "setup_reminder"], isOn: llm.setupReminder)
            }
        }
        .onAppear {
            guard !model.isFixture else { return }
            model.localModel = LocalModels.availability
            Task { await model.refreshLLMStatuses() }
            Task { await model.hunch.refresh() }
        }
    }

    private func testDetail(_ setup: InferenceSetup) -> String {
        let agent = model.config.llm.only ?? setup.suggestedAgent
        let to = model.config.llm.only.map { "to \($0)" }
            ?? agent.map { "to \($0), the first logged in" } ?? "(no agent is logged in)"
        return "One tiny call \(to), never cached; it shows in :log."
    }
}

/// `[llm] agent`: taking turns, or one agent, each with whether it is logged in.
private struct AgentChoice: View {
    @Environment(AppModel.self) private var model
    let llm: LLMSettings
    let statuses: [LLMAgentStatus]

    var body: some View {
        Picker("", selection: Binding(
            get: { llm.agent ?? "" },
            set: { $0.isEmpty ? model.unsetConfig(["llm", "agent"]) : model.setConfig(["llm", "agent"], .string($0)) }
        )) {
            if llm.agent == nil { Text("Not chosen").tag("") }
            Text("Taking turns (auto)").tag(LLMSettings.auto)
            ForEach(statuses) { status in
                Text("\(status.name) · \(Self.login(status))").tag(status.name)
            }
            if let only = llm.only, !statuses.contains(where: { $0.name == only }) {
                Text(only).tag(only)
            }
        }
        .labelsHidden()
        .frame(width: 240)
    }

    static func login(_ status: LLMAgentStatus) -> String {
        switch status.login {
        case .loggedIn: "logged in"
        case .loggedOut: "not logged in"
        case .unknown: "installed"
        case .notInstalled: "not found"
        }
    }
}

/// Settings › Decisions & Hunch: who answers heed's typed questions and a test of it, finding new work's goal with
/// its two thresholds, Hunch, and the screen snapshots a local model learns from.
struct DecisionsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let decisions = model.config.decisions
        let attach = model.config.goals.attach
        SettingsCard(title: "Decisions") {
            SettingRow(
                "decisions.decider",
                detail: "On-device: Apple's model, free, on this Mac only. \(model.localModel.description) Hunch: a "
                    + "Laya checkpoint on this Mac that learns from your corrections. Model call: through Model calls. "
                    + "Off: what asks goes without.",
                defaultText: "a model call", stacked: true
            ) {
                Picker("", selection: Binding(
                    get: { decisions.decider },
                    set: { choice in model.setConfig(["decisions", "decider"], .string(choice?.rawValue ?? "")) }
                )) {
                    if decisions.decider == nil { Text("Not chosen").tag(DecisionSettings.Choice?.none) }
                    Text("On-device").tag(DecisionSettings.Choice?.some(.local))
                    Text("Hunch").tag(DecisionSettings.Choice?.some(.hunch))
                    Text("Model call").tag(DecisionSettings.Choice?.some(.model))
                    Text("Off").tag(DecisionSettings.Choice?.some(.off))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: decisions.decider == nil ? 420 : 340)
            }
            InfoRow(label: "Test", detail: "One decision: where a piece of finished work stands. It shows in :log.") {
                DecisionTestResult(last: model.setupTests.decisions)
                    .disabled(decisions.effective == .off)
            }
        }
        SettingsCard(title: "Finding new work's goal") {
            SettingRow("goals.attach") {
                ConfigSwitch(path: ["goals", "attach"], isOn: attach.enabled)
            }
            SettingRow("goals.attach_auto") {
                NumberField(
                    path: ["goals", "attach_auto"], decimal: attach.auto, range: max(attach.ask, 0.05) ... 1,
                    step: 0.05, places: 2
                )
            }
            SettingRow("goals.attach_ask") {
                NumberField(
                    path: ["goals", "attach_ask"], decimal: attach.ask, range: 0 ... attach.auto, step: 0.05,
                    places: 2
                )
            }
            SettingRow("goals.attach_model") {
                ConfigSwitch(path: ["goals", "attach_model"], isOn: attach.model)
            }
            if attach.enabled {
                InfoRow(
                    label: "Rules",
                    detail: "Your corrections become lines here, and apply before any signal."
                        + (model.goals.attach.rules.problems.isEmpty ? ""
                            : " \(model.goals.attach.rules.problems.count) line(s) heed cannot read are skipped.")
                ) {
                    Text(Paths.tilde(model.goals.files.rules.path))
                        .font(Theme.mono(12)).foregroundStyle(Theme.busy).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .clickable().onTapGesture { model.openAttachRules() }
                        .help("Open attach.rules in your editor")
                }
            }
        }
        HunchCard()
        LocalDecisionsCard()
            .onAppear {
                guard !model.isFixture else { return }
                model.localModel = LocalModels.availability
                Task { await model.hunch.refresh() }
            }
    }
}

/// The top of the pane: each half's state, what goes without, and the one-click setup.
private struct SetupStatusCard: View {
    @Environment(AppModel.self) private var model
    let setup: InferenceSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            line("Model calls", setup.inference)
            line("Decisions", setup.decisions)
            hunchLine(setup.hunch)
            if !setup.degraded.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Until then, these go without:").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    ForEach(setup.degraded, id: \.self) { feature in
                        Text("· " + feature).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                }
            }
            if setup.needsAttention {
                HStack(spacing: 12) {
                    Button(suggestion) { model.applySuggestedSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.suggestedAgent == nil && setup.suggestedDecider == .off)
                    Text("Writes [llm] agent and [decisions] decider, then tests both.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
            // Set up never downloads: the model is offered here, with its size, for you to start.
            if setup.hunch == .noModel, let checkpoint = model.hunch.checkpoint {
                HStack(spacing: 12) {
                    Button("Download \(checkpoint.title) for Hunch (\(HunchCatalogue.size(checkpoint.totalSize)))") {
                        model.perform(CommandInvocation(name: "hunch.download", arguments: [checkpoint.id]))
                    }
                    Text("Decisions on this Mac that learn from you. Weights \(checkpoint.license); nothing downloads "
                        + "until you press it.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var suggestion: String {
        var parts: [String] = []
        if let agent = setup.suggestedAgent { parts.append(agent) }
        let decisions = switch setup.suggestedDecider {
        case .local: "on-device decisions"
        case .hunch: "decisions by Hunch"
        case .model: "decisions by model call"
        case .off: "decisions off"
        }
        parts.append(decisions)
        return "Set up: " + parts.joined(separator: ", ")
    }

    /// Hunch's own line: no model, downloading, ready, learning.
    private func hunchLine(_ status: HunchStatus) -> some View {
        let color: Color = switch status {
        case .ready: Theme.done
        case .learning, .downloading: Theme.block
        case .noModel, .stopped: Theme.fg3
        case .unavailable: Theme.fg3
        }
        let detail: String = switch status {
        case let .unavailable(why): why
        case .noModel: "No model downloaded. Download one below to decide on this Mac and learn from your corrections."
        case let .downloading(fraction):
            "Downloading \(model.hunch.checkpoint?.title ?? "its model")\(Self.percent(fraction))."
        case let .stopped(fraction, reason):
            "The download stopped\(Self.percent(fraction))\(reason.map { ": \($0)" } ?? ""). Resume picks it up."
        case .ready:
            "\(model.hunch.checkpoint?.title ?? "Its model") on this Mac"
                + (model.hunch.record.head == nil ? ", the checkpoint's own head." : ", with a head trained on your "
                    + "corrections.")
        case let .learning(fraction): "Learning from your corrections\(Self.percent(fraction)), in the background."
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Hunch").font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 110, alignment: .leading)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status.label).font(Theme.mono(12)).foregroundStyle(color)
            }
            .frame(width: 130, alignment: .leading)
            Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func percent(_ fraction: Double?) -> String {
        fraction.map { " (\(Int(($0 * 100).rounded(.down)))%)" } ?? ""
    }

    private func line(_ title: String, _ state: SetupState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 110, alignment: .leading)
            HStack(spacing: 6) {
                Circle().fill(SetupColors.of(state)).frame(width: 7, height: 7)
                Text(state.label).font(Theme.mono(12)).foregroundStyle(SetupColors.of(state))
            }
            .frame(width: 130, alignment: .leading)
            Text(state.detail).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum SetupColors {
    static func of(_ state: SetupState) -> Color {
        switch state {
        case .configured: Theme.done
        case .notConfigured: Theme.block
        case .failing: Theme.err
        case .off: Theme.fg3
        }
    }
}

private struct InferenceTestResult: View {
    @Environment(AppModel.self) private var model
    let agent: String?
    let last: SetupTest?

    var body: some View {
        let test = agent.flatMap { model.llmTests[$0] }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(test?.running == true ? "Testing…" : "Test") { model.testInference() }
                .disabled(test?.running == true || agent == nil)
            if let test, !test.running {
                if let error = test.error {
                    Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.summary(test)).font(Theme.mono(12))
                }
            } else if let last, test == nil {
                SetupLastTest(test: last)
            }
        }
    }

    static func summary(_ test: LLMTest) -> String {
        var parts = ["“\(test.answer ?? "")”"]
        if let model = test.model { parts.append(model) }
        if let seconds = test.seconds { parts.append(String(format: "%.1fs", seconds)) }
        if let cost = test.cost { parts.append(cost < 0.01 ? String(format: "$%.4f", cost) : AgentUsage.dollars(cost)) }
        return parts.joined(separator: " · ")
    }
}

private struct DecisionTestResult: View {
    @Environment(AppModel.self) private var model
    let last: SetupTest?

    var body: some View {
        let test = model.decisionTest
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(test?.running == true ? "Testing…" : "Test") { model.testDecision() }
                .disabled(test?.running == true)
            if let test, !test.running {
                if let error = test.error {
                    Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(([test.answer ?? ""] + (test.seconds.map { [String(format: "%.1fs", $0)] } ?? []))
                        .joined(separator: " · "))
                        .font(Theme.mono(12))
                }
            } else if let last, test == nil {
                SetupLastTest(test: last)
            }
        }
    }
}

/// The last test kept from an earlier launch.
private struct SetupLastTest: View {
    let test: SetupTest

    var body: some View {
        Text("last test (\(test.subject)): " + (test.ok ? test.detail : "failed, \(test.detail)"))
            .font(Theme.ui(12))
            .foregroundStyle(test.ok ? Theme.fg2 : Theme.err)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The title bar's reminder while model calls or decisions are not set up (or their last test failed): click to open
/// Settings › Model calls, × to hide it until the next launch; right-click for good.
struct InferenceReminderView: View {
    @Environment(AppModel.self) private var model
    let text: String
    let compact: Bool

    var body: some View {
        let failing = text.hasSuffix("failing")
        let tint = failing ? Theme.err : Theme.block
        HStack(spacing: 6) {
            Button { model.openInferenceSetup() } label: {
                HStack(spacing: 6) {
                    Text(compact ? "setup" : text).fixedSize()
                    if let key = model.keyLabel(for: "inference.setup") { KeyCap(text: key) }
                }
            }
            .buttonStyle(.plain)
            .help("Open Settings › Model calls (:inference.setup)")
            Button { model.hideInferenceReminder(always: false) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Hide until the next launch (:inference.hide; :inference.hide always for good)")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .contextMenu {
            Button("Set up model calls & decisions") { model.openInferenceSetup() }
            Button("Hide until the next launch") { model.hideInferenceReminder(always: false) }
            Button("Don't remind me") { model.hideInferenceReminder(always: true) }
        }
        .shotRegion(.inferenceReminder)
    }
}
