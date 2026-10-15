import HeedCore
import SwiftUI

/// The right column: the session's worktree, its PRs, and the agent's hook events.
struct Inspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            content(height: proxy.size.height)
        }
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    /// Worktrees, links and runs each scroll on their own, up to a share of the column, so a long list in one never
    /// pushes the others out of sight.
    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.currentSession {
                section {
                    HStack {
                        SectionHeader(title: "Worktree")
                        Spacer()
                        CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
                    }
                    CappedScroll(cap: height * 0.18) {
                        // Once per path (the same worktree can be listed under two repos, e.g. a fork's clone), each
                        // led by its repo: a cross-repo session's worktrees often share their folder name.
                        ForEach(Self.unique(model.worktrees.filter { session.owns($0) })) { worktree in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    RepoChip(repo: worktree.repo)
                                    if let host = worktree.location.hostName { HostChip(location: .host(host)) }
                                }
                                Text(Paths.abbreviate(worktree.path)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(worktree.path)
                                if let status = worktree.status { WorktreeStatusLine(status: status) }
                            }
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
                    CappedScroll(cap: height * 0.45) {
                        // PRs and issues apart: each under its own heading, PRs as cards, issues as rows.
                        let pulls = links.filter { if case .pull = $0 { true } else { false } }
                        let issues = links.filter { if case .issue = $0 { true } else { false } }
                        ForEach([("Pull requests", pulls), ("Issues", issues)], id: \.0) { group in
                            if !group.1.isEmpty {
                                Text("\(group.0) · \(group.1.count)").font(Theme.ui(11, weight: .semibold))
                                    .foregroundStyle(Theme.fg3)
                                    .padding(.top, group.0 == "Issues" && !pulls.isEmpty ? 6 : 0)
                                ForEach(group.1, id: \.self) { link in
                                    LinkCard(session: session, link: link)
                                        .contentShape(Rectangle())
                                        // A click opens it here (the PR overlay, the issue reader); ⌘-click on GitHub.
                                        .onTapGesture {
                                            model.open(link, browser: NSEvent.modifierFlags.contains(.command))
                                        }
                                        .help("\(link.url)\n⌘-click opens it on GitHub")
                                        .rightClickMenu { model.rightClickNamed() } _: { menu(for: link) }
                                }
                            }
                        }
                    }
                }
                let runs = Array(model.runs.filter { $0.sessionID == session.id }.prefix(10))
                if !runs.isEmpty {
                    section {
                        SectionHeader(title: "Runs")
                        CappedScroll(cap: height * 0.22) {
                            ForEach(runs) { run in
                                RunRow(run: run)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.open(run: run) }
                                    .help(run.isRunning ? "Go to its tab" : "Open: what it did, and its last screen")
                                    .rightClickMenu { model.rightClickNamed() } _: { model.runMenu(run) }
                            }
                        }
                    }
                }
                if !session.notes.isEmpty {
                    // Notes on its diff before it has a PR: the PR overlay's last tab sends them.
                    section {
                        HStack {
                            SectionHeader(title: "Your notes")
                            Spacer()
                            let queued = session.notes.count { $0.status == .queued }
                            if queued > 0 {
                                Text("\(queued) queued").font(Theme.mono(11)).foregroundStyle(Theme.block)
                            }
                            KeyCap(text: model.keyText(for: "overlay.item"))
                        }
                        ForEach(session.notes.suffix(4)) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.noteLocation ?? "").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                                    .lineLimit(1).truncationMode(.head)
                                Text(note.text).font(Theme.ui(12))
                                    .foregroundStyle(note.status == .queued ? Theme.fg : Theme.fg3).lineLimit(2)
                            }
                        }
                    }
                }
                section {
                    SectionHeader(title: "Agent events")
                    UsageLine(session: session)
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
            Spacer(minLength: 0)
        }
    }

    /// A PR card's menu acts on that PR alone; an issue's on that issue.
    private func menu(for link: SessionLink) -> [MenuEntry] {
        switch link {
        case let .pull(ref): model.pullMenu(ref, place: .inspector)
        case let .issue(ref): ContextMenus.issue(ref)
        case .repo: []
        }
    }

    /// Worktrees once per place (path and host), the first listed kept.
    static func unique(_ worktrees: [Worktree]) -> [Worktree] {
        var seen: Set<String> = []
        return worktrees.filter { seen.insert("\($0.location.label)\u{0}\($0.path)").inserted }
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
        switch link {
        case let .pull(ref):
            VStack(alignment: .leading, spacing: 5) { pull(ref) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
        case let .issue(ref):
            issue(ref).frame(maxWidth: .infinity, alignment: .leading)
        case let .repo(repo):
            Text(repo.slug).font(Theme.mono(11.5))
        }
    }

    /// GitHub's colours: open green, merged purple, closed red.
    static func pullTint(_ pull: PullRequest?) -> Color {
        switch pull?.state {
        case .open: pull?.isDraft == true ? Theme.fg3 : Theme.done
        case .merged: Theme.ask
        case .closed: Theme.err
        case nil: Theme.fg3
        }
    }

    @ViewBuilder private func pull(_ ref: PullRef) -> some View {
        let pull = model.github.pull(ref)
        HStack {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.pullTint(pull))
            Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            Spacer()
            if let pull { StateTag(state: pull.state, draft: pull.isDraft) }
        }
        // Merged or closed: done, so just what it was.
        let finished = pull.map { $0.state != .open } ?? false
        Text(pull?.title ?? session.title).font(Theme.ui(13, weight: .medium)).lineLimit(finished ? 1 : 2)
            .foregroundStyle(finished ? Theme.fg2 : Theme.fg)
        if finished { EmptyView() } else if let pull {
            // The bar takes the card's width; the summary and the review read underneath it.
            CheckBar(checks: pull.checks).padding(.top, 2)
            (CheckText.text(pull.checks)
                + Text(verbatim: " · \(pull.review?.text ?? "no review")").foregroundStyle(Theme.fg3))
                .font(Theme.ui(11.5))
                .lineLimit(1)
        }
        // What the pilot is doing for this PR (nothing to say once it is merged or closed).
        if !finished {
            let watching = model.pilot(for: ref).watching
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PilotMark(status: model.pilotStatus(for: ref), compact: true)
                Text(pull == nil && watching ? "waiting for the next sync" : model.pilotLine(for: ref))
                    .foregroundStyle(watching ? Theme.fg2 : Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(11))
            PilotPlanLine(ref: ref)
        }
    }

    /// An issue: one light row (no card), so it never reads as a PR. Its icon is green while open, purple once closed.
    @ViewBuilder private func issue(_ ref: IssueRef) -> some View {
        let info = model.issueInfo[ref]
        let known = model.issue(for: ref)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: info?.closed == true ? "checkmark.circle" : "smallcircle.filled.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(info == nil ? Theme.fg3 : info!.closed ? Theme.ask : Theme.done)
            // The repo only when it is not the session's own.
            Text(verbatim: ref.repo == session.repos.first ? "#\(ref.number)" : "\(ref.repo.name)#\(ref.number)")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).fixedSize()
            Text(known?.title ?? ref.repo.slug)
                .font(Theme.ui(12.5))
                .foregroundStyle(known == nil ? Theme.fg3 : info?.closed == true ? Theme.fg2 : Theme.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .help("\(ref.repo.slug)#\(ref.number)")
    }
}

