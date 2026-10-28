import HeedCore
import SwiftUI

/// Settings › Inference & decisions (`:inference.setup`): where heed's model calls (`[llm]`) and decisions
/// (`[decisions]`) stand, one click to set both up from what this Mac has, and a test of each. Everything it writes is
/// a single value in config.toml.
struct InferenceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.inferenceSetup
        VStack(alignment: .leading, spacing: 16) {
            Text("Inference & decisions").font(Theme.ui(17, weight: .semibold))
            Text(
                "heed makes short model calls of its own (summaries, drafted replies, goal plans) through an agent CLI "
                    + "you are logged in to, and asks typed questions (decisions) of Apple's on-device model or a model "
                    + "call. No API keys: your logins are used as they are."
            )
            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            SetupStatusCard(setup: setup)
            InferenceGroup(setup: setup)
            DecisionsGroup(setup: setup)
            SetupGroupLabel(title: "Reminder")
            SetupRow(
                label: "Remind me on launch",
                detail: "While model calls or decisions are not set up, or their last test failed, the title bar says "
                    + "so until you set them up or hide it (:inference.hide; always: for good)."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.llm.setupReminder },
                    set: { model.setConfig(["llm", "setup_reminder"], .bool($0)) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .onAppear {
            guard !model.isFixture else { return }
            model.localModel = LocalModels.availability
            Task { await model.refreshLLMStatuses() }
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var suggestion: String {
        var parts: [String] = []
        if let agent = setup.suggestedAgent { parts.append(agent) }
        parts.append(setup.suggestedDecider == .local ? "on-device decisions" : setup.suggestedDecider == .model
            ? "decisions by model call" : "decisions off")
        return "Set up: " + parts.joined(separator: ", ")
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

/// `[llm]`: which agent, its model, the daily budget, and a test.
private struct InferenceGroup: View {
    @Environment(AppModel.self) private var model
    let setup: InferenceSetup

    var body: some View {
        let llm = model.config.llm
        let statuses = model.llmStatuses
        SetupGroupLabel(title: "Inference")
        SetupRow(
            label: "Model calls",
            detail: "Off: heed makes no model calls at all, and decisions by model call go without."
        ) {
            Toggle("", isOn: Binding(get: { llm.enabled }, set: { model.setConfig(["llm", "enabled"], .bool($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        Group {
            SetupRow(
                label: "Agent",
                detail: "Taking turns: every agent you are logged in to, round-robin. One agent: that one alone. "
                    + "Each with a cheap model."
            ) {
                Picker("", selection: Binding(
                    get: { llm.agent ?? "" },
                    set: { model.setConfig(["llm", "agent"], .string($0)) }
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
                .frame(width: 300)
            }
            SetupRow(label: "Detected", detail: "Installed and logged in, as heed runs them (without your shell).") {
                HStack(spacing: 12) {
                    ForEach(statuses) { status in
                        Text(status.name).font(Theme.mono(12))
                            .foregroundStyle(status.usable ? Theme.done : Theme.fg3)
                            .help(Self.login(status))
                    }
                    Button("Check again") { Task { await model.refreshLLMStatuses(force: true) } }
                        .buttonStyle(.link).font(Theme.ui(12))
                }
            }
            if let only = llm.only {
                let detected = statuses.first { $0.name == only }?.detectedModel
                SetupRow(
                    label: "Model",
                    detail: "Empty: \(detected.map { "\($0), detected" } ?? "the agent's own default"). "
                        + "[agents.\(only)] llm_model."
                ) {
                    SetupTextField(path: ["agents", only, "llm_model"], value: llm.model(for: only) ?? "")
                        .frame(width: 260)
                }
            }
            SetupRow(
                label: "Daily budget",
                detail: "Per agent per day: background calls stop until tomorrow at this many calls or dollars (where a "
                    + "cost is known). Calls you ask for still run. 0: no cap."
            ) {
                HStack(spacing: 14) {
                    Stepper(value: Binding(
                        get: { llm.dailyCalls }, set: { model.setConfig(["llm", "daily_calls"], .integer($0)) }
                    ), in: 0 ... 100_000, step: 10) {
                        Text(llm.dailyCalls == 0 ? "no cap" : "\(llm.dailyCalls) calls").font(Theme.mono(12.5))
                    }
                    .frame(width: 180)
                    SetupDollarsField(value: llm.dailyDollars)
                }
            }
            SetupRow(label: "Test", detail: testDetail) {
                InferenceTestResult(agent: testAgent, last: model.setupTests.inference)
            }
        }
        .disabled(!llm.enabled)
    }

    private var testAgent: String? { model.config.llm.only ?? setup.suggestedAgent }

    private var testDetail: String {
        let to = model.config.llm.only.map { "to \($0)" }
            ?? testAgent.map { "to \($0), the first logged in" } ?? "(no agent is logged in)"
        return "One tiny call \(to), never cached; it shows in :log."
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

/// `[decisions]`: which decider, the thresholds decisions act on, and a test.
private struct DecisionsGroup: View {
    @Environment(AppModel.self) private var model
    let setup: InferenceSetup

    var body: some View {
        let decisions = model.config.decisions
        SetupGroupLabel(title: "Decisions")
        SetupRow(
            label: "Decider",
            detail: "On-device: Apple's model, free, on this Mac only. \(model.localModel.description) Model call: "
                + "through Inference above. Off: what asks goes without."
        ) {
            Picker("", selection: Binding(
                get: { decisions.decider },
                set: { choice in model.setConfig(["decisions", "decider"], .string(choice?.rawValue ?? "")) }
            )) {
                if decisions.decider == nil { Text("Not chosen").tag(DecisionSettings.Choice?.none) }
                Text("On-device").tag(DecisionSettings.Choice?.some(.local))
                Text("Model call").tag(DecisionSettings.Choice?.some(.model))
                Text("Off").tag(DecisionSettings.Choice?.some(.off))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: decisions.decider == nil ? 400 : 300)
        }
        let attach = model.config.goals.attach
        SetupRow(
            label: "Attach on its own at",
            detail: "Finding new work's goal: at this confidence or more heed attaches, with undo (u). The same as "
                + "General › Goals."
        ) {
            threshold("attach_auto", attach.auto, range: max(attach.ask, 0.05) ... 1)
        }
        SetupRow(label: "Ask from", detail: "From here up to the line above heed asks; below, it leaves the work.") {
            threshold("attach_ask", attach.ask, range: 0 ... attach.auto)
        }
        SetupRow(label: "Test", detail: "One decision: where a piece of finished work stands. It shows in :log.") {
            DecisionTestResult(last: model.setupTests.decisions)
        }
        .disabled(decisions.effective == .off)
    }

    private func threshold(_ key: String, _ value: Double, range: ClosedRange<Double>) -> some View {
        Stepper(value: Binding(
            get: { value }, set: { model.setConfig(["goals", key], .float(($0 * 100).rounded() / 100)) }
        ), in: range, step: 0.05) {
            Text(String(format: "%.2f", value)).font(Theme.mono(12.5))
        }
        .frame(width: 160)
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

/// A group on the page: its name over a rule.
private struct SetupGroupLabel: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            Theme.line.frame(height: 1)
        }
        .padding(.top, 10)
    }
}

/// A labelled row, as on the other pages.
private struct SetupRow<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 170, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                content
                if let detail {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A text field written to config.toml on return or when it loses focus.
private struct SetupTextField: View {
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

/// `[llm] daily_dollars`, written as a number of dollars, 0 or more.
private struct SetupDollarsField: View {
    @Environment(AppModel.self) private var model
    let value: Double
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("$").font(Theme.mono(12.5)).foregroundStyle(Theme.fg3)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12.5))
                .frame(width: 70)
                .focused($focused)
                .onAppear { text = String(format: "%.2f", value) }
                .onChange(of: value) { if !focused { text = String(format: "%.2f", value) } }
                .onSubmit(save)
                .onChange(of: focused) { if !focused { save() } }
            Text("a day").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            if let problem { Text(problem).font(Theme.ui(11.5)).foregroundStyle(Theme.err) }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let dollars = Double(trimmed), dollars >= 0 else {
            problem = "a number of dollars, 0 or more"
            return
        }
        problem = nil
        guard dollars != value else { return }
        model.setConfig(["llm", "daily_dollars"], .float(dollars))
    }
}

/// The title bar's reminder while model calls or decisions are not set up (or their last test failed): click to open
/// Settings › Inference & decisions, × to hide it until the next launch; right-click for good.
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
            .help("Open Settings › Inference & decisions (:inference.setup)")
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
