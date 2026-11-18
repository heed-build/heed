import HeedCore
import SwiftUI

/// A goal's tint where Sessions points into Goals: the sizing card and the growing session's line.
private let goalTint = Color.adaptive(0xC9E27A)

// MARK: Start work's sizing hint

/// One quiet line under the prompt when it is bigger than one session: the rough size, Make it a goal (⌘G) and ✕ for
/// not now. It never takes the place of the fields and starts nothing: ⌘↩ starts what the fields show.
struct SizeHint: View {
    @Environment(AppModel.self) private var model
    let sizing: TaskSizing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .medium)).foregroundStyle(goalTint)
            Text("Looks bigger than one session").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            if let facts = sizing.facts {
                Text("~\(facts.parts) parts · \(facts.time.value) \(facts.time.unit)")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("Make it a goal").foregroundStyle(goalTint)
                KeyCap(text: "⌘G")
            }
            .font(Theme.ui(12.5))
            .contentShape(Rectangle())
            .tap { model.clickStartWorkKey(KeyStroke("g", .command)) }
            Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.fg3)
                .padding(4)
                .contentShape(Rectangle())
                .tap { model.clickStartWork { $0.setSizingAside() } }
                .help("Not now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(goalTint.opacity(0.07)))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .shotRegion(.sizeCard)
    }
}

// MARK: A session growing into a goal

/// The quiet line at the foot of a growing session's panes (design g10-promote): why it looks like a goal, Make it a
/// goal (`gP`), and ✕ for not now (the line goes for this session). Below the helper line when both show.
struct GrowthLine: View {
    @Environment(AppModel.self) private var model
    let growth: GoalGrowth

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .medium)).foregroundStyle(goalTint)
            Text("Growing into a goal").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.fg)
                .fixedSize()
            HStack(spacing: 12) {
                if growth.pulls >= 2 { sign("arrow.triangle.branch", "\(growth.pulls) PRs") }
                if growth.repos >= 2 { sign("folder", growth.repos == 2 ? "2nd repo" : "\(growth.repos) repos") }
                if !growth.found.isEmpty { sign("questionmark", "found work it didn't start") }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("Make it a goal").foregroundStyle(Theme.fg)
                KeyCap(text: model.keyText(for: "goal.promote", asIn: "sessions"))
            }
            .font(Theme.ui(11.5))
            .clickRuns(CommandInvocation(name: "goal.promote"))
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.fg3)
                .frame(width: 18, height: 18)
                .clickRuns(CommandInvocation(name: "goal.promote.dismiss"))
                .help("Not now: the line goes for this session")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(goalTint.opacity(0.06))
        .overlay(alignment: .top) { goalTint.opacity(0.35).frame(height: 1) }
        .shotRegion(.growthLine)
    }

    private func sign(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5))
            Text(text)
        }
        .font(Theme.mono(11)).foregroundStyle(Theme.fg2).fixedSize()
    }
}

/// Make it a goal's popover over the line: the goal statement, the merged PRs as done parts, what was found, and that
/// the session stays as part 1. ↩ or ⌘↩ asks the agent for a handoff and opens the plan step (s, while it waits, starts
/// without the handoff), x is not now, ⎋ closes.
struct PromotionPopover: View {
    @Environment(AppModel.self) private var model
    let promotion: GoalPromotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make it a goal").font(Theme.ui(14, weight: .semibold))
            ForEach(Array(promotion.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    glyph(line.glyph).frame(width: 14)
                    Text(line.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ask = model.promotionHandoff, ask.isOpen, ask.session == promotion.session {
                waiting(ask)
                HStack(spacing: 8) {
                    button("Start without it", primary: true, command: "goal.promote.skip")
                    button("Cancel", command: "goal.promote")
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    button("Open the plan step", primary: true, command: "goal.promote.go")
                    button("Not now", command: "goal.promote.dismiss")
                    button("Cancel", command: "goal.promote")
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 18)
        .shotRegion(.promotion)
    }

    /// While the agent is asked for its handoff: the ask, the agent's live state, and what is holding it up.
    private func waiting(_ ask: HandoffAsk) -> some View {
        let state = model.sessions.first { $0.id == ask.session }?.state.state ?? .idle
        return HStack(alignment: .top, spacing: 12) {
            StateGlyph(state: state, size: 12).frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(ask.headline).font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.fg)
                Text("\(ask.agent) is \(state.rawValue) · \(ask.detail)")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("gives up after \(PilotDuration.text(ask.timeout)) and starts from the session's prompt")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3.opacity(0.6)))
    }

    @ViewBuilder private func glyph(_ glyph: GoalPromotion.Glyph) -> some View {
        switch glyph {
        case .goal: Image(systemName: "star").foregroundStyle(goalTint)
        case .done: Image(systemName: "checkmark").foregroundStyle(Theme.done)
        case .found: Image(systemName: "questionmark").foregroundStyle(Theme.block)
        case .stays: Image(systemName: "eye").foregroundStyle(Theme.fg3)
        }
    }

    /// Its key as the keymap has it in the popover's scope (↩, x, ⎋ by default).
    private func button(_ label: String, primary: Bool = false, command: String) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(primary ? .semibold : .regular)
            KeyCap(text: model.keyText(for: command, in: "sessionspromote"))
        }
        .font(Theme.ui(12.5))
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(primary ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(primary ? .clear : Theme.line))
        .clickRuns(CommandInvocation(name: command))
    }
}
