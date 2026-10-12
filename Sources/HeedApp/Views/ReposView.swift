import HeedCore
import SwiftUI

/// Repos & worktrees (design/screens/Repos.png): repos on the left, every added worktree in a table, cleanup rules on
/// the right.
struct ReposView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                repoColumn
                table
                // The rules panel gives way first when the window is narrow; `gi` hides it outright.
                if model.inspectorVisible, geometry.size.width >= 1240 { rules }
            }
        }
    }

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Repos").padding(.horizontal, 16).padding(.vertical, 14)
            row(name: "All", count: model.worktreeRows.count, repo: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.repos) { record in
                        row(
                            name: record.repo.name,
                            count: model.worktreeRows.count { $0.repo == record.repo },
                            repo: record.repo
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                keyRow("a", "add repo (rescan roots)")
                keyRow("R", "rescan")
                keyRow("n", "new worktree")
            }
            .padding(16)
        }
        .frame(width: 220)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func row(name: String, count: Int, repo: Repo?) -> some View {
        HStack(spacing: 8) {
            if let repo {
                Text(String(repo.org.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(repo.color.foreground))
            }
            Text(name).font(Theme.mono(12.5)).foregroundStyle(repo == nil ? Theme.fg : Theme.fg2)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(repo == nil ? Theme.bg3 : .clear)
    }

    private func keyRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            KeyCap(text: key)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }

    private var table: some View {
        let rows = model.worktreeRows
        let selected = model.selectedRows
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, worktree in
                            WorktreeRow(
                                worktree: worktree,
                                session: model.session(for: worktree),
                                number: index == model.repoCursor ? index + 1 : abs(index - model.repoCursor),
                                isCursor: index == model.repoCursor,
                                isSelected: selected.contains(worktree.id)
                            )
                            .id(worktree.id)
                        }
                    }
                }
                .onChange(of: model.repoCursor) {
                    if rows.indices.contains(model.repoCursor) { proxy.scrollTo(rows[model.repoCursor].id) }
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(model.repos.isEmpty ? "No repos found yet." : "No worktrees yet.")
                        .foregroundStyle(Theme.fg2)
                    Text(model.repos.isEmpty
                        ? "Scanning \(model.settings.repoRoots.joined(separator: ", ")) for repositories."
                        : "Start work (o) creates one under \(model.settings.worktreeRoot).")
                        .foregroundStyle(Theme.fg3)
                }
                .font(Theme.ui(12.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 64)
            Group {
                Text("REPO").frame(width: 140, alignment: .leading)
                Text("BRANCH").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                Text("AGENT").frame(width: 90, alignment: .leading)
                Text("STATUS").frame(width: 120, alignment: .leading)
                Text("PR").frame(width: 70, alignment: .leading)
            }
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.fg3)
        }
        .padding(.trailing, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "Auto cleanup rules")
                Spacer()
                KeyCap(text: "gi")
            }
            ruleRow(
                "Remove worktrees with no activity",
                "Nothing for 14d: no agent output, keystrokes, commits or PR events."
            )
            ruleRow("Never remove dirty or unpushed work", "Always on. Skipped trees show a warning instead.")
            ruleRow("Delete the local branch too", "Remote branch is left alone.")
            Text("The sweep itself arrives in step 9; rules come from config.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
            HStack(spacing: 8) {
                KeyCap(text: "p")
                Text("pinned sessions are never cleaned up").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func ruleRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.ui(13, weight: .medium))
            Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let session: Session?
    let number: Int
    let isCursor: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 30, alignment: .trailing)
            Group {
                if let session {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                } else {
                    StateGlyph(state: .idle)
                }
            }
            .frame(width: 34)
            RepoChip(repo: worktree.repo).frame(width: 140, alignment: .leading)
            Text(worktree.branch ?? "detached \(worktree.head)")
                .font(Theme.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text(session?.agent ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.fg2).frame(
                width: 90,
                alignment: .leading
            )
            Group {
                if let status = worktree.status {
                    WorktreeStatusLine(status: status, showUpstream: false)
                } else {
                    Text("…").foregroundStyle(Theme.fg3)
                }
            }
            .frame(width: 120, alignment: .leading)
            Text(session?.trackedPRs.first.map { "#\(String($0))" } ?? "no PR")
                .font(Theme.mono(12))
                .foregroundStyle(session?.trackedPRs.isEmpty == false ? Theme.fg : Theme.fg3)
                .frame(width: 70, alignment: .leading)
        }
        .padding(.trailing, 16)
        .frame(height: 42)
        .background(isSelected ? Theme.block.opacity(0.18) : isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }
}
