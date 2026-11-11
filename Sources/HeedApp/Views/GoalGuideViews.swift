import HeedCore
import SwiftUI

// MARK: The pane bar

/// Above every pane of a goal: where you are (`Goals › title › pane`) with how far the goal is, and a tab per pane
/// with its key and what waits there. A click on a tab opens it as its key does; the keys keep working.
struct GoalPaneBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goals = model.goals
        let goal = goals.selected
        let swarms = goal.map { goals.snapshot.swarms(of: $0.id) } ?? []
        let needsYou = goals.board.map { model.waitingOnYou($0).count } ?? 0
        let tabs = GoalPaneTabs.tabs(
            swarm: !swarms.isEmpty, approved: swarms.first?.approved != nil,
            counts: goals.tabCounts(needsYou: needsYou)
        )
        let pane = goals.pane.rawValue
        let parts = GoalPaneTabs.crumb(goal: goal?.title, pane: pane)
        PaneBar(
            // The goal's name goes back to its overview.
            crumb: parts.enumerated().map { index, part in
                PaneCrumb(
                    part,
                    runs: index == 1 && pane != "unassigned" ? CommandInvocation(name: "goal.overview") : nil
                )
            },
            tabs: tabs.map { tab in
                PaneBarTab(
                    id: tab.pane, title: tab.title, command: tab.command, count: tab.count,
                    showsKey: tab.command != "goal.overview",
                    // Unassigned is Goals', not the goal's.
                    gapBefore: tab.pane == "unassigned"
                )
            },
            active: pane, scope: "goals", tabsRegion: .goalPaneTabs,
            select: { selected in
                if let tab = tabs.first(where: { $0.pane == selected.id }) { model.showGoalPane(tab) }
            },
            trailing: {
                if let goal, goals.pane != .unassigned { GoalProgressLine(goal: goal) }
            }
        )
    }
}

/// How far the goal is, in a line: its ring and `1/3 criteria · 4/11 items · 2/4 bars`; the ring's basis on hover.
struct GoalProgressLine: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let progress = model.goals.progress(of: goal)
        HStack(spacing: 8) {
            ScoreRing(score: goal.score, size: 24)
            Text(progress.line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
        }
        .help(goal.score == nil ? "No score yet: reviewers score a goal once they have looked at it"
            : progress.confidence?.basis ?? "")
    }
}

// MARK: The next-steps card

/// A goal's next step, big, with why it matters and its key; beside it every step, ticked off by what is true of the
/// goal. Hidden with `goal.guide`; it comes back when a step it ticked off goes back.
struct GoalGuideCard: View {
    @Environment(AppModel.self) private var model
    let guide: GoalGuide

    var body: some View {
        if let next = guide.next {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SectionHeader(title: "Next step", tint: Theme.block)
                        Text("\(guide.done) of \(guide.steps.count) done").font(Theme.mono(11))
                            .foregroundStyle(Theme.fg3)
                    }
                    Text(next.step.title).font(Theme.ui(17, weight: .semibold))
                    Text(next.step.why).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    if case let .waiting(what, _) = next.state {
                        Text(what).font(Theme.ui(12.5)).foregroundStyle(Theme.block)
                    }
                    HStack(spacing: 16) {
                        if case let .waiting(_, command) = next.state {
                            KeyHint(
                                command, key: model.goalKeyText(command),
                                label: command == next.step.command ? next.step.action
                                    : command == "goal.source.accept" ? "add the source" : "answer them",
                                color: Theme.fg, font: Theme.ui(13)
                            )
                        } else {
                            KeyHint(
                                next.step.command, key: model.goalKeyText(next.step.command),
                                label: next.step.action, color: Theme.fg, font: Theme.ui(13)
                            )
                        }
                        if let other = next.step.alternative {
                            KeyHint(
                                other.command, key: model.goalKeyText(other.command), label: other.action,
                                color: Theme.fg2
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        SectionHeader(title: "First steps")
                        Spacer()
                        Text("hide").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                            .clickRuns(CommandInvocation(name: "goal.guide"))
                    }
                    ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                        GuideStepRow(number: index + 1, step: step, next: step.step == next.step)
                    }
                }
                .frame(width: 330)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.45)))
        }
    }
}

