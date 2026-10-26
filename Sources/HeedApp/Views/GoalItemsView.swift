import HeedCore
import SwiftUI

// MARK: The matrix

/// The overview's items × stages: each stage filled by evidence, never ticked by hand. A click shows the item on the
/// board; right-click acts on it.
struct GoalMatrix: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        let items = goals.items.filter { $0.kind == .work }
        let evidence = goals.evidence
        let lenses = goals.requiredLenses
        Panel(title: "Implementation state", note: items.isEmpty ? "" : "\(items.count) items") {
            if items.isEmpty {
                HStack(spacing: 8) {
                    Quiet("No items yet. The planner breaks GOAL.md into them, sessions add what they find.")
                    KeyHint("goal.plan", label: "plan now")
                }
            } else {
                legend
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("ITEM").frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Stage.allCases, id: \.self) { stage in
                            Text(stage.title.uppercased()).frame(width: Self.cell)
                        }
                    }
                    .font(Theme.ui(10, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .frame(height: 26)
                    ForEach(items) { item in
                        let marks = Stages.of(item, evidence: evidence, requiredLenses: lenses)
                        HStack(spacing: 0) {
                            Text(item.title).font(Theme.ui(12.5)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Stage.allCases, id: \.self) { stage in
                                let mark = marks[stage] ?? .notYet
                                Text(mark.glyph)
                                    .font(Theme.mono(12, weight: mark == .issue ? .bold : .regular))
                                    .foregroundStyle(Self.tint(mark))
                                    .frame(width: Self.cell)
                                    .help(Self.help(stage, mark, item: item, evidence: evidence))
                            }
                        }
                        .frame(height: 30)
                        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                        .contentShape(Rectangle())
                        .clickable()
                        .onTapGesture { model.showGoalItem(item.id) }
                        .rightClickMenu { model.clicksReachLists } _: { model.goalItemMenu(item.id) }
                    }
                }
            }
        }
    }

    static let cell: CGFloat = 58

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([StageMark.done, .inProgress, .issue, .notYet, .notApplicable], id: \.self) { mark in
                HStack(spacing: 4) {
                    Text(mark.glyph).foregroundStyle(Self.tint(mark))
                    Text(mark.word).foregroundStyle(Theme.fg3)
                }
            }
        }
        .font(Theme.mono(11))
    }

    static func tint(_ mark: StageMark) -> Color {
        switch mark {
        case .done: Theme.done
        case .inProgress: Theme.busy
        case .issue: Theme.err
        case .notYet: Theme.fg3
        case .notApplicable: Theme.line
        }
    }

    private static func help(_ stage: Stage, _ mark: StageMark, item: GoalItem, evidence: [GoalEvidence]) -> String {
        let latest = evidence.filter { $0.item == item.id && $0.kind == stage.evidence }
            .max { Stages.newer($1, than: $0) }
        let basis = latest.map { [$0.text, $0.source].filter { !$0.isEmpty }.joined(separator: " · ") }
        return "\(stage.title): \(mark.word)" + (basis.map { " — \($0)" } ?? "")
    }
}

