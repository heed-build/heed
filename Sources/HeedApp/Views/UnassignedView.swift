import HeedCore
import SwiftUI

/// Goals › Unassigned (`goal.unassigned`): how new work found its goal. On top, how heed decides (signals, the model
/// only when unsure, acting by confidence); then what it decided just now, with reasons, and goals it suggests from
/// work
/// on no goal; on the right, what it asks you (y n m i) and what it learnt from you.
struct UnassignedPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let attach = model.goals.attach
        let rows = attach.rows
        let settings = model.config.goals.attach
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("How work finds its goal").font(Theme.ui(18, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(settings.enabled ? "you do nothing unless heed asks" : "off: [goals] attach = false")
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                HStack(alignment: .top, spacing: 12) {
                    Step(number: 1, title: "Signals", lead: "Free, local, instant", lines: [
                        "same worktree or branch family", "files touched already on the goal", "a linked PR or issue",
                        "the prompt against GOAL.md", "repo and recency",
                    ])
                    Step(
                        number: 2, title: "Model", lead: settings.model && model.config.llm.enabled
                            ? "Cheap, only when unsure" : "Off: signals alone",
                        lines: [
                            "Reads the goals and the work; picks a goal or none, with a reason and how sure.",
                            "Logged as a decide call (:log).",
                        ]
                    )
                    Step(number: 3, title: "Act by confidence", lead: "Every act has undo", lines: [
                        "≥ \(Self.number(settings.auto))  attach, u undoes",
                        "\(Self.number(settings.ask))–\(Self.number(settings.auto))  ask, one key",
                        "< \(Self.number(settings.ask))  leave it, cluster later",
                    ])
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Just now")
                        if attach.feed.isEmpty, attach.suggestions.isEmpty {
                            Text("Nothing yet: heed looks when a session or chat starts, gets its first prompt, tracks "
                                + "a PR or gets a ledger entry.")
                                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            switch row {
                            case .ask: EmptyView()
                            case let .suggestion(suggestion):
                                SuggestionCard(suggestion: suggestion, isCursor: index == attach.cursor)
                                    .onTapGesture { model.clickAttachRow(index) }
                                    .hint(model.hintLabel(for: .row(.goals, index)))
                            case let .decision(decision):
                                DecisionCard(decision: decision, isCursor: index == attach.cursor)
                                    .onTapGesture { model.clickAttachRow(index) }
                                    .hint(model.hintLabel(for: .row(.goals, index)))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Proposed · \(attach.asks.count)")
                        if attach.asks.isEmpty {
                            Text("No asks: heed is sure, or leaves it.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if case let .ask(decision) = row {
                                AskCard(decision: decision, isCursor: index == attach.cursor)
                                    .onTapGesture { model.clickAttachRow(index) }
                                    .hint(model.hintLabel(for: .row(.goals, index)))
                            }
                        }
                        Learnt()
                    }
                    .frame(width: 360)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .shotRegion(.goalsUnassigned)
    }

    static func number(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// One of the three steps on top.
private struct Step: View {
    let number: Int
    let title: String
    let lead: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number) · \(title.uppercased())").font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.fg3)
            Text(lead).font(Theme.ui(13, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text("· " + line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// A card in the feed, highlighted under the cursor.
private struct Card<Content: View>: View {
    let isCursor: Bool
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isCursor ? Theme.bg3 : Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint ?? Theme.line))
            .overlay(alignment: .leading) {
                if isCursor { Theme.block.frame(width: 2).padding(.vertical, 6) }
            }
            .contentShape(Rectangle())
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(Theme.mono(11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6)))
            .lineLimit(1).fixedSize()
    }
}

private func kindWord(_ subject: AttachSubject) -> String { subject.kind == .chat ? "Chat" : "Session" }

/// `feature/x · acme/docs-toolkit`: where the work is.
private func place(_ subject: AttachSubject) -> String {
    var parts: [String] = []
    if !subject.branch.isEmpty { parts.append(subject.branch) }
    parts.append(subject.repos.first ?? "no repo")
    return parts.joined(separator: " · ")
}

private struct DecisionCard: View {
    @Environment(AppModel.self) private var model
    let decision: AttachDecision
    let isCursor: Bool

    var body: some View {
        Card(isCursor: isCursor) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(kindWord(decision.subject)): “\(decision.subject.title)”")
                    .font(Theme.ui(13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Badge(text: badge, color: color)
            }
            Text([place(decision.subject), Clock.relative(decision.at)].joined(separator: " · "))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            Text(decision.verdict.reason).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if isCursor {
                HStack(spacing: 14) {
                    if decision.verdict.action == .attach, decision.state == .settled {
                        KeyHint("goal.attach.undo", scope: "unassigned", label: "undo")
                    }
                    KeyHint("goal.ask.move", scope: "unassigned", label: "put on a goal")
                    if decision.state != .ignored { KeyHint(
                        "goal.ask.ignore",
                        scope: "unassigned",
                        label: "ignore like this"
                    ) }
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
            }
        }
    }

    private var goal: String {
        (decision.goal ?? decision.verdict.goal).flatMap { model.goals.snapshot.goal($0)?.title } ?? "a goal"
    }

    private var badge: String {
        switch decision.state {
        case .undone: "undone"
        case .declined: "said no"
        case .ignored: "ignored"
        case .moved: "moved → \(goal)"
        case .accepted: "yes → \(goal)"
        case .clustered: "new goal → \(goal)"
        default:
            switch decision.verdict.action {
            case .attach: "\(decision.label) → \(goal)"
            case .ask: "proposed → \(goal)"
            case .leave: "unassigned"
            case .ignore: "ignored"
            }
        }
    }

    private var color: Color {
        switch decision.state {
        case .undone, .declined, .ignored: Theme.fg3
        case .moved, .accepted, .clustered: Theme.done
        default:
            switch decision.verdict.action {
            case .attach: Theme.done
            case .ask: Theme.block
            case .leave, .ignore: Theme.fg2
            }
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: GoalSuggestion
    let isCursor: Bool

    var body: some View {
        Card(isCursor: isCursor) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(
                    "\(suggestion.subjects.count) on no goal about \(suggestion.terms.prefix(2).joined(separator: " and "))"
                )
                .font(Theme.ui(13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Badge(text: "suggest new goal", color: Theme.busy)
            }
            Text(suggestion.place).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            Text("Offers “\(suggestion.title)”, with a drafted GOAL.md: "
                + suggestion.subjects.map(\.title).joined(separator: " · "))
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if isCursor {
                HStack(spacing: 14) {
                    KeyHint("goal.ask.yes", scope: "unassigned", label: "make the goal")
                    KeyHint("goal.ask.no", scope: "unassigned", label: "not a goal")
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
            }
        }
    }
}

/// One ask: the thing, the goal, why, and the four keys.
struct AskCard: View {
    @Environment(AppModel.self) private var model
    let decision: AttachDecision
    let isCursor: Bool
    var scope = "unassigned"

    var body: some View {
        let goal = decision.verdict.goal.flatMap { model.goals.snapshot.goal($0)?.title } ?? "a goal"
        Card(isCursor: isCursor, tint: Theme.block.opacity(isCursor ? 0.8 : 0.4)) {
            (Text("Put \(decision.subject.kind == .chat ? "chat" : "session") ")
                + Text("“\(decision.subject.title)”").fontWeight(.semibold) + Text(" on ")
                + Text(goal).fontWeight(.semibold) + Text("?"))
                .font(Theme.ui(13)).fixedSize(horizontal: false, vertical: true)
            Text("\(Int((decision.verdict.confidence * 100).rounded()))% · " + decision.verdict.reason)
                .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            let others = decision.candidates.filter { $0.goal != decision.verdict.goal }
            if !others.isEmpty {
                Text("also: " + others.map { candidate in
                    let title = model.goals.snapshot.goal(candidate.goal)?.title ?? candidate.goal
                    return "\(title) \(Int((candidate.confidence * 100).rounded()))%"
                }.joined(separator: " · "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                KeyHint("goal.ask.yes", scope: scope, label: "yes")
                KeyHint("goal.ask.no", scope: scope, label: "no")
                KeyHint("goal.ask.move", scope: scope, label: "other goal")
                KeyHint(
                    "goal.ask.ignore",
                    scope: scope,
                    label: decision.subject.kind == .chat
                        ? "ignore chats like this" : "ignore like this"
                )
            }
            .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            .opacity(isCursor ? 1 : 0.55)
        }
    }
}

/// What heed learnt from you: the rules file, its problems, and today's numbers.
private struct Learnt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let attach = model.goals.attach
        Panel(
            title: "It learns from you",
            note: "\(attach.rules.rules.count) rule\(attach.rules.rules.count == 1 ? "" : "s")"
        ) {
            Text(
                "Undo, n, a move or i adds a line to attach.rules (“never branch:feature/x-* -> goal”), and rules apply "
                    + "before any signal. Plain lines you can edit."
            )
            .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            ForEach(attach.rules.rules.suffix(3), id: \.line) { rule in
                Text(rule.text).font(Theme.mono(11)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(attach.rules.problems.prefix(2), id: \.line) { problem in
                Text(problem.description).font(Theme.mono(11)).foregroundStyle(Theme.err).lineLimit(2)
            }
            Text(Paths.tilde(model.goals.files.rules.path))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head)
            Text("today: " + attach.today(now: Clock.now).text)
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The sidebar's last row: what is on no goal, below the goals.
struct UnassignedRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goals = model.goals
        let current = goals.pane == .unassigned
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.fg3, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                Text("\(goals.attach.unassignedCount)").font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.fg2)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Unassigned").font(Theme.ui(13, weight: .semibold))
                Text(goals.attach.asks.isEmpty ? "work heed left alone"
                    : "\(goals.attach.asks.count) proposed · "
                    + "\(max(goals.attach.unassignedCount - goals.attach.asks.count, 0)) left")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer(minLength: 0)
            KeyHint("goal.unassigned", scope: "goals") { EmptyView() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if current { Theme.block.frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.perform(CommandInvocation(name: "goal.unassigned")) }
    }
}
