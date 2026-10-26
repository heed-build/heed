import HeedCore
import SwiftUI

/// The overview's GitHub panel: where the goal mirrors to, its meta issue, the last sync and what went wrong, and a
/// colleague's change waiting for an answer. Not mirrored: how to start.
struct GoalMirrorPanel: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        let state = goals.mirror(of: goal.id)
        let repo = goal.tracker?.repo
        Panel(title: "On GitHub", note: state.on ? "mirrored" : repo == nil ? "" : "off") {
            if let repo {
                HStack(spacing: 8) {
                    Text(repo).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                    if let number = goal.tracker?.metaIssue {
                        Text("#\(number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                            .clickRuns(CommandInvocation(name: "goal.mirror.open"))
                    }
                    Spacer(minLength: 6)
                    if let check = goals.checks[repo], !check.ok {
                        Text("can't write").font(Theme.mono(11)).foregroundStyle(Theme.err)
                    }
                }
                Text(Self.status(state))
                    .font(Theme.ui(12)).foregroundStyle(state.error == nil ? Theme.fg3 : Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(state.asks) { ask in
                    let title = goals.snapshot.item(ask.item)?.title ?? ask.item
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(ask.issue) \(title)").font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
                        Text(ask.kind == .done ? "Closed on GitHub. Done?" : "Reopened on GitHub. Not done?")
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        HStack(spacing: 14) {
                            KeyHint("goal.mirror.yes", scope: "goals", label: ask.kind == .done ? "done" : "not done")
                            KeyHint(
                                "goal.mirror.no",
                                scope: "goals",
                                label: ask.kind == .done ? "keep open" : "keep done"
                            )
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
                }
            } else {
                Quiet("Not mirrored. Colleagues can follow the goal as a GitHub issue with a sub-issue per item, in a "
                    + "tracker repo of its own.")
            }
            KeyHint("goal.mirror", scope: "goals", label: state.on ? "stop mirroring" : "mirror")
            HStack(spacing: 14) {
                KeyHint("goal.tracker", scope: "goals", label: "tracker", color: Theme.fg2)
                if state.on { KeyHint("goal.mirror.sync", scope: "goals", label: "now", color: Theme.fg2) }
            }
        }
    }

    /// `synced 4m ago · 12 sub-issues`, what is left for the next sync, or what went wrong.
    static func status(_ state: GoalMirrorState) -> String {
        if let error = state.error { return "Last sync failed: \(error)" }
        guard state.on else {
            return state.meta == nil ? "Off: M mirrors it, then heed keeps it up to date on its own."
                : "Off: its issues stay as they were."
        }
        var parts: [String] = [state.syncedAt.map { "synced \(Clock.relative($0))" } ?? "not synced yet"]
        parts.append("\(state.items.count) sub-issue\(state.items.count == 1 ? "" : "s")")
        if state.pending > 0 { parts.append("\(state.pending) writes next sync") }
        return parts.joined(separator: " · ")
    }
}

/// An item's sub-issue number, on its matrix row and its card.
struct SubIssueNumber: View {
    let item: GoalItem

    var body: some View {
        if let number = item.issueNumber {
            Text("#\(number)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                .help("its sub-issue on GitHub")
        }
    }
}