/// What the goal waits on you for: GOAL.md changes, open questions, and its sessions that need you.
struct NeedsYou: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let rows: [GoalOverview.Row]
    let questions: [String]

    var body: some View {
        let proposals = model.goals.proposals.count
        let waiting = rows.filter { $0.state == .blocked || $0.state == .asking }
        Panel(title: "Needs you", note: "") {
            if proposals == 0, questions.isEmpty, waiting.isEmpty {
                Quiet("Nothing: the work runs without you for now.")
            }
            if proposals > 0 {
                Text("\(proposals) change\(proposals == 1 ? "" : "s") to GOAL.md wait for a yes or no")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.block)
                    .clickRuns(CommandInvocation(name: "goal.doc"))
            }
            ForEach(questions, id: \.self) { question in
                Text("· " + question).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !waiting.isEmpty {
                Text("\(waiting.count) session\(waiting.count == 1 ? "" : "s") waiting: "
                    + waiting.map(\.title).joined(separator: ", "))
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: The board

/// A goal as a board: what is unknown, planned, running, being checked and done. Cards move themselves as evidence
/// arrives; H L or a drag moves one by hand until the next evidence about it.
struct GoalBoardPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    @State private var dragging: (id: String, offset: CGSize)?

    private static let spacing: CGFloat = 10

    var body: some View {
        let goals = model.goals
        let columns = goals.columns
        let evidence = goals.evidence
        VStack(alignment: .leading, spacing: 16) {
            GoalHeader(goal: goal, statement: goals.snapshot.docs[goal.id]?.goal ?? "")
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geometry in
                    let count = CGFloat(Board.Column.allCases.count)
                    let width = max((geometry.size.width - Self.spacing * (count - 1)) / count, 80)
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(Array(Board.Column.allCases.enumerated()), id: \.element) { index, column in
                            columnView(
                                column,
                                index: index,
                                cards: columns[column] ?? [],
                                evidence: evidence,
                                width: width
                            )
                        }
                    }
                }
                BoardSide(goal: goal).frame(width: 280)
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint(
                    "goal.item.column", ["1"],
                    key: model.keyText(for: "goal.item.column -1", in: "goalboard") + " "
                        + model.keyText(for: "goal.item.column 1", in: "goalboard"),
                    label: "column"
                )
                KeyHint(
                    "goal.item.move", ["right"],
                    key: model.keyText(for: "goal.item.move left", in: "goalboard") + " "
                        + model.keyText(for: "goal.item.move right", in: "goalboard"),
                    label: "move the card"
                )
                KeyHint("goal.item.add", scope: "goalboard", label: "add an item")
                KeyHint("goal.item.work", scope: "goalboard", label: "work here")
                KeyHint("goal.item.open", scope: "goalboard", label: "open")
                KeyHint("goal.item.done", scope: "goalboard", label: "done")
            }
        }
        .padding(24)
    }

    private func columnView(
        _ column: Board.Column, index: Int, cards: [GoalItem], evidence: [GoalEvidence], width: CGFloat
    ) -> some View {
        let goals = model.goals
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: column.title)
                Spacer()
                Text("\(cards.count)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 4)
            if cards.isEmpty {
                Text(column == .toExplore ? "Questions land here" : "–")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).padding(.horizontal, 4)
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { row, item in
                let isCursor = goals.boardColumn == column && goals.boardRow == row
                let dragged = dragging?.id == item.id
                BoardCard(item: item, evidence: evidence, isCursor: isCursor)
                    .hint(model.hintLabel(for: .row(.goals, row)).flatMap { isColumn(column) ? $0 : nil })
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickGoalCard(column: column, row: row) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        model.clickGoalCard(column: column, row: row, open: true)
                    })
                    .rightClickMenu {
                        guard model.clicksReachLists else { return false }
                        model.clickGoalCard(column: column, row: row)
                        return true
                    } _: { model.goalItemMenu(item.id) }
                    .offset(dragged ? dragging?.offset ?? .zero : .zero)
                    .zIndex(dragged ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { dragging = (item.id, $0.translation) }
                            .onEnded { value in
                                let target = BoardDrag.target(
                                    from: index, by: value.translation.width, width: width, spacing: Self.spacing,
                                    count: Board.Column.allCases.count
                                )
                                var quiet = Transaction()
                                quiet.disablesAnimations = true
                                withTransaction(quiet) { dragging = nil }
                                model.dropGoalCard(item.id, on: Board.Column.allCases[target])
                            }
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// Hint labels go on the column under the cursor, as j k move there.
    private func isColumn(_ column: Board.Column) -> Bool { model.goals.boardColumn == column }
}

/// One card: what it is, its title, and the newest thing known about it.
private struct BoardCard: View {
    let item: GoalItem
    let evidence: [GoalEvidence]
    let isCursor: Bool

