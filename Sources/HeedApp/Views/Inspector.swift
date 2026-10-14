import HeedCore
import SwiftUI

/// The right column: the session's worktree, its PRs, and the agent's hook events.
struct Inspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.currentSession {
                section {
                    HStack {
                        SectionHeader(title: "Worktree")
                        Spacer()
                        CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
                    }
                    ForEach(model.worktrees
                        .filter { session.owns($0) })
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
                        KeyCap(text: "go")
                    }
                    if session.trackedPRs.isEmpty {
                        Text("No PR yet. Tracked by branch name, or `heed pr add <url>` from the agent.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.fg3)
                    }
                    ForEach(session.trackedPRs, id: \.self) { ref in
                        let pull = model.github.pull(ref)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5))
                                    .foregroundStyle(Theme.fg2)
                                Spacer()
                                if let pull { StateTag(state: pull.state, draft: pull.isDraft) }
                            }
                            Text(pull?.title ?? session.title).font(Theme.ui(13, weight: .medium)).lineLimit(2)
                            if let pull {
                                HStack(spacing: 8) {
                                    CheckBar(checks: pull.checks)
                                    Text(pull.checks.text)
                                        .foregroundStyle(pull.checks.failed > 0 ? Theme.err : Theme.fg2)
                                    Text("· \(pull.review?.text ?? "no review")").foregroundStyle(Theme.fg3)
                                }
                                .font(Theme.ui(11.5))
                                .lineLimit(1)
                            }
                            // What the pilot is doing for this PR, from its real state (this said "watching" always).
                            let watching = model.pilot(for: ref).watching
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                PilotMark(status: model.pilotStatus(for: ref), compact: true)
                                Text(pull == nil && watching ? "waiting for the next sync" : model.pilotLine(for: ref))
                                    .foregroundStyle(watching ? Theme.fg2 : Theme.fg3)
                                    .fixedSize(horizontal: false, vertical: true)
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
                    let log = model.events[session.id] ?? []
                    if log.isEmpty {
                        HStack(spacing: 8) {
                            StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                            Text(session.state.state.rawValue).foregroundStyle(Theme.fg)
                            Text(session.state.reason ?? (session.state.source == .guessed ? "not reported yet" : ""))
                                .foregroundStyle(Theme.fg3)
                                .lineLimit(1)
                        }
                        .font(Theme.mono(11))
                    }
                    ForEach(Array(log.prefix(8).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Text(event.at, format: .dateTime.hour().minute().second()).foregroundStyle(Theme.fg3)
                            StateGlyph(state: event.state)
                            Text(event.state.rawValue).foregroundStyle(Theme.fg)
                            Text(event.reason ?? "").foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
                        }
                        .font(Theme.mono(11))
                    }
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

/// `open`, `draft`, `merged`, `closed`.
struct StateTag: View {
    let state: PullRequest.State
    let draft: Bool

    var body: some View {
        let (text, tint): (String, Color) = switch state {
        case .open: draft ? ("draft", Theme.fg2) : ("open", Theme.done)
        case .merged: ("merged", Theme.ask)
        case .closed: ("closed", Theme.err)
        }
        Text(text)
            .font(Theme.mono(10.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
    }
}
