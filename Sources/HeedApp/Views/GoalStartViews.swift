import HeedCore
import SwiftUI

/// A goal's tint where Sessions points into Goals: the sizing card and the growing session's line.
private let goalTint = Color(hex: 0xC9E27A)

// MARK: Start work's sizing card

/// Start work's card when the prompt is bigger than one session (design g01-start): the rough size in icons, then
/// Make it a goal (⌘↩, suggested), Just a session (⌥↩) and It's a question (⌃↩). The fields wait behind it.
struct SizeCard: View {
    @Environment(AppModel.self) private var model
    let form: StartWorkForm
    let sizing: TaskSizing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                badge("square.stack.3d.up", goalTint)
                Text("Bigger than one session").font(Theme.ui(14, weight: .semibold))
                Spacer(minLength: 8)
                if let call = sizing.callLabel {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0x5CC8E0)).frame(width: 6, height: 6)
                        Text(call)
                    }
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            if let facts = sizing.facts { stats(facts) }
            VStack(spacing: 6) {
                option(
                    "star", goalTint, "Make it a goal",
                    "talk the plan through, a panel weighs in, split across your agents", button: "Goal", key: "⌘↩",
                    suggested: true, stroke: KeyStroke("CR", .command)
                )
                option(
                    "play", Theme.busy, "Just a session", "one agent, one worktree; make it a goal later",
                    button: "Session", key: "⌥↩", stroke: KeyStroke("CR", .option)
                )
                option(
                    "questionmark", Theme.ask, "It's a question",
                    "a chat, no worktree; promote it when it becomes work",
                    button: "Chat", key: "⌃↩", stroke: KeyStroke("CR", .control)
                )
            }
            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 10))
                Text("small tasks skip this · Settings › Start work")
            }
            .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            .contentShape(Rectangle())
            .onTapGesture { model.clickHint(CommandInvocation(name: "settings.open")) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .shotRegion(.sizeCard)
    }

    private func badge(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.12)))
    }

    /// The rough size, an icon each: parts, repos, agents at once, one agent's time.
    private func stats(_ facts: TaskSizeFacts) -> some View {
        HStack(spacing: 22) {
            stat("square.stack.3d.up", "~\(facts.parts)", "parts")
            stat("folder", "\(facts.repos)", facts.repos == 1 ? "repo" : "repos")
            stat("person.2", "\(facts.atOnce)", "at once")
            let time = facts.time
            stat("clock", "\(time.value) \(time.unit)", "for one agent")
        }
        .padding(.horizontal, 4)
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.fg3)
            Text(value).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .fixedSize()
    }

    private func option(
        _ symbol: String, _ tint: Color, _ title: String, _ detail: String, button: String, key: String,
        suggested: Bool = false, stroke: KeyStroke
    ) -> some View {
        HStack(spacing: 14) {
            badge(symbol, tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(button).fontWeight(suggested ? .semibold : .regular)
                KeyCap(text: key)
            }
            .font(Theme.ui(12.5))
            .foregroundStyle(suggested ? Theme.ink : Theme.fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(suggested ? Theme.inverse : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(suggested ? .clear : Theme.line))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 5).fill(suggested ? goalTint.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(suggested ? goalTint.opacity(0.55) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.clickStartWorkKey(stroke) }
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
                KeyCap(text: model.keyText(for: "goal.promote", in: "sessions"))
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
/// the session stays as part 1. ↩ or ⌘↩ opens the plan step, x is not now, ⎋ closes.
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
            HStack(spacing: 8) {
                button("Open the plan step", key: "⌘↩", primary: true, command: "goal.promote.go")
                button("Not now", key: "x", command: "goal.promote.dismiss")
                button("Cancel", key: "⎋", command: "goal.promote")
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 18)
        .shotRegion(.promotion)
    }

    @ViewBuilder private func glyph(_ glyph: GoalPromotion.Glyph) -> some View {
        switch glyph {
        case .goal: Image(systemName: "star").foregroundStyle(goalTint)
        case .done: Image(systemName: "checkmark").foregroundStyle(Theme.done)
        case .found: Image(systemName: "questionmark").foregroundStyle(Theme.block)
        case .stays: Image(systemName: "eye").foregroundStyle(Theme.fg3)
        }
    }

    private func button(_ label: String, key: String, primary: Bool = false, command: String) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(primary ? .semibold : .regular)
            KeyCap(text: key)
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
