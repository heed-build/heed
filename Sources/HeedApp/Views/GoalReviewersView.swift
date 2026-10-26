import HeedCore
import SwiftUI

/// Reviewers (`goal.reviewers`, R in Goals): the goal's reviewers with their scores and trends on the left, the one
/// under the cursor with its objections and why its score is what it is in the middle, and on the right the panel
/// that spawns another and the goal's quality bars, each lens against its bar.
struct GoalReviewersPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        let quality = goals.qualities[goal.id] ?? .empty
        HStack(alignment: .top, spacing: 16) {
            ReviewerList(quality: quality).frame(width: 300).shotRegion(.goalReviewerList)
            Group {
                if let reviewer = goals.selectedReviewer {
                    ReviewerDetail(goal: goal, reviewer: reviewer, quality: quality)
                } else {
                    Panel(title: "No reviewers yet", note: "") {
                        Quieter("heed spawns one per lens the goal's profile requires once a model has read its "
                            + "GOAL.md. Spawn one yourself on the right.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .shotRegion(.goalReviewerDetail)
            VStack(alignment: .leading, spacing: 16) {
                SpawnPanel(goal: goal).shotRegion(.goalSpawn)
                QualityBars(quality: quality).shotRegion(.goalBars)
            }
            .frame(width: 330)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shotRegion(.goalReviewers)
    }
}

// MARK: The list

private struct ReviewerList: View {
    @Environment(AppModel.self) private var model
    let quality: GoalQuality

    var body: some View {
        let goals = model.goals
        let reviewers = goals.reviewers
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reviewers · \(reviewers.count)").font(Theme.ui(13, weight: .semibold))
                Spacer()
                Text("score = how happy they are").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            ListScroll {
                VStack(spacing: 2) {
                    ForEach(Array(reviewers.enumerated()), id: \.element.id) { index, reviewer in
                        let isCursor = index == goals.reviewerCursor
                        ReviewerRow(reviewer: reviewer, required: required(reviewer), large: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isCursor ? (goals.focus == .reviewers ? Theme.bg3 : Theme.chip) : .clear)
                            )
                            .overlay(alignment: .leading) {
                                if isCursor, goals.focus == .reviewers { Theme.block.frame(width: 2) }
                            }
                            .hint(goals.focus == .reviewers ? model.hintLabel(for: .row(.goals, index)) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickReviewer(index) }
                            .rightClickMenu {
                                guard model.clicksReachLists else { return false }
                                model.clickReviewer(index)
                                return true
                            } _: { model.reviewerMenu(index) }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func required(_ reviewer: ReviewerState) -> Bool {
        guard let lens = reviewer.config.kind.lens else { return true }
        return quality.lenses.contains { $0.lens == lens }
    }
}

/// A reviewer: its ring, its name, what is open and when it last looked, and which way its score went.
struct ReviewerRow: View {
    let reviewer: ReviewerState
    var required = true
    var large = false

    var body: some View {
        HStack(spacing: 12) {
            ScoreRing(score: reviewer.score?.value, size: large ? 40 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(reviewer.config.title).font(Theme.ui(large ? 13.5 : 12.5, weight: .semibold))
                    .foregroundStyle(required ? Theme.fg : Theme.fg2).lineLimit(1)
                Text(subline).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer(minLength: 4)
            TrendMark(trend: reviewer.trend, scored: reviewer.score != nil)
        }
    }

    private var subline: String {
        var parts: [String] = []
        if reviewer.score != nil || !reviewer.objections.isEmpty { parts.append("\(reviewer.open.count) open") }
        if reviewer.running {
            parts.append("running now")
        } else if let failure = reviewer.lastReview?.failure {
            parts.append(failure)
        } else if let at = reviewer.lastReviewAt {
            parts.append("looked " + Clock.relative(at))
        } else {
            parts.append(reviewer.config.walk != nil ? "not walked yet" : "not run yet")
        }
        if !required { parts.append("lens not required") }
        return parts.joined(separator: " · ")
    }
}

/// ↗ +0.8, ↘ −0.4, → when it did not move.
private struct TrendMark: View {
    let trend: Double?
    let scored: Bool

    var body: some View {
        if let trend {
            let text = trend > 0 ? "↗ +\(GoalBarTable.number(trend))"
                : trend < 0 ? "↘ −\(GoalBarTable.number(-trend))" : "→"
            Text(text).font(Theme.mono(11.5))
                .foregroundStyle(trend > 0 ? Theme.done : trend < 0 ? Theme.block : Theme.fg3)
                .help("Since the review before")
        } else if scored {
            Text("→").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
        }
    }
}

// MARK: The detail

private struct ReviewerDetail: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let reviewer: ReviewerState
    let quality: GoalQuality

    var body: some View {
        let goals = model.goals
        let objections = reviewer.ordered
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(header).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    Text(reviewer.config.title).font(Theme.ui(17, weight: .semibold))
                }
                Spacer(minLength: 8)
                ScoreRing(score: reviewer.score?.value, size: 58)
            }
            if !reviewer.summary.isEmpty {
                Text(reviewer.summary).font(Theme.ui(13)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = reviewer.lastReview?.failure {
                Text("The last run wrote no review: \(failure).").font(Theme.ui(12)).foregroundStyle(Theme.err)
            }
            SectionHeader(title: "Objections")
            if objections.isEmpty {
                Quieter(reviewer.score == nil ? "Nothing yet: it has not reviewed." : "None. It is happy.")
            }
            VStack(spacing: 0) {
                ForEach(Array(objections.enumerated()), id: \.element.id) { index, objection in
                    let isCursor = goals.focus == .objections && index == min(
                        goals.objectionCursor,
                        objections.count - 1
                    )
                    ObjectionRow(objection: objection)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(isCursor ? Theme.bg3 : .clear)
                        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
                        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                        .hint(goals.focus == .objections ? model.hintLabel(for: .row(.goals, index)) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickObjection(index) }
                        .rightClickMenu {
                            guard model.clicksReachLists else { return false }
                            model.clickObjection(index)
                            return true
                        } _: { model.objectionMenu(index) }
                }
            }
            if let score = reviewer.score {
                WhyBar(score: score)
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("review.recheck", scope: "goalreviewers", label: reviewer.running ? "running" : "re-check")
                KeyHint("review.accept", scope: "goalreviewers", label: "accept risk")
                KeyHint("review.fix", scope: "goalreviewers", label: "start session to fix")
                KeyHint("review.why", scope: "goalreviewers", label: "ask the reviewer why")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// `reviews: implementation · v3 · acme/docs-toolkit#2841@4be1f20`.
    private var header: String {
        var parts = ["reviews: \(reviewer.config.kind.lens?.title ?? "custom")"]
        if let basis = reviewer.lastReview?.basis ?? reviewer.lastRun?.basis { parts.append(basis.text) }
        parts.append(reviewer.config.policy.text)
        return parts.joined(separator: " · ")
    }
}

private struct ObjectionRow: View {
    let objection: Objection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SeverityTag(severity: objection.severity, quiet: objection.state != .open)
            VStack(alignment: .leading, spacing: 3) {
                Text(objection.text).font(Theme.ui(13))
                    .foregroundStyle(objection.state == .open ? Theme.fg : Theme.fg2)
                    .strikethrough(objection.state == .fixed, color: Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = objection.evidence ?? objection.file {
                    Text(evidence).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(stateText).font(Theme.mono(10.5)).foregroundStyle(Theme.fg2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                .fixedSize()
        }
    }

    private var stateText: String {
        switch objection.state {
        case .fixed: "fixed · +\(GoalBarTable.number(GoalScore.fixedCredit))"
        default: objection.state.text
        }
    }
}

struct SeverityTag: View {
    let severity: Severity
    var quiet = false

    var body: some View {
        Text(severity.label).font(Theme.mono(10.5, weight: .semibold))
            .foregroundStyle(quiet ? Theme.fg3 : tint)
            .frame(width: 46)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill((quiet ? Theme.fg3 : tint).opacity(0.14)))
    }

    private var tint: Color {
        switch severity {
        case .high: Theme.err
        case .med: Theme.block
        case .low: Theme.fg2
        }
    }
}

/// WHY 5.8: the score as a bar, and what it is made of.
private struct WhyBar: View {
    let score: GoalScore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Why \(GoalBarTable.number(score.value))")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(score.value >= 7 ? Theme.done : score.value >= 5 ? Theme.block : Theme.err)
                        .frame(width: geometry.size.width * min(max(score.value / 10, 0), 1))
                }
            }
            .frame(height: 6)
            Text(score.basis).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Spawn

/// Spawn a reviewer: its kind, what it looks at, when it re-checks, and what it runs as.
private struct SpawnPanel: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        let spawn = goals.spawn
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spawn a reviewer").font(Theme.ui(14, weight: .semibold))
                Spacer()
                KeyHint("reviewer.spawn", scope: "goalreviewers", label: "spawn", color: Theme.fg2)
            }
            SectionHeader(title: "Kind")
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(ReviewerKind.allCases, id: \.self) { kind in
                    Chip(text: kind.short, on: spawn.kind == kind) { model.goals.spawn.kind = kind }
                }
            }
            if spawn.kind == .custom {
                Group {
                    if ShotMode.active || !goals.spawnTyping {
                        Text(spawn.instructions.isEmpty ? "Its instructions: who it is, what it looks for" : spawn
                            .instructions)
                            .foregroundStyle(spawn.instructions.isEmpty ? Theme.fg3 : Theme.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.goals.spawnTyping = true
                                model.textInputActive = true
                            }
                    } else {
                        TextField(
                            "Its instructions", text: Binding(
                                get: { model.goals.spawn.instructions }, set: { model.goals.spawn.instructions = $0 }
                            ), axis: .vertical
                        )
                        .textFieldStyle(.plain)
                    }
                }
                .font(Theme.ui(12.5))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            }
            SectionHeader(title: "Looks at")
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(looksAt, id: \.self) { Tag(text: $0) }
            }
            SectionHeader(title: "Re-checks")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ReviewPolicy.allCases, id: \.self) { policy in
                    HStack(spacing: 8) {
                        Circle().fill(spawn.policy == policy ? Theme.block : Theme.line).frame(width: 8, height: 8)
                        Text(policy.text).font(Theme.ui(12.5))
                            .foregroundStyle(spawn.policy == policy ? Theme.fg : Theme.fg2)
                    }
                    .clickable()
                    .onTapGesture { model.goals.spawn.policy = policy }
                }
            }
            SectionHeader(title: "Runs as")
            if ShotMode.active {
                // Screenshots draw no AppKit views: the menus' labels instead.
                HStack(spacing: 8) {
                    Picked(text: (spawn.agent ?? defaultAgent) + " ▾")
                    Picked(text: (spawn.tier ?? model.config.goals.tier(for: spawn.kind)).rawValue + " ▾")
                }
            } else {
                runsAs(spawn)
            }
            Text("Reviewers read, run tests and benchmarks in a worktree of their own, and write what they find. "
                + "They never edit your code or push.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func runsAs(_ spawn: GoalsBrowser.Spawn) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("The goal's sessions' agent") { model.goals.spawn.agent = nil }
                ForEach(model.settings.agents.map(\.name), id: \.self) { name in
                    Button(name) { model.goals.spawn.agent = name }
                }
            } label: {
                Picked(text: (spawn.agent ?? defaultAgent) + " ▾")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("As configured") { model.goals.spawn.tier = nil }
                ForEach(ModelTier.allCases, id: \.self) { tier in
                    Button(tier.rawValue) { model.goals.spawn.tier = tier }
                }
            } label: {
                Picked(text: (spawn.tier ?? model.config.goals.tier(for: spawn.kind)).rawValue + " ▾")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var defaultAgent: String {
        model.config.goals.reviewerAgent.isEmpty ? "session's agent" : model.config.goals.reviewerAgent
    }

    /// The goal, its plan, and the PRs on it.
    private var looksAt: [String] {
        let pulls = model.goalOverview(goal).pulls
        var tags = ["goal", "GOAL.md v\(goal.version)"]
        tags += pulls.prefix(3).map { "PR #\($0.ref.number)" }
        if pulls.isEmpty { tags.append("a session's branch") }
        return tags
    }
}

private struct Chip: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Text(text).font(Theme.mono(11.5))
            .foregroundStyle(on ? Theme.ink : Theme.fg2)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.inverse : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? .clear : Theme.line))
            .clickable()
            .onTapGesture(perform: action)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.mono(11)).foregroundStyle(Theme.block)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.block.opacity(0.12)))
    }
}

