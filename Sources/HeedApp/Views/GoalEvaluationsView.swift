import HeedCore
import SwiftUI

/// Evaluations (`goal.evaluations`, X in Goals): stranger walks of the goal. On the left the evaluator of the lens
/// picked, its score and its walk (each step, how it went and how long it took); in the middle its friction log; on
/// the right the lens picker, the same walk judged for something else.
struct GoalEvaluationsPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        let evaluation = goals.selectedEvaluation
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let evaluation {
                    EvaluatorCard(evaluation: evaluation)
                } else {
                    Panel(title: "No evaluations", note: "") { Quiet("This goal has no quality record yet.") }
                }
            }
            .frame(width: 360)
            .shotRegion(.goalEvaluator)
            FrictionLog(goal: goal, evaluation: evaluation)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .shotRegion(.goalFriction)
            LensPicker(goal: goal).frame(width: 270).shotRegion(.goalLenses)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shotRegion(.goalEvaluations)
    }
}

// MARK: The evaluator

private struct EvaluatorCard: View {
    @Environment(AppModel.self) private var model
    let evaluation: Evaluation

    var body: some View {
        let lens = evaluation.lens
        let evaluator = evaluation.evaluator
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lens.evaluatorTitle).font(Theme.ui(17, weight: .semibold))
                    Text(lens.title + (evaluation.bar.map { " · bar \(GoalBarTable.number($0))" } ?? ""))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                Spacer(minLength: 8)
                ScoreRing(score: evaluation.score?.value, size: 58)
            }
            Text(lens.persona).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if !evaluation.required {
                Quiet("The goal's profile does not need this lens: it walks only when you ask.")
            }
            if evaluator?.running == true {
                Text("Walking now, in a fresh clone.").font(Theme.ui(12)).foregroundStyle(Theme.block)
            }
            if let failure = evaluator?.lastReview?.failure {
                Text("The last walk left nothing: \(failure).").font(Theme.ui(12)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let walk = evaluation.walk {
                WalkSteps(walk: walk)
                if !walk.summary.isEmpty {
                    Text(walk.summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let draft = WalkDrafter.current(evaluator?.draft, version: draftVersion) {
                SectionHeader(title: "The walk, not taken yet")
                ForEach(Array(draft.steps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, title: step, outcome: nil, seconds: nil)
                }
            } else {
                Quiet(evaluator == nil ? "No evaluator for this lens yet: heed spawns one when the goal's profile "
                    + "needs it, or walk it now." : "Not walked yet.")
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(lens.tags.enumerated()), id: \.offset) { index, tag in
                    WalkTag(text: tag, lit: index == 0)
                }
            }
            if let score = evaluation.score {
                Text(score.basis).font(Theme.mono(11)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let evaluator, evaluator.history.count > 1 {
                Text("Each walk: " + evaluator.history.suffix(5).map(GoalBarTable.number).joined(separator: " → "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint(
                    "eval.rewalk", scope: "goalevals", label: evaluator?.running == true ? "walking" : "walk again"
                )
                KeyHint(
                    "eval.lens", ["1"], key: model.keyText(for: "eval.lens 1", in: "goalevals"), label: "next lens"
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var draftVersion: Int { evaluation.evaluator?.draft?.goalVersion ?? 0 }
}

/// THE WALK · 9 min 11 s, then each step.
private struct WalkSteps: View {
    let walk: EvaluationWalk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THE WALK · \(EvaluationWalk.span(walk.seconds).uppercased())")
                .font(Theme.mono(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
                .padding(.bottom, 6)
            ForEach(Array(walk.steps.enumerated()), id: \.offset) { index, step in
                StepRow(number: index + 1, title: step.title, outcome: step.outcome, seconds: step.seconds)
                    .help(step.note ?? "")
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let outcome: WalkStep.Outcome?
    let seconds: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(Theme.mono(12)).foregroundStyle(Theme.fg3).frame(width: 16, alignment: .leading)
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.fg).lineLimit(1)
            Spacer(minLength: 8)
            if let outcome {
                Text(outcome.rawValue).font(Theme.mono(11.5)).foregroundStyle(tint(outcome))
                Text(EvaluationWalk.clock(seconds)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func tint(_ outcome: WalkStep.Outcome) -> Color {
        switch outcome {
        case .ok: Theme.done
        case .confusing: Theme.block
        case .stalled, .failed: Theme.err
        }
    }
}

private struct WalkTag: View {
    let text: String
    let lit: Bool

    var body: some View {
        Text(text).font(Theme.mono(11, weight: lit ? .semibold : .regular))
            .foregroundStyle(lit ? Theme.block : Theme.fg2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(lit ? Theme.block.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lit ? Theme.block.opacity(0.6) : Theme.line))
    }
}

// MARK: The friction log

private struct FrictionLog: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let evaluation: Evaluation?

    var body: some View {
        let goals = model.goals
        let rows = goals.friction
        let open = rows.filter { $0.state == .open }
        let high = open.count { $0.friction.severity == .high }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Friction log").font(Theme.ui(15, weight: .semibold))
                Spacer()
                Text(rows.isEmpty ? "" : "\(open.count) open · \(high) high").font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
            }
            if rows.isEmpty {
                Quiet(evaluation?.walk == nil ? "Nothing yet: the stranger has not walked this lens."
                    : "No friction. The walk went smoothly.")
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    let isCursor = goals.focus == .friction && index == min(goals.frictionCursor, rows.count - 1)
                    FrictionRow(row: row)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .background(isCursor ? Theme.bg3 : .clear)
                        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
                        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                        .hint(goals.focus == .friction ? model.hintLabel(for: .row(.goals, index)) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickFriction(index) }
                        .rightClickMenu {
                            guard model.clicksReachLists else { return false }
                            model.clickFriction(index)
                            return true
                        } _: { model.frictionMenu(index) }
                }
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("eval.fix", scope: "goalevals", label: "start session to fix", color: Theme.fg2)
                KeyHint("eval.accept", scope: "goalevals", label: "accept", color: Theme.fg2)
                KeyHint("eval.rewalk", scope: "goalevals", label: "re-walk after fix", color: Theme.fg2)
                KeyHint("goal.focus", scope: "goalevals", label: "to the log", color: Theme.fg3)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

private struct FrictionRow: View {
    let row: Evaluation.Row

    var body: some View {
        let friction = row.friction
        let open = row.state == .open
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SeverityTag(severity: friction.severity, quiet: !open)
            VStack(alignment: .leading, spacing: 4) {
                if !friction.place.isEmpty {
                    Text(friction.place).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Text(friction.finding).font(Theme.ui(13)).foregroundStyle(open ? Theme.fg : Theme.fg2)
                    .strikethrough(row.state == .fixed, color: Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = friction.suggestion {
                    Text("→ " + suggestion).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !open {
                Text(row.state == .fixed ? "fixed" : "accepted").font(Theme.mono(10.5)).foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                    .fixedSize()
            }
        }
    }
}

// MARK: The lens picker

private struct LensPicker: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Same walk, different lens").font(Theme.ui(15, weight: .semibold))
                Text("Pick what is being judged.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
            ForEach(goals.evaluations) { evaluation in
                let picked = evaluation.lens == goals.evalLens
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(picked ? Theme.block : Theme.line).frame(width: 9, height: 9).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evaluation.lens.title).font(Theme.ui(13.5, weight: .semibold))
                            .foregroundStyle(picked ? Theme.fg : evaluation.required ? Theme.fg2 : Theme.fg3)
                        Text(evaluation.required ? evaluation.lens.checks : evaluation.lens.checks + " · not required")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    }
                    Spacer(minLength: 4)
                    if let score = evaluation.score {
                        Text(GoalBarTable.number(score.value)).font(Theme.mono(12))
                            .foregroundStyle((evaluation.bar ?? 0) <= score.value ? Theme.done : Theme.fg2)
                    } else if evaluation.evaluator?.running == true {
                        Text("walking").font(Theme.mono(11)).foregroundStyle(Theme.block)
                    }
                }
                .contentShape(Rectangle())
                .clickable()
                .onTapGesture { model.clickLens(evaluation.lens) }
                .rightClickMenu {
                    guard model.clicksReachLists else { return false }
                    model.clickLens(evaluation.lens)
                    return true
                } _: { model.lensMenu(evaluation.lens) }
            }
            Text("Each lens is a stranger with a checklist of its own, in a fresh clone with the README only. The "
                + "score drops with open friction and rises when a re-walk goes faster.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            HStack(spacing: 14) {
                KeyHint(
                    "eval.lens", ["-1"], key: model.keyText(for: "eval.lens -1", in: "goalevals"), label: "lens before"
                )
                KeyHint("eval.lens", ["1"], key: model.keyText(for: "eval.lens 1", in: "goalevals"), label: "next")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}
