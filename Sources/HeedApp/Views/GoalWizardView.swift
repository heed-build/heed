import HeedCore
import SwiftUI

/// The new-goal wizard, over the whole of Goals: the six-step rail on the left, the step on the right. Steps 1–3 have
/// screens; Split, How careful and Go show what the goal's page does for them until theirs exist (`WizardLaterStep`).
struct GoalWizardView: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        HStack(spacing: 0) {
            WizardRail(wizard: wizard)
                .frame(width: 232)
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                .shotRegion(.wizardRail)
            Group {
                switch wizard.step {
                case .plan: WizardPlanStep(wizard: wizard)
                case .panel: WizardPanelStep(wizard: wizard)
                case .done: WizardDoneStep(wizard: wizard)
                case .split, .careful, .go: WizardLaterStep(wizard: wizard)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .shotRegion(.goalWizard)
    }
}

// MARK: The rail

private struct WizardRail: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: wizard.finished ? "Goal" : "New goal")
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            ForEach(WizardStep.allCases, id: \.self) { step in
                let state = wizard.state(of: step)
                HStack(spacing: 12) {
                    StepDot(step: step, state: state)
                    Text(step.title)
                        .font(Theme.ui(14, weight: state == .now ? .semibold : .regular))
                        .foregroundStyle(state == .next ? Theme.fg3 : Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 5).fill(state == .now ? Theme.selected : .clear))
                .contentShape(Rectangle())
                .clickRuns(step <= wizard.reach && state != .now
                    ? CommandInvocation(name: "wizard.step", arguments: [step.rawValue]) : nil)
            }
            if let badge = model.tldrBadge(wizard.goal) {
                TLDRRailEntry(badge: badge)
                    .padding(.top, 14)
                    .overlay(alignment: .top) { Theme.line.frame(height: 1).padding(.horizontal, 8) }
                    .padding(.top, 6)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 22)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A step's mark: a check once done, its number ringed while it shows, its number dim ahead.
struct StepDot: View {
    let step: WizardStep
    let state: WizardStepState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.done.opacity(0.28))
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.done)
            case .now:
                Circle().strokeBorder(Theme.block.opacity(0.9), lineWidth: 1.5)
                Text("\(step.number)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.fg)
            case .next:
                Circle().strokeBorder(Theme.keyCapBorder, lineWidth: 1)
                Text("\(step.number)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: Shared pieces

/// A step's title and its quiet subtitle.
private struct StepHeader<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(Theme.ui(22, weight: .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                .layoutPriority(1)
            Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let goal = model.goals.wizard.open, model.tldrBadge(goal) != nil {
                TLDRChip(goal: goal).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            trailing
        }
    }
}

extension StepHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// What a step's calls cost: a dot, the model, the dollars (≈ when estimated or partly unknown).
private struct CostLine: View {
    let wizard: GoalWizard
    let step: WizardStep
    var extra: [String] = []

    var body: some View {
        let model = wizard.model(for: step)
        let dollars = wizard.dollars(for: step).map(AgentUsage.dollars)
        let partial = wizard.costIsPartial(for: step)
        let parts = [model] + extra.map(Optional.some)
            + [dollars.map { (partial ? "≈" : "") + $0 } ?? (model == nil ? nil : "cost unknown")]
        HStack(spacing: 6) {
            Circle().fill(Theme.ask).frame(width: 6, height: 6)
            Text(parts.compactMap(\.self).joined(separator: " · "))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
        .help("What this step's model calls cost so far, as the agents reported it (≈: estimated or partly unknown)")
        .opacity(model == nil && extra.isEmpty ? 0 : 1)
    }
}

/// A primary action: a light button with its key.
private struct PrimaryAction: View {
    let label: String
    let command: String
    var arguments: [String] = []
    let scope: String

    var body: some View {
        WizardButton(label: label, command: command, arguments: arguments, scope: scope, primary: true)
    }
}

private struct WizardButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    var icon: String?
    let command: String
    var arguments: [String] = []
    let scope: String
    var primary = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 11)) }
            Text(label).font(Theme.ui(13.5, weight: primary ? .semibold : .regular)).lineLimit(1)
            Text(model.keyText(for: command, in: scope))
                .font(Theme.mono(10))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(primary ? Theme.ink : Theme.keyCap))
                .foregroundStyle(primary ? Theme.inverse : Theme.fg2)
        }
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(primary ? Theme.inverse : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(primary ? .clear : Theme.keyCapBorder))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command, arguments: arguments))
    }
}

