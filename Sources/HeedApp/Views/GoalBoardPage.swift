import HeedCore
import SwiftUI

/// The goal's page for a goal with a plan of parts: its title, the journey bar, the one next step for you, the Split
/// board live (done, running, asking, waiting, the now line), and the numbers under it. A part folds out as in Split,
/// with Steer for a running one.
struct GoalBoardPage: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let page: GoalPage

    var body: some View {
        let browser = model.goals.wizard
        let rows = model.splitRowsOnPage(page)
        ListScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(goal.title).font(Theme.ui(21, weight: .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(Set(page.draft.active.compactMap(\.agent)).count.description + " agents")
                        .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                    Spacer(minLength: 8)
                    if model.tldrBadge(goal.id) != nil { TLDRChip(goal: goal.id) }
                }
                JourneyBar(journey: page.journey)
                if let next = page.next { NextStepBanner(next: next).shotRegion(.goalPageNext) }
                SplitBoardView(
                    draft: page.draft, rows: rows, schedule: page.schedule, selected: browser.pagePart,
                    folded: browser.pageFolded, states: page.states, now: page.now, live: true
                ) { part, _ in
                    PartFoldCard(part: part, draft: page.draft, live: page.states[part.id] ?? .planned)
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .zIndex(2)
                HStack(spacing: 24) {
                    stat("square.3.layers.3d", "\(page.done) / \(page.total)", "parts done")
                    stat("clock", "~" + SplitSchedule.text(page.hoursLeft) + " left", "by the plan's estimates")
                    if let spent = page.spent {
                        stat("cylinder.split.1x2", AgentUsage.dollars(spent), "spent, as the agents reported")
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    private func stat(_ symbol: String, _ value: String, _ help: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.fg3)
            Text(value).font(Theme.ui(18, weight: .bold)).foregroundStyle(Theme.fg)
        }
        .help(help)
    }
}

/// planned ✓ — panel ✓ — split ✓ — ④ building · 5/15 — reviewed — walked — done.
private struct JourneyBar: View {
    let journey: GoalJourney

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(journey.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle().fill(journey.steps[index - 1].state == .done ? Theme.done.opacity(0.5) : Theme.line)
                        .frame(height: 1.5).frame(minWidth: 16)
                }
                HStack(spacing: 7) {
                    ZStack {
                        switch step.state {
                        case .done:
                            Circle().fill(Theme.done.opacity(0.28))
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.done)
                        case .now:
                            Circle().strokeBorder(Theme.block, lineWidth: 1.5)
                            Text("\(index + 1)").font(Theme.mono(10, weight: .semibold)).foregroundStyle(Theme.fg)
                        case .next:
                            Circle().strokeBorder(Theme.keyCapBorder, lineWidth: 1)
                            Text("\(index + 1)").font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(step.title).font(Theme.ui(13, weight: step.state == .now ? .semibold : .regular))
                        .foregroundStyle(step.state == .next ? Theme.fg3 : Theme.fg).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// The one thing that needs you, in amber: what, why, and its options.
private struct NextStepBanner: View {
    @Environment(AppModel.self) private var model
    let next: GoalNextStep

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.block.opacity(0.16))
                Image(systemName: "questionmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.block)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(next.title).font(Theme.ui(14.5, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(next.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let typing = model.goals.wizard.typing, typing.kind == .nextStep, !ShotMode.active {
                TextField("your answer", text: Binding(
                    get: { model.goals.wizard.typing?.text ?? "" }, set: { model.goals.wizard.typing?.text = $0 }
                ))
                .textFieldStyle(.plain).frame(width: 220)
                .onSubmit { model.submitWizardTyping() }
            }
            ForEach(Array(next.options.prefix(3).enumerated()), id: \.offset) { index, option in
                Text("\(index + 1)  \(option)").font(Theme.ui(13)).foregroundStyle(Theme.fg)
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
                    .clickRuns(CommandInvocation(name: "page.pick", arguments: ["\(index + 1)"]))
            }
            Text("\(model.keyText(for: "page.answer", in: "goals"))  answer").font(Theme.ui(13))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
                .clickRuns(CommandInvocation(name: "page.answer"))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.block.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.block.opacity(0.55)))
    }
}