private struct Picked: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.fg)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

// MARK: Bars

/// The goal's profile and its quality bars: each required lens, its bar, and the best score for it so far.
struct QualityBars: View {
    let quality: GoalQuality

    var body: some View {
        Panel(title: "Quality bars", note: quality.profile?.profile.text ?? "profile not decided yet") {
            if quality.lenses.isEmpty {
                Quieter("No lens required yet.")
            }
            ForEach(quality.lenses, id: \.lens) { lens in
                HStack(spacing: 10) {
                    Image(systemName: lens.met ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(lens.met ? Theme.done : Theme.fg3)
                        .font(.system(size: 11))
                    Text(lens.lens.title).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                    Spacer(minLength: 6)
                    Text(lens.score.map(GoalBarTable.number) ?? "–").font(Theme.mono(12))
                        .foregroundStyle(lens.met ? Theme.done : Theme.fg2)
                    Text("/ \(GoalBarTable.number(lens.bar))").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                        .help(quality.pins[lens.lens] != nil ? "Pinned for this goal" : "From the goal's profile")
                    if quality.pins[lens.lens] != nil {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.fg3)
                    }
                }
            }
            if let change = quality.profiles.last(where: { !$0.changes.isEmpty }) {
                Text("v\(change.goalVersion): " + change.changes.map(\.text).joined(separator: "; "))
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            if let confidence = quality.confidence {
                Text("Confidence \(GoalBarTable.number(confidence.value)): \(confidence.basis)")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
            if !quality.done.done, !quality.done.missing.isEmpty {
                Text("Not done: " + quality.done.missing.joined(separator: ", "))
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            KeyHint("goal.bar", scope: "goalreviewers", label: "pin a bar", color: Theme.fg2)
        }
    }
}

/// The overview's "how happy are they": each reviewer's ring, what is open and its trend.
struct HowHappy: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let quality = model.goals.qualities[goal.id] ?? .empty
        Panel(title: "How happy are they", note: quality.live.isEmpty ? "" : "\(quality.live.count)") {
            if quality.live.isEmpty {
                Quieter("No reviewers yet: they come with the goal's profile.")
            }
            VStack(spacing: 8) {
                ForEach(quality.live) { reviewer in
                    ReviewerRow(reviewer: reviewer)
                        .contentShape(Rectangle())
                        .clickable()
                        .onTapGesture {
                            model.toggleGoalReviewers()
                            model.goals.point(reviewer: reviewer.id)
                            model.goals.setFocus(.reviewers)
                        }
                }
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("goal.reviewers", scope: "goals", label: "reviewers")
                KeyHint("review.recheck", scope: "goals", label: "re-check all")
            }
        }
    }
}

private struct Quieter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
    }
}