/// "heed is thinking…", or what went wrong.
private struct BusyLine: View {
    @Environment(AppModel.self) private var model
    let goal: String

    var body: some View {
        if let busy = model.goals.wizard.busy[goal] {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy + "…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            }
        } else if let problem = model.goals.wizard.problem[goal] {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.err)
                Text(problem).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(3)
            }
        }
    }
}

/// The text field of the step, when you type; else a quiet prompt to press `i`.
private struct WizardInput: View {
    @Environment(AppModel.self) private var model
    let placeholder: String
    let scope: String
    @FocusState private var focused: Bool

    var body: some View {
        let typing = model.goals.wizard.typing
        HStack(spacing: 10) {
            Image(systemName: "bolt").font(.system(size: 12)).foregroundStyle(Theme.fg3)
            if let typing {
                let binding = Binding(
                    get: { model.goals.wizard.typing?.text ?? "" },
                    set: { model.goals.wizard.typing?.text = $0 }
                )
                if ShotMode.active {
                    Text(typing.text.isEmpty ? placeholder : typing.text)
                        .foregroundStyle(typing.text.isEmpty ? Theme.fg3 : Theme.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: binding)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { model.submitWizardTyping() }
                        .onAppear { focused = true }
                }
            } else {
                Text(placeholder).foregroundStyle(Theme.fg3).frame(maxWidth: .infinity, alignment: .leading)
            }
            KeyCap(text: typing == nil ? model.keyText(for: "wizard.answer", in: scope) : "↩")
        }
        .font(Theme.ui(14))
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(typing == nil ? Theme.line : Theme.paneActive))
        .contentShape(Rectangle())
        .onTapGesture { if typing == nil { model.perform(CommandInvocation(name: "wizard.answer")) } }
    }
}

// MARK: Step 1, Plan

private struct WizardPlanStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Talk the plan through", subtitle: "heed asks until the plan has what agents need")
                ScrollViewReader { proxy in
                    ListScroll {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(wizard.plan.turns.enumerated()), id: \.offset) { index, turn in
                                PlanTurnView(turn: turn, open: index == wizard.plan.turns.count - 1)
                                    .id(index)
                            }
                            BusyLine(goal: wizard.goal)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: wizard.plan.turns.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
                }
                WizardInput(placeholder: "Answer, or \"good enough\"…", scope: "wizardplan")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .shotRegion(.wizardPlan)
            PlanSide(wizard: wizard)
                .frame(width: 440)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.bg2.opacity(0.4))
                .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
        }
    }
}

private struct PlanTurnView: View {
    @Environment(AppModel.self) private var model
    let turn: PlanTurn
    let open: Bool