private struct GuideStepRow: View {
    @Environment(AppModel.self) private var model
    let number: Int
    let step: GoalGuide.Step
    let next: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if step.state.isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.done)
                } else {
                    Text("\(number)").font(Theme.mono(10.5, weight: .semibold))
                        .foregroundStyle(next ? Theme.ink : Theme.fg3)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(next ? Theme.block : .clear))
                        .overlay(Circle().strokeBorder(next ? .clear : Theme.line))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(step.step.title).font(Theme.ui(12.5, weight: next ? .semibold : .regular))
                        .foregroundStyle(step.state.isDone ? Theme.fg2 : Theme.fg)
                    if step.step.optional { Text("optional").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
                }
                if let line = detail {
                    Text(line).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !step.state.isDone {
                KeyHint(step.command, key: model.goalKeyText(step.command), label: "")
            }
        }
        .help(step.step.why)
    }

    private var detail: String? {
        switch step.state {
        case let .done(evidence): evidence
        case let .waiting(what, _): what
        case .todo: nil
        }
    }
}

// MARK: What is left

/// The goal's progress in full: the ring and what it is made of, each done-when criterion (met ones with their
/// evidence), each bar against its score, and the items done. What is not met yet comes first.
struct GoalLeftPanel: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let progress = model.goals.progress(of: goal)
        let left = progress.left
        Panel(title: "What is left", note: left.isEmpty ? "nothing" : "\(left.count)") {
            HStack(alignment: .top, spacing: 12) {
                ScoreRing(score: goal.score, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                    Text(goal.score == nil ? "No score yet: it counts once reviewers have looked or a criterion is met."
                        : progress.confidence?.basis ?? "")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if progress.criteria.isEmpty {
                Text("Nothing says when it is done yet: done-when lines in GOAL.md.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.block)
                    .clickRuns(CommandInvocation(name: "goal.edit"))
            }
            ForEach(Array((progress.unmet + progress.criteria.filter(\.met)).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.met ? "checkmark.square" : "square")
                        .foregroundStyle(line.met ? Theme.done : Theme.fg3)
                    Text(line.text).font(Theme.ui(12.5)).foregroundStyle(line.met ? Theme.fg2 : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let evidence = line.evidence {
                        Text(evidence).font(Theme.mono(10.5)).foregroundStyle(Theme.block).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.block.opacity(0.12)))
                    }
                }
            }
            if !progress.lenses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(progress.short + progress.lenses.filter(\.met), id: \.lens) { lens in
                        BarRow(lens: lens)
                    }
                }
                .padding(.top, 2)
                .clickRuns(CommandInvocation(name: "goal.reviewers"))
            }
            if progress.itemsTotal > 0 {
                HStack(spacing: 8) {
                    Text("items").font(Theme.ui(12)).foregroundStyle(Theme.fg2).frame(width: 96, alignment: .leading)
                    Meter(fraction: Double(progress.itemsDone) / Double(progress.itemsTotal), tint: Theme.busy)
                    Text("\(progress.itemsDone)/\(progress.itemsTotal) done").font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2).frame(width: 70, alignment: .trailing)
                }
                .clickRuns(CommandInvocation(name: "goal.board"))
            }
        }
    }
}

/// A lens against its bar: a meter toward the bar, red while under it.
private struct BarRow: View {
    let lens: GoalScore.Lens

    var body: some View {
        HStack(spacing: 8) {
            Text(lens.lens.title).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
                .frame(width: 96, alignment: .leading)
            Meter(fraction: lens.progress, tint: lens.met ? Theme.done : lens.score == nil ? Theme.fg3 : Theme.err)
            Text("\(lens.score.map(GoalBarTable.number) ?? "–") / \(GoalBarTable.number(lens.bar))")
                .font(Theme.mono(11)).foregroundStyle(lens.met ? Theme.done : Theme.fg2)
                .frame(width: 70, alignment: .trailing)
        }
    }
}

private struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}
