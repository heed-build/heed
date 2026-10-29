import HeedCore
import SwiftUI

/// The overview's Sources: the GitHub queries the goal's items come from, each with its done rule and how far along
/// its items are, and the source heed proposes when the goal reads like a set over GitHub. Right-click a source for
/// its rule, its query, or to take it off.
struct GoalSourcesPanel: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let snapshot = model.goals.snapshot
        let state = snapshot.sources(of: goal.id)
        Panel(title: "Sources", note: state.sources.isEmpty ? "" : "\(state.sources.count)") {
            if let proposal = state.proposal { ProposedSource(proposal: proposal) }
            if state.sources.isEmpty, state.proposal == nil {
                Quiet("Items can come from GitHub: one per PR or issue a query finds, kept in step. "
                    + ":goal.source.add prs org/repo, issues, a label, reviews, or any search.")
            }
            ForEach(state.sources) { source in
                let progress = SourceProgress.of(
                    source, items: snapshot.items(of: goal.id), evidence: snapshot.evidence(of: goal.id)
                )
                SourceRow(source: source, progress: progress)
                    .contentShape(Rectangle())
                    .rightClickMenu { model.clicksReachLists } _: {
                        ContextMenus.goalSource(
                            id: source.id, label: source.label, query: source.query, rule: source.rule,
                            what: source.what
                        )
                    }
            }
            if !state.sources.isEmpty {
                Text(Self.status(state)).font(Theme.ui(12))
                    .foregroundStyle(state.error == nil ? Theme.fg3 : Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                KeyHint("goal.source.add", scope: "goals", label: "add a source", color: Theme.fg2)
                if !state.sources.isEmpty {
                    KeyHint("goal.source.sync", scope: "goals", label: "now", color: Theme.fg2)
                }
            }
        }
    }

    /// `synced 3m ago`, or what went wrong.
    static func status(_ state: GoalSourceState) -> String {
        if let error = state.error { return "Last sync: \(error)" }
        return state.syncedAt.map { "synced \(Clock.relative($0)) · on heed's GitHub sync" }
            ?? "not synced yet: heed fills the items on its next GitHub sync"
    }
}

/// A source: what it finds, when each item is done, and how far along they are.
private struct SourceRow: View {
    let source: ItemSource
    let progress: SourceProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(source.id).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                Text(source.label).font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if progress.complete {
                    Text("all done").font(Theme.mono(11)).foregroundStyle(Theme.done)
                }
            }
            Text("done when \(source.what == .issues ? ItemSource.Rule.closed.phrase : source.rule.phrase) · "
                + progress.text(source.rule, what: source.what))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            Text(source.query).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("Right-click: done rule, query, take it off")
    }
}

/// heed's proposal: the source, why, and y to take it.
private struct ProposedSource: View {
    @Environment(AppModel.self) private var model
    let proposal: SourceProposal

    var body: some View {
        let source = proposal.source
        VStack(alignment: .leading, spacing: 5) {
            Text("Keep items from GitHub?").font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.block)
            Text("“\(proposal.because)” reads like a set: one item per match of \(source.label), each done when "
                + "\(source.what == .issues ? ItemSource.Rule.closed.phrase : source.rule.phrase).")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Text(source.query).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            HStack(spacing: 14) {
                KeyHint("goal.source.accept", scope: "goals", label: "add it")
                KeyHint("goal.source.dismiss", scope: "goals", label: "no", color: Theme.fg2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
        .rightClickMenu { model.clicksReachLists } _: { ContextMenus.goalSourceProposal(label: source.label) }
    }
}

/// The source dialog: a query, checked as it is typed (what it will search, or what is wrong), and when each item is
/// done. ↩ or ⌘↩ adds it (or changes the one being edited); ⎋ leaves it.
struct SourceFormView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let form = model.goals.sourceForm
        let notes = form?.notes ?? []
        let tried = form?.tried == true
        let parsed = form.flatMap { try? ItemSourceQuery.parse($0.query, repo: $0.repo) }
        let what = parsed.map { ItemSourceQuery.what($0.query) } ?? .pulls
        let rule = form?.rule ?? parsed?.rule ?? .merged
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 12) {
                Text(form?.editing == nil ? "New source" : "Change \(form?.editing ?? "")")
                    .font(Theme.ui(16, weight: .semibold))
                Text("One item per PR or issue the query finds, kept in step on heed's GitHub sync.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                SectionHeader(title: "Query")
                Group {
                    if ShotMode.active {
                        Text(form?.query ?? "").frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("prs org/repo, issues, label <name>, reviews, or a search", text: query)
                            .textFieldStyle(.plain)
                    }
                }
                .font(Theme.mono(12.5))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .focused($focused)
                FieldNoteView(note: notes.note(for: "query", tried: tried))
                SectionHeader(title: "Done when")
                HStack(spacing: 8) {
                    ForEach(what == .issues ? [ItemSource.Rule.closed] : ItemSource.Rule.allCases, id: \.self) { each in
                        let picked = (what == .issues ? .closed : rule) == each
                        Text(each.phrase).font(Theme.ui(12.5))
                            .foregroundStyle(picked ? Theme.bg : Theme.fg2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Theme.block : Theme.bg3))
                            .clickable()
                            .onTapGesture { model.goals.sourceForm?.rule = each }
                    }
                }
                FieldNoteView(note: notes.note(for: "rule", tried: tried))
                HStack(spacing: 18) {
                    Spacer()
                    KeyHint(keys: "<Esc>", label: "cancel")
                    ConfirmHint(
                        keys: "<D-CR>", label: form?.editing == nil ? "add" : "change", blocking: notes.blocking
                    )
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shotRegion(.sourceForm)
        }
        .onAppear { focused = true }
    }

    private var query: Binding<String> {
        Binding(get: { model.goals.sourceForm?.query ?? "" }, set: { model.goals.sourceForm?.query = $0 })
    }
}