/// `claude · model-a · 12.3k in / 4.1k out · ≈$0.42 · ctx 38%`: the agent's model and what it used, as far as its
/// hooks told; while rate limited, when the limit lifts.
private struct UsageLine: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let usage = session.usage ?? AgentUsage()
        let resets = session.state.state == .limited ? usage.resetText(now: Clock.now) : nil
        if session.usage != nil || resets != nil {
            let summary = usage.summary(cost: model.config.usage.cost(of: usage))
            HStack(spacing: 0) {
                Text(([session.agent] + (summary.isEmpty ? [] : [summary])).joined(separator: " · "))
                    .foregroundStyle(Theme.fg2)
                if let resets { Text(" · \(resets)").foregroundStyle(Theme.block) }
            }
            .font(Theme.mono(11))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(Self.detail(usage, reported: usage.costUSD != nil))
        }
    }

    /// The tooltip: where the numbers come from.
    static func detail(_ usage: AgentUsage, reported: Bool) -> String {
        let tokens = usage.tokens
        return [
            "Input \(AgentUsage.count(tokens.allInput)): \(AgentUsage.count(tokens.input)) new, "
                +
                "\(AgentUsage.count(tokens.cacheRead)) cache read, \(AgentUsage.count(tokens.cacheWrite)) cache write",
            "Output \(AgentUsage.count(tokens.output))",
            reported ? "≈ cost as the agent reported it" : "≈ cost estimated from [usage.prices]",
        ].joined(separator: "\n")
    }
}

/// One get it green / get it merged run in the inspector: what, with which agent, how long, how it went.
struct RunRow: View {
    @Environment(AppModel.self) private var model
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
                if !used.isEmpty { Text(used).font(Theme.ui(11)).foregroundStyle(Theme.fg3).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Text(Clock.relative(run.startedAt)).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
        }
    }

    static func duration(_ run: PilotRun) -> String {
        PilotDuration.text((run.endedAt ?? Clock.now).timeIntervalSince(run.startedAt))
    }

    private var detail: String {
        let how = run.isRunning ? "working" : run.outcome?.text ?? "ended"
        return "\(Self.who(run)) · \(Self.duration(run)) · \(how)"
    }

    /// Its tokens and cost, as its agent's hooks reported them.
    private var used: String {
        run.usage.map { $0.summary(cost: model.config.usage.cost(of: $0), includeModel: false) } ?? ""
    }

    /// `codex model-a`, and the model it actually ran when that is another (or the only one known).
    static func who(_ run: PilotRun) -> String {
        let ran = run.usage?.model
        switch (run.model, ran) {
        case let (asked?, ran?) where ran != asked && !ran.hasPrefix(asked): return "\(run.agent) \(asked) (ran \(ran))"
        case let (asked?, _): return "\(run.agent) \(asked)"
        case let (nil, ran?): return "\(run.agent) \(ran)"
        case (nil, nil): return run.agent
        }
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

/// A list that takes the height of its content, up to `cap`, and scrolls beyond it.
struct CappedScroll<Content: View>: View {
    let cap: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 10) { content }
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
                })
        }
        .frame(height: min(max(height, 1), max(cap, 60)), alignment: .top)
        .clipped()
        .onPreferenceChange(ContentHeight.self) { height = $0 }
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
