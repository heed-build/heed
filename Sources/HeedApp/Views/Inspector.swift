import HeedCore
import SwiftUI

/// The right column: the session's worktree, its PRs, and the agent's hook events.
struct Inspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.currentSession {
                section {
                    SectionHeader(title: "Worktree")
                    ForEach(model.worktrees
                        .filter { $0.branch == session.branch && session.repos.contains($0.repo) })
                    { worktree in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Paths.abbreviate(worktree.path)).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                            if let status = worktree.status { WorktreeStatusLine(status: status) }
                        }
                    }
                }
                section {
                    HStack {
                        SectionHeader(title: "Pull requests")
                        Spacer()
                        KeyCap(text: "gp")
                    }
                    if session.trackedPRs.isEmpty {
                        Text("No PR yet. Tracked by branch name, or `heed pr add <url>` from the agent.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.fg3)
                    }
                    ForEach(Array(zip(session.trackedPRs, session.repos + session.repos)), id: \.0) { number, repo in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: "\(repo.name) #\(number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                            Text(session.title).font(Theme.ui(13, weight: .medium))
                            HStack(spacing: 4) {
                                Circle().fill(Theme.busy).frame(width: 6, height: 6)
                                Text("watching · ask").foregroundStyle(Theme.busy)
                            }
                            .font(Theme.mono(11))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
                    }
                }
                section {
                    SectionHeader(title: "Agent events")
                    HStack(spacing: 8) {
                        StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                        Text(session.state.state.rawValue).foregroundStyle(Theme.fg)
                        Text(session.state.reason ?? (session.state.source == .guessed ? "from output" : ""))
                            .foregroundStyle(Theme.fg3)
                    }
                    .font(Theme.mono(11))
                }
            }
            Spacer()
        }
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// `base main ↑3 ↓0 ~2`: ahead, behind, changed.
struct WorktreeStatusLine: View {
    let status: WorktreeStatus
    var showUpstream = true

    var body: some View {
        HStack(spacing: 8) {
            if showUpstream {
                Text(status.upstream.map { "↥ \($0)" } ?? "no upstream").foregroundStyle(Theme.fg3).lineLimit(1)
            } else if status.upstream == nil {
                Text("local").foregroundStyle(Theme.block)
            }
            Text("↑\(status.ahead)").foregroundStyle(status.ahead > 0 ? Theme.done : Theme.fg3)
            Text("↓\(status.behind)").foregroundStyle(status.behind > 0 ? Theme.busy : Theme.fg3)
            Text("~\(status.changedFiles + status.untrackedFiles)")
                .foregroundStyle(status.isDirty ? Theme.block : Theme.fg3)
        }
        .font(Theme.mono(11.5))
    }
}