    var body: some View {
        switch turn.role {
        case .you:
            HStack {
                Spacer(minLength: 120)
                Text(turn.text)
                    .font(Theme.ui(15))
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .heed:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "star").font(.system(size: 10))
                    Text("heed").font(Theme.mono(11.5, weight: .semibold))
                    if let model = turn.model {
                        Text("·").font(Theme.mono(11.5))
                        Text(model).font(Theme.mono(11.5)).foregroundStyle(Theme.ask)
                    }
                }
                .foregroundStyle(Theme.ask)
                Text(turn.text)
                    .font(Theme.ui(15))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if !turn.options.isEmpty {
                    FlowLayout(spacing: 10, lineSpacing: 8) {
                        ForEach(Array(turn.options.enumerated()), id: \.offset) { index, option in
                            OptionChip(
                                number: open ? index + 1 : nil, text: option, picked: turn.picked.contains(index),
                                answered: !turn.picked.isEmpty
                            )
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        }
    }
}

/// An option heed offers: numbered while it can be picked, checked once it was.
private struct OptionChip: View {
    let number: Int?
    let text: String
    let picked: Bool
    let answered: Bool

    var body: some View {
        HStack(spacing: 8) {
            if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            if let number { Text("\(number)").font(Theme.mono(12)).foregroundStyle(Theme.fg3) }
            Text(text).font(Theme.ui(14)).lineLimit(1)
        }
        .foregroundStyle(picked ? Theme.ink : answered ? Theme.fg3 : Theme.fg)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(picked ? .clear : Theme.keyCapBorder))
        .clickRuns(number.map { CommandInvocation(name: "wizard.pick", arguments: [String($0)]) })
    }
}

/// The plan as it stands (its version) and the meters.
private struct PlanSide: View {
    let wizard: GoalWizard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListScroll {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 11))
                        SectionHeader(title: "The plan" + (wizard.plan.versions.last.map { " · v\($0.number)" } ?? ""))
                    }
                    .foregroundStyle(Theme.fg3)
                    if let plan = wizard.plan.current {
                        Text(plan.title).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.fg)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                                        .frame(width: 20, height: 20)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.chip))
                                    Text(step).font(Theme.ui(14)).foregroundStyle(Theme.fg)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        Text("The plan builds here as you answer.").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                    }
                    Meters(completeness: wizard.plan.completeness)
                        .padding(.top, 14)
                        .shotRegion(.wizardMeters)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                PrimaryAction(label: "Good enough", command: "wizard.next", scope: "wizardplan")
                Spacer()
                CostLine(wizard: wizard, step: .plan)
            }
            .padding(24)
        }
    }
}

/// The five completeness meters: green once enough, amber under it.
private struct Meters: View {
    let completeness: Completeness?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10))
                SectionHeader(title: "How complete")
            }
            .foregroundStyle(Theme.fg3)
            ForEach(Completeness.Dimension.allCases, id: \.self) { dimension in
                let value = completeness?[dimension]
                HStack(spacing: 12) {
                    Text(dimension.label).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                        .frame(width: 130, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.chip)
                            Capsule().fill((value ?? 0) >= 70 ? Theme.done : Theme.block)
                                .frame(width: geometry.size.width * CGFloat(value ?? 0) / 100)
                        }
                    }
                    .frame(height: 4)
                    Text(value.map(String.init) ?? "–").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: Step 2, Panel

