import HeedCore
import SwiftUI

/// Configure… over Settings: 1 Profile (four starting points, or skip), 2 Gaps (the settings worth deciding, each
/// with its own control, Keep default, or the action it needs), 3 Review (the keys Apply writes). The draft lives on
/// the model (`configure`); nothing reaches config.toml before Apply.
struct ConfigureView: View {
    @Environment(AppModel.self) private var model
    let draft: ConfigureDraft

    var body: some View {
        let config = model.config
        let chosen = model.settingsChosen
        let gaps = draft.gaps(config, chosen: chosen, facts: model.gapFacts)
        let changes = draft.changes(config, chosen: chosen)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure heed").font(Theme.ui(17, weight: .semibold))
                    Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                Spacer()
                Button { model.configure = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fg3)
                .help("Close; nothing is written (esc)")
            }
            StepStrip(current: draft.step, gaps: gaps.count, changes: changes.count) { step($0) }
            switch draft.step {
            case .profile: ProfileStep(draft: draft)
            case .gaps: GapsStep(draft: draft, gaps: gaps)
            case .review: ReviewStep(draft: draft, changes: changes)
            }
            foot(gaps: gaps, changes: changes)
        }
        .padding(24)
        .frame(width: 660)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30)
        .onExitCommand { model.configure = nil }
    }

    private var subtitle: String {
        switch draft.step {
        case .profile:
            "Start from a profile, then go through what is still unset. Nothing is written until you apply."
        case .gaps: "Ranked by what each one unlocks. Keep default and heed stops asking about it."
        case .review: "What Apply writes into config.toml. Nothing else changes."
        }
    }

    private func step(_ step: ConfigureDraft.Step) {
        model.configure?.step = step
    }

    @ViewBuilder private func foot(gaps: [SettingsGap], changes: [SettingChange]) -> some View {
        let chosen = model.settingsChosen
        HStack(spacing: 10) {
            Group {
                switch draft.step {
                case .profile:
                    if let plan = draft.plan(model.config, chosen: chosen) {
                        Text("\(plan.profile.title) \(plan.summary)").foregroundStyle(Theme.fg2)
                            + Text(" of your unset settings").foregroundStyle(Theme.fg3)
                    } else {
                        Text("Pick one to start from, or skip straight to the gaps.").foregroundStyle(Theme.fg3)
                    }
                case .gaps:
                    Text("Set one, or Keep default; the rest stay gaps for later.").foregroundStyle(Theme.fg3)
                case .review:
                    let decided = draft.decided(model.config, chosen: chosen).count
                    Text("Writes \(Self.count(changes.count, "key")) · records \(decided) as decided")
                        .foregroundStyle(Theme.fg3)
                }
            }
            .font(Theme.ui(12))
            Spacer(minLength: 8)
            switch draft.step {
            case .profile:
                Button("Skip profile") {
                    model.configure?.pick(nil)
                    step(.gaps)
                }
                .buttonStyle(DialogButtonStyle())
                Button("Next: \(Self.count(gaps.count, "gap"))") { step(.gaps) }
                    .buttonStyle(DialogButtonStyle(primary: true))
                    .disabled(draft.profile == nil)
            case .gaps:
                Button("Back") { step(.profile) }.buttonStyle(DialogButtonStyle())
                Button("Review \(Self.count(changes.count, "change"))") { step(.review) }
                    .buttonStyle(DialogButtonStyle(primary: true))
            case .review:
                Button("Back") { step(.gaps) }.buttonStyle(DialogButtonStyle())
                Button("Apply") { model.applyConfigure() }
                    .buttonStyle(DialogButtonStyle(primary: true))
                    .disabled(changes.isEmpty && draft.decided(model.config, chosen: chosen).isEmpty)
            }
        }
    }

    static func count(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

/// `1 Profile  2 Gaps (5)  3 Review (3)`: the step shown outlined; each one a click away.
private struct StepStrip: View {
    let current: ConfigureDraft.Step
    let gaps: Int
    let changes: Int
    let go: (ConfigureDraft.Step) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ConfigureDraft.Step.allCases, id: \.self) { step in
                let on = step == current
                Button { go(step) } label: {
                    Text(title(step))
                        .font(Theme.ui(11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.fg : Theme.fg3)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(on ? Theme.selected : .clear))
                        .overlay(Capsule().strokeBorder(on ? Theme.fg2 : Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func title(_ step: ConfigureDraft.Step) -> String {
        let number = "\(step.rawValue + 1) \(step.title)"
        return switch step {
        case .profile: number
        case .gaps: "\(number) (\(gaps))"
        case .review: "\(number) (\(changes))"
        }
    }
}

// MARK: Profile

private struct ProfileStep: View {
    @Environment(AppModel.self) private var model
    let draft: ConfigureDraft

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(SettingsProfile.allCases) { profile in
                let on = draft.profile == profile
                Button { model.configure?.pick(on ? nil : profile) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg)
                        Text(profile.summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        let plan = SettingsProfile.apply(profile, to: model.config, chosen: model.settingsChosen)
                        Text(plan.summary).font(Theme.mono(11)).foregroundStyle(on ? Theme.fg2 : Theme.fg3)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.bg3 : Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.fg2 : Theme.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Gaps

private struct GapsStep: View {
    @Environment(AppModel.self) private var model
    let draft: ConfigureDraft
    let gaps: [SettingsGap]

    var body: some View {
        if gaps.isEmpty {
            Text("No gaps: everything that matters is set or decided on.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .settingsCard()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(gaps) { gap in
                        if gap.id != gaps.first?.id { Theme.line.frame(height: 1) }
                        GapRow(gap: gap, draft: draft)
                    }
                }
            }
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
            .settingsCard()
        }
    }
}

/// One gap: its name, impact and what it does on the left; on the right its control (drafting, not writing), or the
/// action it needs; then Keep default, or what was decided with Undo.
private struct GapRow: View {
    @Environment(AppModel.self) private var model
    let gap: SettingsGap
    let draft: ConfigureDraft

    var body: some View {
        let entry = gap.entry
        let decided = draft.isDecided(entry.id)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // `[llm] agent` is what setting model calls up writes; the row is about model calls.
                    Text(gap.action == .setUpModelCalls ? "Model calls" : entry.label).font(Theme.ui(13))
                        .foregroundStyle(Theme.fg)
                    ImpactBadge(impact: entry.impact)
                    Text(entry.page.title).font(Theme.ui(11)).foregroundStyle(Theme.fg3)
                }
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let reason = draft.refused[entry.id] {
                    Text("Not taken: \(reason). Like \(entry.example)").font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                control.fixedSize()
                if decided {
                    HStack(spacing: 4) {
                        Text(draft.edits[entry.id] != nil ? "✓ Set" : "✓ Default kept").foregroundStyle(Theme.done)
                        Button("Undo") { model.configure?.reopen(entry.id) }.buttonStyle(.link)
                    }
                    .font(Theme.ui(11.5))
                } else {
                    Button("Keep default") { model.configure?.keepDefault(entry.id) }
                        .buttonStyle(.link)
                        .font(Theme.ui(11.5))
                        .help("Default: \(SettingsCatalog.defaultValue(entry)?.description ?? "unset"). heed stops "
                            + "asking about it.")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .environment(\.configWrites, drafting)
    }

    private var detail: String {
        switch gap.action {
        case let .installZmx(commands):
            let health = model.zmxHealth
            if let problem = health?.problem, health?.path != nil {
                return "Agents keep running when heed quits or updates. zmx does not work: \(problem)."
            }
            return "Agents keep running when heed quits or updates. zmx is not installed: "
                + commands.joined(separator: "; ") + ", then Check again."
        case .setUpModelCalls:
            let setup = model.inferenceSetup
            let agent = setup.suggestedAgent.map { "\($0) is logged in" } ?? "No agent is logged in yet"
            return "Summaries, goal matching and decisions, through your agent's cheap model. \(agent); "
                + "$\(DollarsField.text(model.config.llm.dailyDollars)) a day at most."
        case nil:
            return gap.entry.detail
        }
    }

    @ViewBuilder private var control: some View {
        let entry = gap.entry
        switch gap.action {
        case .installZmx:
            Button("Check again") { model.checkZmxAgain() }
                .buttonStyle(DialogButtonStyle())
        case .setUpModelCalls:
            if let agent = draft.edits[entry.id] ?? nil {
                Text("\(agent.description), tested on Apply").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            } else {
                Button("Set up & test") { model.draftModelCallsSetup() }
                    .buttonStyle(DialogButtonStyle())
                    .disabled(model.inferenceSetup.suggestedAgent == nil)
                    .help("Drafts [llm] agent and [decisions] decider from what is logged in; tested on Apply")
            }
        case nil:
            GapControl(entry: entry, value: draft.value(entry, in: model.config, chosen: model.settingsChosen))
        }
    }

    /// The controls write into the draft; a value heed would not take is said on the row instead.
    private var drafting: ConfigWrites {
        ConfigWrites(
            onSet: { model, path, toml, _ in
                guard let entry = SettingsCatalog.entry(at: path) else { return }
                if let problem = SettingsCatalog.validate(entry, toml) {
                    model.configure?.refuse(entry.id, problem.reason)
                } else if let value = SettingValue(toml) {
                    model.configure?.set(entry.id, value)
                }
            },
            onUnset: { model, path in
                guard let entry = SettingsCatalog.entry(at: path) else { return }
                model.configure?.set(entry.id, nil)
            }
        )
    }
}

/// The control a gap's page has for it, drafting instead of writing (`ConfigWrites` in the environment).
private struct GapControl: View {
    @Environment(AppModel.self) private var model
    let entry: SettingsEntry
    let value: SettingValue?

    var body: some View {
        let path = entry.key
        switch (entry.id, value) {
        case let ("keys.global_start_work", .text(text)?):
            ShortcutField(path: path, value: text, other: model.config.globalActivate)
        case ("decisions.decider", _):
            MenuChoice(
                path: path, value: Self.text(value),
                options: [
                    ("", "Not chosen"),
                    ("local", "On-device"),
                    ("hunch", "Hunch"),
                    ("model", "Model call"),
                    ("off", "Off"),
                ],
                width: 150
            )
        case let (_, .text(text)?) where Self.choices[entry.id] != nil:
            let options = Self.choices[entry.id] ?? []
            SegmentedChoice(path: path, value: text, options: options, name: { $0 }, width: CGFloat(options.count) * 58)
        case let (_, .bool(flag)?):
            ConfigSwitch(path: path, isOn: flag)
        case let (_, .integer(number)?):
            NumberField(path: path, value: number)
        case let (_, .text(text)?):
            ConfigTextField(
                path: path, value: text, placeholder: Self.placeholders[entry.id] ?? "", width: 160
            )
        default:
            PageLink(page: entry.page)
        }
    }

    static func text(_ value: SettingValue?) -> String {
        if case let .text(text)? = value { text } else { "" }
    }

    /// The short choices, as their pages offer them.
    static let choices: [String: [(String, String)]] = [
        "sessions.persist": [("auto", "Auto"), ("zmx", "zmx"), ("none", "Off")],
        "updates.install": [("ask", "Ask"), ("auto", "Auto")],
        "pilot.green": [("off", "Off"), ("ask", "Ask"), ("auto", "Auto")],
        "pilot.merge": [("off", "Off"), ("auto", "Auto"), ("heed", "heed")],
    ]

    static let placeholders: [String: String] = [
        "attention.quiet": "22:00-07:00",
        "goals.tracker": "org/name",
    ]
}

/// `high` `medium` `low`, as a small tag.
private struct ImpactBadge: View {
    let impact: SettingImpact

    var body: some View {
        let (text, color): (String, Color) = switch impact {
        case .high: ("high", Theme.block)
        case .medium: ("medium", Theme.busy)
        case .low, .none: ("low", Theme.fg3)
        }
        Text(text)
            .font(Theme.ui(10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
    }
}

// MARK: Review

private struct ReviewStep: View {
    @Environment(AppModel.self) private var model
    let draft: ConfigureDraft
    let changes: [SettingChange]

    var body: some View {
        let written = Set(changes.map(\.entry.id))
        let kept = draft.decided(model.config, chosen: model.settingsChosen).subtracting(written)
            .compactMap(SettingsCatalog.entry)
            .sorted { $0.label < $1.label }
        VStack(alignment: .leading, spacing: 10) {
            if changes.isEmpty {
                Text("Nothing to write.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .settingsCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(changes, id: \.key) { change in
                        if change.key != changes.first?.key { Theme.line.frame(height: 1) }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.entry.label).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                                Text(change.key).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                            }
                            Spacer(minLength: 8)
                            Text(change.from?.description ?? "unset").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                                .strikethrough(color: Theme.fg3)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.fg3)
                            Text(change.to?.description ?? "heed's default").font(Theme.mono(12))
                                .foregroundStyle(Theme.done)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
                .settingsCard()
            }
            if !kept.isEmpty {
                Text("Decided, nothing to write: " + kept.map(\.label).joined(separator: ", ") + ".")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The dialog's buttons: outlined, or the light filled one that moves on.
struct DialogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12.5, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Theme.ink : Theme.fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : Theme.bg3))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Theme.keyCapBorder))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
