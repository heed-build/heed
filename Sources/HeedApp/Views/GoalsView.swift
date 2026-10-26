import HeedCore
import SwiftUI

/// Goals (`view.goals`): the goals in a list on the left, each with its score ring and where it stands; on the right
/// the goal under the cursor, as an overview (what it is, its numbers, the sessions and chats on it, their PRs, where
/// the work was left) or as its GOAL.md with its versions (`goal.doc`).
struct GoalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goals = model.goals
        GeometryReader { geometry in
            HStack(spacing: 0) {
                GoalList()
                    .frame(width: geometry.size.width < 1000 ? 260 : 320)
                    .frame(height: geometry.size.height)
                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                    .shotRegion(.goalsList)
                Group {
                    if goals.pane == .unassigned {
                        UnassignedPane()
                    } else if let goal = goals.selected {
                        switch goals.pane {
                        case .overview, .unassigned: GoalOverviewPane(goal: goal).shotRegion(.goalsOverview)
                        case .doc: GoalDocPane(goal: goal).shotRegion(.goalsDoc)
                        case .board: GoalBoardPane(goal: goal).shotRegion(.goalsBoard)
                        case .reviewers: GoalReviewersPane(goal: goal)
                        }
                    } else {
                        EmptyState(
                            title: goals.snapshot.goals.isEmpty ? "No goals yet" : "Nothing matches",
                            detail: goals.unavailable
                                ? "goals.sqlite could not be opened, so goals are not kept. The log says why."
                                : "A goal is long-running work that sessions, chats and PRs belong to, with a GOAL.md "
                                + "every agent on it reads first.",
                            actions: [EmptyState.Action("New goal", "goal.new")],
                            pointer: EmptyState.Action("Goals", "tutor", arguments: ["goals"]),
                            pointerText: "New here? The tutor shows"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.size.height, alignment: .top)
                .clipped()
            }
        }
    }
}

// MARK: The list

private struct GoalList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goals = model.goals
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionHeader(title: "Goals · \(goals.snapshot.goals.count)")
                Spacer(minLength: 8)
                FilterPill(view: .goals)
                KeyHint("goal.new", scope: "goals", label: "new")
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ListScroll {
                VStack(spacing: 0) {
                    ForEach(Array(goals.rows.enumerated()), id: \.element.id) { index, goal in
                        GoalRow(
                            goal: goal, links: goals.snapshot.links(of: goal.id),
                            isCursor: index == goals.cursor,
                            focused: goals.focus == .goals && goals.pane != .unassigned
                        )
                        .hint(goals.focus == .goals ? model.hintLabel(for: .row(.goals, index)) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickGoal(index) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.clickGoal(index, open: true) })
                        .rightClickMenu {
                            guard model.clicksReachLists else { return false }
                            model.clickGoal(index)
                            return true
                        } _: { model.goalMenu(index) }
                    }
                }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            UnassignedRow()
            Theme.line.frame(height: 1)
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("goal.focus", scope: "goals", label: "what is on it")
                KeyHint("goal.doc", scope: "goals", label: "GOAL.md")
                KeyHint("goal.reviewers", scope: "goals", label: "reviewers")
                KeyHint("goal.archive", scope: "goals", label: "archive")
                KeyHint("session.filter", label: "filter")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GoalRow: View {
    let goal: HeedGoal
    let links: [GoalLink]
    let isCursor: Bool
    let focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            ScoreRing(score: goal.score)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.title)
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(goal.status == .archived ? Theme.fg3 : Theme.fg)
                    .lineLimit(1)
                Text(subline).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? (focused ? Theme.bg3 : Theme.bg2) : .clear)
        .overlay(alignment: .leading) { if isCursor, focused { Theme.block.frame(width: 2) } }
    }

    private var subline: String {
        let sessions = links.count { $0.kind == .session }
        let chats = links.count { $0.kind == .chat }
        var parts: [String] = []
        if goal.status != .active { parts.append(goal.status.rawValue) }
        parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions")
        if chats > 0 { parts.append(chats == 1 ? "1 chat" : "\(chats) chats") }
        parts.append("v\(goal.version)")
        return parts.joined(separator: " · ")
    }
}