private struct WizardPanelStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let panel = wizard.panel
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text("The panel").font(Theme.ui(22, weight: .bold)).foregroundStyle(Theme.fg)
                if !panel.latest.isEmpty {
                    HStack(spacing: 14) {
                        tally(panel.count(.happy), "checkmark", Theme.done)
                        tally(panel.count(.concern), "questionmark", Theme.block)
                        tally(panel.count(.not), "arrow.left.arrow.right", Theme.err)
                    }
                }
                Spacer(minLength: 8)
                if model.tldrBadge(wizard.goal) != nil {
                    TLDRChip(goal: wizard.goal).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                HStack(spacing: 8) {
                    Text("invited:").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    ForEach(reasons, id: \.self) { why in
                        Text(why).font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.chip))
                    }
                    WizardButton(label: "", icon: "plus", command: "wizard.invite", scope: "wizardpanel")
                }
            }
            ListScroll {
                VStack(spacing: 14) {
                    if let skeptic = panel.seats.first(where: { $0.id == PanelInvites.skeptic.id }) {
                        SeatCard(seat: skeptic, verdict: panel.verdict(of: skeptic.id), row: 0, wide: true)
                    }
                    let rest = Array(panel.seats.enumerated()).filter { $0.element.id != PanelInvites.skeptic.id }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                        ForEach(rest, id: \.element.id) { index, seat in
                            SeatCard(seat: seat, verdict: panel.verdict(of: seat.id), row: index, wide: false)
                        }
                    }
                    BusyLine(goal: wizard.goal).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let chat = model.goals.wizard.chat { PersonaChatView(chat: chat) }
            if model.goals.wizard.typing?.kind == .dropReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why not? It goes in GOAL.md's decisions, and the goal is archived.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                    WizardInput(placeholder: "The reason", scope: "wizardpanel")
                }
            }
            Theme.line.frame(height: 1)
            HStack(spacing: 12) {
                PrimaryAction(
                    label: panel.next == .advance && !panel.latest.isEmpty ? "Worth it, on to done"
                        : "Worth it, take the fixes",
                    command: "wizard.next", scope: "wizardpanel"
                )
                WizardButton(
                    label: "Go smaller",
                    icon: "square.stack.3d.down.right",
                    command: "wizard.smaller",
                    scope: "wizardpanel"
                )
                WizardButton(
                    label: "Talk to one",
                    icon: "arrow.left.arrow.right",
                    command: "wizard.talk",
                    scope: "wizardpanel"
                )
                WizardButton(label: "Don't do it", command: "wizard.drop", scope: "wizardpanel")
                Spacer(minLength: 12)
                CostLine(wizard: wizard, step: .panel, extra: [
                    "\(panel.seats.count) personas", "round \(max(panel.rounds.count, 1))/\(PanelState.maxRounds)",
                ])
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .overlay(alignment: .topTrailing) {
            if let offered = model.goals.wizard.inviting {
                InvitePicker(offered: offered).padding(.top, 70).padding(.trailing, 32)
            }
        }
        .shotRegion(.wizardPanel)
    }

    private var reasons: [String] {
        var seen: [String] = []
        for seat in wizard.panel.seats where !seen.contains(seat.why) {
            seen.append(seat.why)
        }
        return seen
    }

    private func tally(_ count: Int, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            Text("\(count)").font(Theme.ui(17, weight: .semibold)).foregroundStyle(Theme.fg)
        }
    }
}

/// A persona's tint: its identity, the same in every round.
private func seatTint(_ id: String) -> Color {
    switch id {
    case "skeptic", "security": Theme.err
    case "ux", "operator": Color(hex: 0x4FB8B0)
    case "dx", "performance": Theme.busy
    case "purist", "accessibility": Theme.ask
    case "adversary": Theme.block
    case "newcomer": Theme.done
    case "scope-keeper": Color(hex: 0xE59A6B)
    default: Theme.fg2
    }
}

private struct SeatCard: View {
    @Environment(AppModel.self) private var model
    let seat: PanelSeat
    let verdict: PanelVerdict?
    let row: Int
    let wide: Bool

