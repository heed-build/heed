import HeedCore
import SwiftUI

/// The goal's TL;DR (`goal.tldr`), over the wizard or the goal's page: the steps with a summary each, what is settled,
/// what is still open (numbered, each with what to do about it) and, once Split knows, where it is going.
struct WizardTLDRView: View {
    @Environment(AppModel.self) private var model
    let goal: String

    var body: some View {
        let tldr = model.shownTLDR(goal)
        let inputs = model.tldrInputs(goal)
        let wizard = model.goals.wizard.wizard(of: goal)
        let writing = model.goals.wizard.writing.contains(goal)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "TL;DR · " + (wizard.map { $0.finished ? "goal" : "new goal" } ?? "goal"))
                    Text(inputs.title).font(Theme.ui(20, weight: .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 8) {
                    if writing { ProgressView().controlSize(.small) }
                    Text(byline(tldr, writing: writing)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    KeyCap(text: "⎋")
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            Theme.line.frame(height: 1)
            Stepper(steps: tldr.steps, wizard: wizard)
                .padding(.horizontal, 28).padding(.vertical, 22)
            Theme.line.frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                column(title: "Settled", icon: "checkmark", tint: Theme.done) {
                    ForEach(tldr.settled, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Rectangle().fill(Theme.fg3).frame(width: 4, height: 4).offset(y: -3)
                            Text(LocalizedStringKey(line)).font(Theme.ui(14)).foregroundStyle(Theme.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Theme.line.frame(width: 1)
                column(title: "Open", icon: "questionmark", tint: Theme.block) {
                    if tldr.open.isEmpty {
                        Text("Nothing open.").font(Theme.ui(14)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(Array(tldr.open.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").font(Theme.mono(11, weight: .bold))
                                .foregroundStyle(point.action == nil ? Theme.fg2 : Theme.ink)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(point.action == nil ? Theme.chip : Theme.block))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.text).font(Theme.ui(14)).foregroundStyle(Theme.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let action = point.action {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play").font(.system(size: 8))
                                        Text(action.label).font(Theme.ui(13, weight: .semibold))
                                    }
                                    .foregroundStyle(Theme.block)
                                    .clickRuns(CommandInvocation(
                                        name: action.command.name, arguments: action.command.arguments
                                    ))
                                }
                            }
                        }
                    }
                }
                if let going = tldr.going {
                    Theme.line.frame(width: 1)
                    column(title: "Where it's going", icon: "arrow.left.arrow.right", tint: Theme.busy) {
                        GoingView(going: going)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Theme.line.frame(height: 1)
            HStack(spacing: 12) {
                KeyHint("goal.tldr", scope: "tldr", label: "Back", color: Theme.fg, font: Theme.ui(13.5))
                if let action = tldr.open.compactMap(\.action).first {
                    KeyHint(
                        "tldr.act",
                        scope: "tldr",
                        label: action.label.prefix(1).uppercased()
                            + action.label.dropFirst(),
                        color: Theme.fg,
                        font: Theme.ui(13.5)
                    )
                }
                KeyHint("tldr.copy", scope: "tldr", label: "Copy as markdown", color: Theme.fg, font: Theme.ui(13.5))
                Spacer()
                Text("opens from any step with \(model.keyText(for: "goal.tldr", in: "wizardplan")) · and from the "
                    + "goal's page")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(maxWidth: 1080)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.keyCapBorder))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .shotRegion(.tldr)
    }

    private func byline(_ tldr: WizardTLDR, writing: Bool) -> String {
        if writing { return "writing…" }
        let who = tldr.writtenBy == "heed" ? "heed's facts" : "written by \(tldr.writtenBy)"
        let seconds = tldr.seconds.map { " · \(Int($0.rounded())) s" } ?? ""
        let age = Clock.now.timeIntervalSince(tldr.at) < 90 ? "just now" : AgentUsage.clock(tldr.at)
        return "\(who)\(seconds) · \(age)"
    }

    private func column(
        title: String, icon: String, tint: Color, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                Text(title).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.fg)
            }
            content()
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The six steps in a row, each with its summary under it.
private struct Stepper: View {
    let steps: [WizardStepSummary]
    let wizard: GoalWizard?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, summary in
                let state = wizard?.state(of: summary.step) ?? .next
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 0) {
                        StepDot(step: summary.step, state: state)
                        if index < steps.count - 1 {
                            Rectangle().fill(state == .done ? Theme.done.opacity(0.5) : Theme.line).frame(height: 2)
                                .padding(.horizontal, 10)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.step.title).font(Theme.ui(14, weight: .semibold))
                            .foregroundStyle(state == .now ? Theme.block : Theme.fg).lineLimit(1)
                        Text(summary.headline).font(Theme.ui(13)).foregroundStyle(Theme.fg2).lineLimit(1)
                        if !summary.detail.isEmpty {
                            Text(summary.detail).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 34)
                    .padding(.trailing, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Where it's going: time, money, agents, the end, and the longest chain by agent.
private struct GoingView: View {
    let going: WizardGoing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                if let hours = going.hours { stat("clock", "~\(Int(hours.rounded())) h") }
                if let dollars = going.dollars { stat("cylinder", AgentUsage.dollars(dollars)) }
                if let agents = going.agents { stat("person.2", "\(agents) agents") }
                if let ends = going.endsAt { stat("star", AgentUsage.clock(ends)) }
            }
            if !going.chain.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(going.chain.enumerated()), id: \.offset) { _, agent in
                        Rectangle().fill(OrgPalette.automatic(for: agent).swatch).frame(height: 8)
                    }
                }
                Text("the longest chain, by agent").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.fg3)
            Text(text).font(Theme.ui(17, weight: .semibold)).foregroundStyle(Theme.fg)
        }
    }
}