    var body: some View {
        let badge = Board.badge(item, evidence: evidence)
        let latest = evidence.filter { $0.item == item.id }.max { Stages.newer($1, than: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(badge.title)
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Self.tint(badge))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Self.tint(badge).opacity(0.6)))
                    .fixedSize()
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(item.source.rawValue).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Text(item.title).font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.fg)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(latest?.text ?? item.reason ?? "")
                .font(Theme.mono(10.5)).foregroundStyle(latest?.state == .issue ? Theme.err : Theme.fg3)
                .lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCursor ? Theme.bg3 : Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isCursor ? Theme.block : Theme.line))
        .help(item.confidence.map { "\(item.reason ?? item.source.rawValue) · \(Int($0 * 100))% sure it is new" }
            ?? (item.reason ?? item.source.rawValue))
    }

    static func tint(_ badge: Board.Badge) -> Color {
        switch badge {
        case .question: Theme.block
        case .session, .chat: Theme.busy
        case .pr: Theme.done
        case .review: Theme.ask
        case .bench: Theme.err
        case .swarm: Theme.block
        case .item: Theme.fg2
        }
    }
}

/// Beside the board: the goal's done-when criteria, and how far along it is.
private struct BoardSide: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let doc = model.goals.snapshot.docs[goal.id]
        let criteria = doc?.doneWhen ?? []
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Criteria", note: criteria.isEmpty ? "" : "\(criteria.count { $0.met })/\(criteria.count)") {
                if criteria.isEmpty { Quiet("GOAL.md says when it is done: E, then e.") }
                ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: criterion.met ? "checkmark.square" : "square")
                            .foregroundStyle(criterion.met ? Theme.done : Theme.fg3)
                        Text(criterion.text).font(Theme.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.goals.proposals.isEmpty {
                Panel(title: "GOAL.md", note: "") {
                    Text("\(model.goals.proposals.count) changes wait for you")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.block)
                        .clickRuns(CommandInvocation(name: "goal.doc"))
                }
            }
        }
    }
}

// MARK: GOAL.md proposals

/// The changes to GOAL.md the work suggests, waiting for a yes or no: y n c act on the first, clicks on any.
struct GoalProposals: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let proposals = model.goals.proposals
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "The work suggests", tint: proposals.isEmpty ? Theme.fg3 : Theme.block)
                Spacer()
                KeyHint("goal.sharpen", scope: "goaldoc", label: "ask to sharpen")
            }
            if proposals.isEmpty {
                Quiet("Nothing waiting. Decisions, answers and criteria met go in on their own; what changes the goal "
                    + "waits here.")
            }
            ForEach(Array(proposals.enumerated()), id: \.element.id) { index, edit in
                ProposalCard(edit: edit, first: index == 0)
                    .rightClickMenu { model.clicksReachLists } _: { model.goalProposalMenu(edit) }
            }
        }
    }
}

private struct ProposalCard: View {
    let edit: GoalEdit
    let first: Bool

    var body: some View {
        let target = edit.id.map { CommandTarget.row(view: "goals", id: "edit:\($0)") }
        VStack(alignment: .leading, spacing: 8) {
            Text("from \(edit.from) · \(Clock.relative(edit.at))")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            if let reason = edit.reason {
                Text(reason).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
            }
            Text(edit.line)
                .font(Theme.mono(11.5)).foregroundStyle(Theme.done)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.done.opacity(0.08)))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if first {
                    KeyHint("goal.proposal.accept", target: target, scope: "goaldoc", label: "accept")
                    KeyHint("goal.proposal.reject", target: target, scope: "goaldoc", label: "no")
                    KeyHint("goal.proposal.edit", target: target, scope: "goaldoc", label: "reword")
                } else {
                    word("accept", "goal.proposal.accept", target)
                    word("no", "goal.proposal.reject", target)
                    word("reword", "goal.proposal.edit", target)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(first ? 0.7 : 0.3)))
    }

    private func word(_ text: String, _ command: String, _ target: CommandTarget?) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            .clickRuns(CommandInvocation(name: command, target: target))
    }
}

/// A version's changes: lines taken out and put in, a few at most.
struct VersionDiff: View {
    let lines: [GoalVersionDiff.Line]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text((line.added ? "+ " : "− ") + line.text)
                        .font(Theme.mono(10.5)).foregroundStyle(line.added ? Theme.done : Theme.err)
                        .lineLimit(1)
                }
                if lines.count > 3 {
                    Text("+\(lines.count - 3) more").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.leading, 26)
        }
    }
}