    var body: some View {
        let tint = seatTint(seat.id)
        let cursor = model.goals.wizard.row == row
        let mood: Color? = switch verdict?.kind {
        case .not: Theme.err
        case .concern: Theme.block
        default: nil
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(seat.initial)
                    .font(Theme.ui(16, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(seat.name).font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(seat.role).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Spacer(minLength: 4)
                VerdictGlyph(kind: verdict?.kind)
                    .help(seat.why == "always" ? "Always on the panel" : "Invited: \(seat.why)")
            }
            Text(verdict.map { "“\($0.quote)”" } ?? "reading…")
                .font(Theme.ui(14.5)).foregroundStyle(verdict == nil ? Theme.fg3 : Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(wide ? 2 : 3)
            if let fix = verdict?.fix {
                Text(fix).font(Theme.mono(11.5)).foregroundStyle(mood ?? Theme.fg2).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill((mood ?? Theme.fg3).opacity(0.14)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: wide ? 0 : 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill((mood ?? Theme.bg3).opacity(mood == nil ? 0.45 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
            cursor ? Theme.paneActive : (mood ?? Theme.line).opacity(mood == nil ? 1 : 0.45),
            lineWidth: cursor ? 1.5 : 1
        ))
        .contentShape(Rectangle())
        .onTapGesture { model.goals.wizard.row = row }
    }
}

/// happy ✓, concern ?, not ⇄ (it argues the other way).
private struct VerdictGlyph: View {
    let kind: PanelVerdict.Kind?

    var body: some View {
        let (icon, color): (String, Color) = switch kind {
        case .happy: ("checkmark", Theme.done)
        case .concern: ("questionmark", Theme.block)
        case .not: ("arrow.left.arrow.right", Theme.err)
        case nil: ("ellipsis", Theme.fg3)
        }
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(Circle().fill(color.opacity(0.16)))
    }
}

private struct PersonaChatView: View {
    let chat: PersonaChat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11))
                SectionHeader(title: "Talking to \(chat.seat.name)")
                Spacer()
                KeyHint(keys: "<Esc>", label: "close")
            }
            .foregroundStyle(Theme.fg3)
            ForEach(Array(chat.lines.enumerated()), id: \.offset) { _, line in
                HStack {
                    if line.fromYou { Spacer(minLength: 80) }
                    Text(line.text).font(Theme.ui(13.5)).foregroundStyle(Theme.fg)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(line.fromYou ? Theme.bg3 : seatTint(chat.seat.id).opacity(0.1)))
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.fromYou { Spacer(minLength: 80) }
                }
            }
            WizardInput(placeholder: "Ask \(chat.seat.name)…", scope: "wizardchat")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }
}

private struct InvitePicker: View {
    @Environment(AppModel.self) private var model
    let offered: [PanelSeat]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Invite").padding(.bottom, 6)
            ForEach(Array(offered.enumerated()), id: \.element.id) { index, seat in
                HStack(spacing: 10) {
                    Text(seat.initial).font(Theme.ui(12, weight: .bold)).foregroundStyle(seatTint(seat.id))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(seatTint(seat.id).opacity(0.16)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(seat.name).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.fg)
                        Text(seat.role).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(index == model.goals.wizard.inviteRow ? Theme.selected : .clear))
                .contentShape(Rectangle())
                .onTapGesture {
                    model.goals.wizard.inviteRow = index
                    model.perform(CommandInvocation(name: "wizard.invite.pick"))
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.keyCapBorder))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

// MARK: Step 3, Done looks like

private struct WizardDoneStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let draft = wizard.criteria
        let tally = Checkability.tally(draft.criteria)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(
                    title: "What does done look like",
                    subtitle: "from the agreed plan · each needs a way to check it"
                )
                if !draft.statement.isEmpty {
                    Text(draft.statement)
                        .font(Theme.ui(15)).foregroundStyle(Theme.fg)
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 10))
                    SectionHeader(title: "Done when")
                    Spacer()
                    HStack(spacing: 10) {
                        Label("\(tally.checked)", systemImage: "checkmark").foregroundStyle(Theme.done)
                        Label("\(tally.proposed)", systemImage: "questionmark").foregroundStyle(Theme.block)
                        Label("\(tally.unchecked)", systemImage: "questionmark").foregroundStyle(Theme.err)
                    }
                    .font(Theme.mono(11))
                    .labelStyle(TightLabel())
                }
                .foregroundStyle(Theme.fg3)
                ListScroll {
                    VStack(spacing: 8) {
                        ForEach(Array(draft.criteria.enumerated()), id: \.offset) { index, criterion in
                            CriterionRow(criterion: criterion, row: index)
                        }
                        if !draft.notTheGoal.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11))
                                Text("not the goal:").font(Theme.mono(11.5))
                                ForEach(draft.notTheGoal, id: \.self) { item in
                                    Text(item).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.chip))
                                }
                                Spacer()
                            }
                            .foregroundStyle(Theme.fg3)
                            .padding(.top, 10)
                        }
                        BusyLine(goal: wizard.goal).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Theme.line.frame(height: 1)
                HStack(spacing: 12) {
                    PrimaryAction(label: "Looks right · split it", command: "wizard.next", scope: "wizarddone")
                    if draft.firstVague != nil {
                        WizardButton(
                            label: "Define the vague one",
                            icon: "play",
                            command: "wizard.define",
                            scope: "wizarddone"
                        )
                    }
                    Spacer()
                    CostLine(
                        wizard: wizard,
                        step: .done,
                        extra: draft.fromPlan.map { ["from plan v\($0)"] } ?? []
                    )
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .shotRegion(.wizardDone)
            ReplacementSide(wizard: wizard)
                .frame(width: 440)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.bg2.opacity(0.4))
                .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
                .shotRegion(.wizardReplacements)
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

