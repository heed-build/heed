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
                        SectionHeader(title: "Links")
                        Spacer()
                        KeyCap(text: "gB")
                    }
                    let links = model.links(of: session)
                    if links.isEmpty { emptyLinks(session) }
                    ForEach(links, id: \.self) { link in
                        LinkCard(session: session, link: link)
                            .contentShape(Rectangle())
                            // A click opens it here (the PR overlay, the issue reader); ⌘-click on GitHub.
                            .onTapGesture {
                                model.open(link, browser: NSEvent.modifierFlags.contains(.command))
                            }
                            .help("\(link.url)\n⌘-click opens it on GitHub")
                    }
                }
                let runs = Array(model.runs.filter { $0.sessionID == session.id }.prefix(10))
                if !runs.isEmpty {
                    section {
                        SectionHeader(title: "Runs")
                        ForEach(runs) { run in
                            RunRow(run: run)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(run: run) }
                                .help(run.isRunning ? "Go to its tab" : "Open: what it did, and its last screen")
                        }
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

    /// No PR and no issue yet: what comes next. A pushed branch offers the compare page that opens a PR.
    @ViewBuilder private func emptyLinks(_ session: Session) -> some View {
        let pushed = model.worktrees.contains { session.owns($0) && $0.status?.upstream != nil }
        if pushed, let repo = session.repos.first {
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch pushed, no PR yet.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                Text("Open a PR on GitHub ↗")
                    .font(Theme.ui(11.5, weight: .medium))
                    .foregroundStyle(Theme.busy)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = URL(string: IssueLinks.compareURL(repo: repo, branch: session.branch)) {
                            NSWorkspace.shared.open(url)
                        }
                    }
            }
        } else {
            Text("No PR or issue yet. PRs are found by branch name, or `heed pr add <url>` from the agent; issues by "
                + "the prompt's \"Closes #12\", or `heed issue add <url>`.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// One of a session's links in the inspector: a PR (its state, checks, review and what heed is doing about it) or an
/// issue (its title and state).
private struct LinkCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let link: SessionLink

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch link {
            case let .pull(ref): pull(ref)
            case let .issue(ref): issue(ref)
            case let .repo(repo): Text(repo.slug).font(Theme.mono(11.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
    }

    @ViewBuilder private func pull(_ ref: PullRef) -> some View {
        let pull = model.github.pull(ref)
        HStack {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
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
        // What the pilot is doing for this PR; a merged or closed one is done.
        let watching = model.pilot(for: ref).watching
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PilotMark(status: model.pilotStatus(for: ref), compact: true)
            Text(pull == nil && watching ? "waiting for the next sync" : model.pilotLine(for: ref))
                .foregroundStyle(watching && pull?.state == .open ? Theme.fg2 : Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.mono(11))
    }

    @ViewBuilder private func issue(_ ref: IssueRef) -> some View {
        let info = model.issueInfo[ref]
        let known = model.issue(for: ref)
        HStack {
            Image(systemName: "smallcircle.filled.circle").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            Spacer()
            if let info {
                let (text, tint) = info.closed ? ("closed", Theme.ask) : ("open", Theme.done)
                Text(text)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
            }
        }
        Text(known?.title ?? "issue \(ref.repo.slug)#\(ref.number)")
            .font(Theme.ui(13, weight: .medium))
            .foregroundStyle(known == nil ? Theme.fg3 : Theme.fg)
            .lineLimit(2)
    }
}

/// One get it green / get it merged run in the inspector: what, with which agent, how long, how it went.
struct RunRow: View {
    let run: PilotRun

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if run.isRunning {
                StateGlyph(state: .working, size: 11).padding(.top, 2)
            } else {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 11).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(run.goal.rawValue) #\(run.ref.number)").font(Theme.mono(11.5))
                    .foregroundStyle(Theme.fg)
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(run.isRunning ? Theme.busy : tint).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(Clock.relative(run.startedAt)).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
        }
    }

    static func duration(_ run: PilotRun) -> String {
        PilotDuration.text((run.endedAt ?? Clock.now).timeIntervalSince(run.startedAt))
    }

    private var detail: String {
        let who = run.model.map { "\(run.agent) \($0)" } ?? run.agent
        let how = run.isRunning ? "working" : run.outcome?.text ?? "ended"
        return "\(who) · \(Self.duration(run)) · \(how)"
    }

    private var tint: Color {
        switch run.outcome {
        case .pushed: Theme.done
        case .noChanges, nil: Theme.fg3
        case .timedOut, .failed: Theme.err
        case .stopped, .interrupted: Theme.block
        }
    }

    private var icon: String {
        switch run.outcome {
        case .pushed: "arrow.up"
        case .noChanges, nil: "minus"
        case .timedOut: "clock"
        case .failed: "xmark"
        case .stopped, .interrupted: "stop.fill"
        }
    }
}

/// A run that ended, read: its PR, agent, how it went, and the last lines of its screen.
struct RunReaderView: View {
    @Environment(AppModel.self) private var model
    let run: PilotRun

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).onTapGesture { model.runReader = nil }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: "\(run.goal.rawValue) · \(run.ref.repo.name) #\(run.ref.number)")
                        .font(Theme.ui(15, weight: .semibold))
                    Spacer()
                    KeyCap(text: "esc")
                }
                RunRow(run: run)
                VStack(alignment: .leading, spacing: 3) {
                    line("Branch", run.branch.isEmpty ? "none" : run.branch)
                    line("Pushed to", run.prBranch.isEmpty ? "none" : run.prBranch)
                    line("Sent", "\(run.items) feedback item\(run.items == 1 ? "" : "s")")
                    line("Started", Clock.relative(run.startedAt, named: true))
                }
                Text("Last screen").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.fg2)
                // At most 40 lines are kept: they fit without scrolling.
                Text(run.screen?.isEmpty == false ? run.screen! : "Nothing was kept.")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(run.screen == nil ? Theme.fg3 : Theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            }
            .padding(20)
            .frame(width: 640, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg3).frame(width: 80, alignment: .leading)
            Text(value).font(Theme.mono(12))
        }
    }
}
