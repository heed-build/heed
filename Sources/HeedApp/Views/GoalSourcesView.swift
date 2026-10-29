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