private struct CriterionRow: View {
    @Environment(AppModel.self) private var model
    let criterion: DoneCriterion
    let row: Int

    var body: some View {
        let cursor = model.goals.wizard.row == row
        let score = criterion.checkability
        let color = score >= 1 ? Theme.done : score >= 0.5 ? Theme.block : Theme.err
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
            Text(criterion.text).font(Theme.ui(15)).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            Text(criterion.check.label)
                .font(Theme.mono(11.5)).foregroundStyle(criterion.check.kind == .none ? Theme.err : Theme.fg3)
                .lineLimit(1).truncationMode(.middle)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip)
                    Capsule().fill(color).frame(width: geometry.size.width * score)
                }
            }
            .frame(width: 84, height: 4)
            .help("How surely an agent can tell it is met: \(Int(score * 100))%")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cursor ? Theme.fg : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.goals.wizard.row = row
            model.goals.wizard.pick = 0
        }
    }

    private var icon: String {
        switch criterion.check.kind {
        case .test: "checkmark"
        case .ci: "checkmark.shield"
        case .command: "play"
        case .none: "questionmark"
        }
    }
}

/// The criterion under the cursor: its measurable replacements (↩ uses the highlighted one), and defining it with an
/// agent.
private struct ReplacementSide: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let row = model.goals.wizard.row
        let criteria = wizard.criteria.criteria
        VStack(alignment: .leading, spacing: 14) {
            if criteria.indices.contains(row) {
                let criterion = criteria[row]
                let options = wizard.criteria.replacements(for: row) ?? []
                HStack(spacing: 8) {
                    Image(systemName: criterion.check.kind == .none ? "questionmark" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(criterion.check.kind == .none ? Theme.err : Theme.done)
                    SectionHeader(title: "\(row + 1) · \(criterion.text)").lineLimit(1)
                }
                Text(explanation(criterion, options: options))
                    .font(Theme.ui(13.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let highlighted = index == model.goals.wizard.pick
                    HStack(spacing: 14) {
                        Image(systemName: option.lowercased().hasPrefix("drop it") ? "arrow.left.arrow.right"
                            : index == 0 ? "clock" : "checkmark")
                            .font(.system(size: 12)).foregroundStyle(Theme.fg3).frame(width: 18)
                        Text(option).font(Theme.ui(14)).foregroundStyle(Theme.fg).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(highlighted ? Theme.done.opacity(0.08) : Theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(highlighted ? Theme.done.opacity(0.7) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.perform(CommandInvocation(name: "wizard.pick", arguments: [String(index + 1)]))
                    }
                }
                if criterion.check.kind == .none {
                    HStack(spacing: 8) {
                        Image(systemName: "play").font(.system(size: 9))
                        SectionHeader(title: "Or define it with an agent")
                    }
                    .foregroundStyle(Theme.fg3)
                    .padding(.top, 8)
                    .clickRuns(CommandInvocation(name: "wizard.define"))
                    Text(
                        "an agent reads the repos, read-only, and proposes checks it can run; they join the list above"
                    )
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if options.indices.contains(model.goals.wizard.pick) {
                    PrimaryAction(
                        label: "Use " + short(options[model.goals.wizard.pick]),
                        command: "wizard.use",
                        scope: "wizarddone"
                    )
                }
            } else {
                Text("The criteria come from the agreed plan.").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                Spacer()
            }
        }
        .padding(24)
    }

    private func explanation(_ criterion: DoneCriterion, options: [String]) -> String {
        if criterion.check.kind != .none { return "Checked by \(criterion.check.label)." }
        if criterion.vague { return "Nothing can check it as written. Pick a measurable one, or drop it." }
        return options.isEmpty ? "Nothing checks this yet." : "Nothing checks this yet. Pick one, or define it."
    }

    private func short(_ text: String) -> String {
        let words = text.split(separator: " ")
        return words.count > 5 ? words.suffix(4).joined(separator: " ") : text
    }
}

// MARK: Steps 4–6

/// A step heed has no wizard screen for yet: what it will do, and the goal's page that does it today.
private struct WizardLaterStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: wizard.step.title, subtitle: subtitle)
            Text(detail).font(Theme.ui(14)).foregroundStyle(Theme.fg2).frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                WizardButton(label: place, icon: "arrow.up.right", command: "wizard.later", scope: "wizardlater")
                WizardButton(label: "Done here, on", command: "wizard.next", scope: "wizardlater")
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
    }

    private var subtitle: String {
        switch wizard.step {
        case .split: "who does which part"
        case .careful: "how much checking the work gets"
        default: "start it"
        }
    }

    private var detail: String {
        switch wizard.step {
        case .split:
            "The wizard's own board for this comes in a later heed. Today a swarm splits the plan: its lead proposes "
                + "the parts and who takes each, and you steer it."
        case .careful:
            "The wizard's choice of Quick, Standard or Thorough comes in a later heed. Today the goal's reviewers and "
                + "their bars decide how careful the work is."
        default:
            "Starting from the wizard comes in a later heed. Today the goal's page starts the work: a session, or a "
                + "swarm."
        }
    }

    private var place: String {
        switch wizard.step.fallback {
        case .swarm: "Open the swarm plan"
        case .reviewers: "Open the reviewers"
        default: "Open the goal's page"
        }
    }
}