// MARK: Overview

private struct GoalOverviewPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let overview = model.goalOverview(goal)
        let doc = model.goals.snapshot.docs[goal.id]
        let goals = model.goals
        let work = goals.items.filter { $0.kind == .work }
        let done = goals.columns[.done]?.count { $0.kind == .work } ?? 0
        ListScroll {
            VStack(alignment: .leading, spacing: 18) {
                GoalHeader(goal: goal, statement: doc?.goal ?? "")
                HStack(spacing: 12) {
                    StatTile(value: goal.score.map { String(format: "%.1f", $0) } ?? "–", label: "confidence")
                    StatTile(value: work.isEmpty ? "–" : "\(done)/\(work.count)", label: "items done")
                    StatTile(
                        value: overview.criteriaTotal == 0 ? "–" : "\(overview.criteriaMet)/\(overview.criteriaTotal)",
                        label: "criteria met"
                    )
                    StatTile(value: "\(overview.sessions)", label: overview.sessions == 1 ? "session" : "sessions")
                    StatTile(
                        value: overview.pulls.isEmpty ? "–" : "\(overview.merged) of \(overview.pulls.count)",
                        label: "PRs merged"
                    )
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        GoalMatrix(goal: goal).shotRegion(.goalMatrix)
                        OnTheGoal(rows: overview.rows)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HowHappy(goal: goal).shotRegion(.goalHappy)
                        Panel(title: "Resulting PRs", note: overview.pulls.isEmpty ? "" : "\(overview.pulls.count)") {
                            if overview.pulls.isEmpty {
                                Quiet("None yet: PRs the goal's sessions open show here.")
                            }
                            ForEach(overview.pulls) { pull in
                                HStack(spacing: 8) {
                                    Text("#" + String(pull.ref.number)).font(Theme.mono(11.5))
                                        .foregroundStyle(Theme.fg3)
                                    Text(pull.title ?? pull.ref.repo.name).font(Theme.ui(12.5)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    PullWord(state: pull.state)
                                }
                                .clickRuns(CommandInvocation(name: "overlay.item", target: .pull(pull.ref)))
                            }
                        }
                        NeedsYou(goal: goal, rows: overview.rows, questions: doc?.openQuestions ?? [])
                        Panel(title: "Last time", note: overview.lastTime.map { Clock.relative($0.at) } ?? "") {
                            if let last = overview.lastTime {
                                Text(last.title).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                                Text(last.summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Quiet("Where the work was left shows here once the ledger has a summary of one of "
                                    + "the goal's sessions.")
                            }
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// The goal's title, version and statement, and the goal's keys.
struct GoalHeader: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let statement: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(goal.title).font(Theme.ui(18, weight: .semibold)).lineLimit(1)
                Text("goal v\(goal.version)").font(Theme.mono(11)).foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                if goal.status != .active { PullWord(state: goal.status.rawValue) }
                Spacer(minLength: 12)
                KeyHint(
                    "goal.doc", scope: "goals",
                    label: model.goals.pane == .doc ? "overview" : "GOAL.md", color: Theme.fg2
                )
                KeyHint(
                    "goal.board", scope: "goals", label: model.goals.pane == .board ? "overview" : "board",
                    color: Theme.fg2
                )
                KeyHint("goal.edit", scope: "goals", label: "edit", color: Theme.fg2)
                KeyHint("goal.reviewers", scope: "goals", label: "reviewers", color: Theme.fg2)
                KeyHint(
                    "goal.archive", scope: "goals", label: goal.status == .archived ? "bring back" : "archive",
                    color: Theme.fg2
                )
            }
            if !statement.isEmpty {
                Text(statement).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The sessions and chats on the goal, newest first: ⇥ moves the cursor here, ↩ goes to one.
private struct OnTheGoal: View {
    @Environment(AppModel.self) private var model
    let rows: [GoalOverview.Row]

    var body: some View {
        let goals = model.goals
        Panel(title: "On this goal", note: "\(rows.count)") {
            if rows.isEmpty {
                Quiet("Nothing yet. On a session, 'g… :goal.attach puts it here, or right-click it.")
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    let isCursor = goals.focus == .links && index == goals.linkCursor
                    HStack(spacing: 10) {
                        if let state = row.state { StateGlyph(state: state) } else {
                            Circle().strokeBorder(Theme.line, lineWidth: 1.5).frame(width: 12, height: 12)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(Theme.ui(13, weight: .medium)).lineLimit(1)
                            Text([row.place, row.link.kind == .chat ? "chat" : nil, row.open ? nil : "closed"]
                                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if isCursor {
                            KeyHint("goal.open", scope: "goals", label: row.open ? "go there" : "closed")
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                    .background(isCursor ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
                    .hint(goals.focus == .links ? model.hintLabel(for: .row(.goals, index)) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickGoalLink(index) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.clickGoalLink(index, open: true) })
                    .rightClickMenu {
                        guard model.clicksReachLists else { return false }
                        model.clickGoalLink(index)
                        return true
                    } _: { model.goalLinkMenu(index) }
                }
            }
        }
    }
}

/// A state in words: merged, open, closed, done, archived.
struct PullWord: View {
    let state: String

    var body: some View {
        Text(state)
            .font(Theme.mono(11))
            .foregroundStyle(state == "merged" || state == "done" ? Theme.done : Theme.fg2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            .fixedSize()
    }
}

struct Quiet: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: GOAL.md

private struct GoalDocPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("GOAL.md").font(Theme.ui(16, weight: .semibold))
                    Text("v\(goal.version) · \(goal.updatedAt.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                    Spacer(minLength: 12)
                    if goals.draft != nil {
                        KeyHint(keys: "<Esc>", label: "save", color: Theme.fg2)
                        Text("Cancel").font(Theme.ui(12)).foregroundStyle(Theme.fg2).clickable()
                            .onTapGesture { model.endGoalEditing() }
                    } else {
                        KeyHint("goal.edit", scope: "goals", label: "edit", color: Theme.fg2)
                        KeyHint("goal.doc", scope: "goals", label: "overview", color: Theme.fg2)
                    }
                }
                if goals.draft != nil {
                    GoalEditor()
                } else if let doc = goals.snapshot.docs[goal.id] {
                    ListScroll { RenderedGoal(doc: doc).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Text(Paths.tilde(goals.files.doc(goal.id).path))
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head)
                    .help("Agents on this goal are told to read this file first")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            VStack(alignment: .leading, spacing: 16) {
                GoalProposals(goal: goal).shotRegion(.goalProposals)
                GoalVersions(goal: goal).shotRegion(.goalVersions)
            }
            .frame(width: 360)
        }
        .padding(20)
    }
}

/// The doc as sections, the way the file reads.
private struct RenderedGoal: View {
    let doc: GoalDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Goal") {
                Text(doc.goal.isEmpty ? "Not written yet." : doc.goal)
                    .font(Theme.ui(14)).foregroundStyle(doc.goal.isEmpty ? Theme.fg3 : Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section("Not the goal") { bullets(doc.notTheGoal) }
            section("Done when") {
                if doc.doneWhen.isEmpty { empty }
                ForEach(Array(doc.doneWhen.enumerated()), id: \.offset) { _, criterion in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: criterion.met ? "checkmark.square" : "square")
                            .foregroundStyle(criterion.met ? Theme.done : Theme.fg3)
                        Text(criterion.text).font(Theme.ui(13)).fixedSize(horizontal: false, vertical: true)
                        if let evidence = criterion.evidence {
                            Text(evidence).font(Theme.mono(11)).foregroundStyle(Theme.block)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.block.opacity(0.12)))
                        }
                    }
                }
            }
            section("Open questions") { bullets(doc.openQuestions) }
            section("Decisions") {
                if doc.decisions.isEmpty { empty }
                ForEach(Array(doc.decisions.enumerated()), id: \.offset) { _, decision in
                    (Text("· " + decision.text).foregroundStyle(Theme.fg)
                        + Text(decision.source.map { "  (\($0))" } ?? "").foregroundStyle(Theme.fg3))
                        .font(Theme.ui(13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(doc.extras, id: \.heading) { extra in
                section(extra.heading) {
                    Text(extra.body).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var empty: some View { Text("None yet.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3) }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: title)
            content()
        }
    }

    @ViewBuilder private func bullets(_ items: [String]) -> some View {
        if items.isEmpty { empty }
        ForEach(items, id: \.self) { item in
            Text("· " + item).font(Theme.ui(13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// GOAL.md as text, edited in place: ⎋ or ⌘S saves it as a new version.
private struct GoalEditor: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: Binding(get: { model.goals.draft ?? "" }, set: { model.goals.draft = $0 }))
            .font(Theme.mono(12.5))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .focused($focused)
            .onAppear { focused = true }
    }
}

/// Every version, newest first, with what changed; a click on an older one restores it (as a new version).
private struct GoalVersions: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        Panel(title: "Versions", note: "\(model.goals.versions.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.goals.versions.enumerated()), id: \.element.id) { index, version in
                    let versions = model.goals.versions
                    let previous = versions.indices.contains(index + 1) ? versions[index + 1].text : nil
                    let undo = model.goals.snapshot.edits.first {
                        $0.goal == goal.id && $0.version == version.number && $0.state == .applied && $0.kind == .record
                    }
                    HStack(spacing: 8) {
                        Text("v\(version.number)").font(Theme.mono(11.5))
                            .foregroundStyle(version.number == goal.version ? Theme.block : Theme.fg3)
                        Text(Clock.relative(version.at)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                        Text(version.note).font(Theme.ui(12)).foregroundStyle(Theme.fg).lineLimit(1)
                        Spacer(minLength: 6)
                        if version.number == goal.version, undo != nil {
                            KeyHint("goal.undo", scope: "goaldoc", label: "undo")
                        } else if version.number != goal.version {
                            Text("restore").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                .clickRuns(CommandInvocation(name: "goal.restore", arguments: ["\(version.number)"]))
                        }
                    }
                    VersionDiff(lines: GoalVersionDiff.of(old: previous, new: version.text))
                }
            }
        }
    }
}

// MARK: New goal

/// The new goal dialog: a title and what the goal is. ⌘↩ makes it; ⎋ leaves it.
struct GoalFormView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var field: Field?

    enum Field { case title, statement }

    var body: some View {
        let form = model.goals.form
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 14) {
                Text("New goal").font(Theme.ui(16, weight: .semibold))
                if let id = form?.session, let session = model.sessions.first(where: { $0.id == id }) {
                    Text("From \(session.title), which goes on it")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                SectionHeader(title: "Title")
                // Screenshots draw no AppKit views: the fields' text instead.
                Group {
                    if ShotMode.active {
                        Text(form?.title ?? "").frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("What the goal is called", text: binding(\.title)).textFieldStyle(.plain)
                    }
                }
                .font(Theme.ui(14))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .focused($field, equals: .title)
                SectionHeader(title: "The goal")
                Group {
                    if ShotMode.active {
                        Text(form?.statement ?? "").padding(5).frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                    } else {
                        TextEditor(text: binding(\.statement)).scrollContentBackground(.hidden)
                    }
                }
                .font(Theme.ui(13))
                .padding(6)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .focused($field, equals: .statement)
                Text("GOAL.md starts from these, with empty sections for what is not the goal, when it is done, "
                    + "open questions and decisions.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Spacer()
                    KeyHint(keys: "<Esc>", label: "cancel")
                    KeyHint(keys: "<D-CR>", label: "create", color: Theme.fg)
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shotRegion(.goalForm)
        }
        .onAppear { field = .title }
    }

    private func binding(_ path: WritableKeyPath<GoalsBrowser.Form, String>) -> Binding<String> {
        Binding(
            get: { model.goals.form?[keyPath: path] ?? "" },
            set: { model.goals.form?[keyPath: path] = $0 }
        )
    }
}