// MARK: The TL;DR's entries

/// The TL;DR as a seventh item under the rail's steps: its icon, its name, news since you last opened it (a dot, or
/// the open points' count, amber when one needs you), and its key.
private struct TLDRRailEntry: View {
    @Environment(AppModel.self) private var model
    let badge: TLDRBadge

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fg2)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chip))
            Text("TL;DR").font(Theme.ui(14)).foregroundStyle(Theme.fg).lineLimit(1)
            if badge.news { TLDRNews(badge: badge) }
            Spacer(minLength: 0)
            KeyCap(text: model.keyText(for: "goal.tldr", in: model.goals.scope))
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: "goal.tldr"))
        .help(badge.news ? "The TL;DR has news since you last opened it" : "The goal's TL;DR")
    }
}

/// News on the TL;DR: the open points' count, amber when one needs you; a dot when none is open.
struct TLDRNews: View {
    let badge: TLDRBadge

    var body: some View {
        let color = badge.needsYou ? Theme.block : Theme.fg2
        if badge.open > 0 {
            Text("\(badge.open)").font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(color))
        } else {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

/// A quiet TL;DR chip beside a title: the wizard's steps and the goal's page.
struct TLDRChip: View {
    @Environment(AppModel.self) private var model
    let goal: String

    var body: some View {
        let badge = model.tldrBadge(goal)
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft").font(.system(size: 10, weight: .semibold))
            Text("TL;DR").font(Theme.ui(12))
            if let badge, badge.news { TLDRNews(badge: badge) }
            KeyCap(text: model.keyText(for: "goal.tldr", in: model.goals.scope))
        }
        .foregroundStyle(Theme.fg2)
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
        .fixedSize()
        .clickRuns(CommandInvocation(name: "goal.tldr"))
    }
}
