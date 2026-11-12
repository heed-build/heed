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

    /// A session: what it is, its PRs, issues and runs scroll; the anchored parts under them keep small caps of their
    /// own, so a long list never pushes them out of sight.
    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.currentSession, let chat = session.chat {
                chatSections(session, chat)
            } else if let session = model.currentSession {
                // What it is and its PRs and issues scroll; what was learned and left open around it, who else is in
                // the same files, and its agent stay anchored at the bottom, each in a small capped box.
                ListScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        section { summary(session) }
                        let links = model.links(of: session)
                        let pulls = links.filter { if case .pull = $0 { true } else { false } }
                        let issues = links.filter { if case .issue = $0 { true } else { false } }
                        section {
                            HStack {
                                SectionHeader(title: "Pull requests")
                                Spacer()
                                KeyCap(text: "gB")
                            }
                            if pulls.isEmpty { emptyLinks(session) }
                            ForEach(pulls, id: \.self) { link in linkRow(link, session: session) }
                        }
                        if !issues.isEmpty {
                            section {
                                SectionHeader(title: "Issues")
                                ForEach(issues, id: \.self) { link in linkRow(link, session: session) }
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
                                            .help(run
                                                .isRunning ? "Go to its tab" : "Open: what it did, and its last screen")
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
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                anchored(session)
            }
            Spacer(minLength: 0)
        }
    }

    /// What the session is about, where its work sits in the Mindmap, and its goal as a pill.
    @ViewBuilder private func summary(_ session: Session) -> some View {
        HStack {
            SectionHeader(title: "Summary")
            Spacer()
            CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
        }
        if let text = model.summary(of: session) {
            Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text("Nothing to say yet: a summary shows once its agent has finished a turn.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
        if let campaign = model.placement(of: session).flatMap({ SessionCampaign.of(entry: session.id, in: $0.tree) }) {
            HStack(spacing: 6) {
                Text(campaign.title).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                if let stage = campaign.stage {
                    Text(stage.rawValue).font(Theme.mono(10.5)).foregroundStyle(Sidebar.tint(stage))
                }
            }
            .help("Its campaign in the Mindmap")
        }
        if let goal = model.goals.bySession[session.id] {
            let target = CommandTarget.session(session.id)
            HStack(spacing: 7) {
                ScoreRing(score: goal.score, size: 18)
                Text(goal.title).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer(minLength: 0)
                Text("goal").font(Theme.mono(10)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg3))
            .contentShape(Rectangle())
            .clickRuns(CommandInvocation(name: "goal.jump", target: target))
            .help("Its goal: click to go there")
            .rightClickMenu { model.rightClickNamed() } _: {
                [
                    .header(goal.title),
                    .item(MenuItem("Go to the goal", CommandInvocation(name: "goal.jump", target: target))),
                    .item(MenuItem("Move to another goal", CommandInvocation(name: "goal.attach", target: target))),
                    .item(MenuItem("Take it off the goal", CommandInvocation(name: "goal.detach", target: target))),
                ]
            }
            .shotRegion(.inspectorGoal)
        }
    }

    /// A PR or an issue: a click opens it on GitHub; the right-click menu does the rest.
    private func linkRow(_ link: SessionLink, session: Session) -> some View {
        LinkCard(session: session, link: link)
            .contentShape(Rectangle())
            .onTapGesture { model.open(link, browser: true) }
            .help("\(link.url)\nClick opens it on GitHub; right-click for more")
            .rightClickMenu { model.rightClickNamed() } _: { menu(for: link) }
    }

    /// Learned decisions, loose ends, overlapping sessions, the agent's events and the worktree: each only when it has
    /// something, each capped small so together they never crowd out the PRs.
    @ViewBuilder private func anchored(_ session: Session) -> some View {
        let decisions = model.learnedDecisions(of: session)
        let loose = model.looseEnds(of: session)
        let overlaps = model.overlaps(of: session)
        VStack(alignment: .leading, spacing: 0) {
            if !decisions.isEmpty {
                anchoredSection {
                    HStack {
                        SectionHeader(title: "Learned decisions")
                        Spacer()
                        Text("\(decisions.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    }
                    CappedScroll(cap: Self.lines(3)) {
                        ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in decisionRow(decision) }
                    }
                }
            }
            if !loose.isEmpty {
                anchoredSection {
                    HStack {
                        SectionHeader(title: "Loose ends")
                        Spacer()
                        Text("Tackle all").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.fg)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                            .contentShape(Rectangle())
                            .onTapGesture { model.tackle(loose.map(\.item), in: session) }
                            .help("Hand every loose end to \(session.agent) in one prompt")
                    }
                    CappedScroll(cap: Self.lines(3)) {
                        ForEach(Array(loose.enumerated()), id: \.offset) { _, entry in
                            looseRow(entry.item, node: entry.node, session: session)
                        }
                    }
                }
            }
            if !overlaps.isEmpty {
                anchoredSection {
                    SectionHeader(title: "Overlapping sessions")
                    CappedScroll(cap: Self.lines(3)) {
                        ForEach(overlaps, id: \.session.id) { overlap in
                            overlapRow(overlap.session, files: overlap.files)
                        }
                    }
                }
            }
            anchoredSection { AgentEventsLine(session: session) }
            worktreeLines(session)
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    /// The height of `count` one-line rows in the anchored boxes.
    private static func lines(_ count: Int) -> CGFloat { CGFloat(count) * 22 }

    private func decisionRow(_ decision: MindNode.Decision) -> some View {
        HStack(spacing: 7) {
            Rectangle().fill(decision.pinned ? Theme.block.opacity(0.7) : Theme.line).frame(width: 2, height: 14)
            Text(decision.text).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
        }
        .frame(height: 22, alignment: .leading)
        .help(decision.text)
        .rightClickMenu { model.rightClickNamed() } _: {
            [.header("Decision"), .item(MenuItem("Open the Mindmap", CommandInvocation(name: "history.mindmap")))]
        }
    }

    private func looseRow(_ item: MindNode.OpenItem, node: String, session: Session) -> some View {
        HStack(spacing: 7) {
            Text(item.kind.rawValue).font(Theme.mono(9.5)).foregroundStyle(Theme.fg2)
                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Theme.chip))
                .fixedSize()
            Text(item.text).font(Theme.ui(12)).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.tail)
        }
        .frame(height: 22, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.tackle([item], in: session) }
        .help("\(item.text)\nClick hands it to \(session.agent); right-click to mark it done")
        .rightClickMenu { model.rightClickNamed() } _: {
            [
                .header(item.kind.rawValue),
                .item(MenuItem(
                    "Hand it to \(session.agent)", CommandInvocation(name: "inspector.tackle", arguments: [item.text])
                )),
                .item(MenuItem(
                    "Mark it done", CommandInvocation(name: "inspector.resolve", arguments: [node, item.text])
                )),
            ]
        }
    }

    private func overlapRow(_ other: Session, files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                StateGlyph(state: other.state.state, size: 9)
                Text(other.title).font(Theme.ui(12)).foregroundStyle(Theme.fg).lineLimit(1)
            }
            Text("same files · " + files.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.block.opacity(0.8)).lineLimit(1).padding(.leading, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(sessionID: other.id) }
        .help(files.joined(separator: "\n"))
        .rightClickMenu { model.rightClickNamed() } _: {
            [.header(other.title), .item(MenuItem(
                "Go to it", CommandInvocation(name: "session.open", arguments: [other.title])
            ))]
        }
    }

    /// Where it works, at the very bottom: a click copies the path; right-click opens a shell there.
    @ViewBuilder private func worktreeLines(_ session: Session) -> some View {
        let worktrees = Self.unique(model.worktrees.filter { session.owns($0) })
        if !worktrees.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(worktrees) { worktree in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                        Text(Paths.abbreviate(worktree.path)).font(Theme.mono(11)).foregroundStyle(Theme.fg2)
                            .lineLimit(1).truncationMode(.head)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        if let status = worktree.status {
                            // Just the counts: the branch is the session's, its upstream is in the tooltip.
                            Text("↑\(status.ahead) ↓\(status.behind) ~\(status.changedFiles + status.untrackedFiles)")
                                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).fixedSize()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.copyPath(worktree.path) }
                    .help(
                        "\(worktree.path)\(worktree.status?.upstream.map { "\n↥ \($0)" } ?? "")\n"
                            + "Click copies it; right-click opens a shell there"
                    )
                    .rightClickMenu { model.rightClickNamed() } _: {
                        [
                            .header(Paths.abbreviate(worktree.path)),
                            .item(MenuItem("Shell in a pane beside", CommandInvocation(name: "pane.split.right"))),
                            .item(MenuItem("Shell in a new tab", CommandInvocation(name: "tab.new"))),
                            .item(MenuItem(
                                "Copy the path", CommandInvocation(name: "inspector.copy", arguments: [worktree.path])
                            )),
                        ]
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
    }

    private func anchoredSection(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    /// A chat: its folder where a session's worktree would be, and its agent's events. No links: it has no branch for a
    /// PR to come from.
    @ViewBuilder private func chatSections(_ session: Session, _ chat: ChatFolder) -> some View {
        section {
            HStack {
                SectionHeader(title: "Chat")
                Spacer()
                CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ChatKindChip()
                    ChatFolderChip(chat: chat)
                    if let host = session.host { HostChip(location: .host(host)) }
                }
                Text(Paths.tilde(chat.path)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                    .lineLimit(1).truncationMode(.middle)
                    .help(chat.path)
                Text(chat.kind == .scratch
                    ? "An empty folder heed made for this chat. No repo, no branch."
                    : "A folder you picked. No repo, no branch; heed never removes it.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        section { GoalCard(session: session) }.shotRegion(.inspectorGoal)
        section {
            SectionHeader(title: "Agent events")
            UsageLine(session: session)
            let log = model.events[session.id] ?? []
            if log.isEmpty {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                    Text(session.state.state.rawValue).foregroundStyle(Theme.fg)
                    Text(session.state.reason ?? "").foregroundStyle(Theme.fg3).lineLimit(1)
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

/// The goal the session is on: what it is, how far along, and the keys to go there, move it or take it off; with
/// none, the ways to put it on one.
struct GoalCard: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let target = CommandTarget.session(session.id)
        if let goal = model.goals.bySession[session.id] {
            HStack {
                SectionHeader(title: "Goal")
                Spacer()
                KeyHint("goal.jump", target: target, label: "go there")
            }
            HStack(alignment: .top, spacing: 10) {
                ScoreRing(score: goal.score, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title).font(Theme.ui(13, weight: .semibold)).lineLimit(2)
                    let doc = model.goals.snapshot.docs[goal.id]
                    if let summary = doc?.summary, !summary.isEmpty {
                        Text(summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2).lineLimit(2)
                    }
                    let met = doc?.criteriaMet ?? (met: 0, total: 0)
                    Text(([
                        met.total > 0 ? "\(met.met)/\(met.total) criteria met" : nil,
                        "GOAL.md v\(goal.version)",
                        goal.status == .active ? nil : goal.status.rawValue,
                    ] as [String?])
                        .compactMap(\.self).joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
            }
            .contentShape(Rectangle())
            .clickRuns(CommandInvocation(name: "goal.jump", target: target))
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("goal.attach", target: target, label: "move")
                // Its x is Goals' own; here x closes the session.
                KeyHint("goal.detach", target: target, key: ":goal.detach", label: "take off")
            }
        } else {
            SectionHeader(title: "Goal")
            Text("On no goal. Agents on a goal read its GOAL.md first.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("goal.attach", target: target, label: "put on a goal")
                KeyHint("goal.new", target: target, label: "new goal from it")
            }
        }
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
            // Coloured like the session row's pending chips: unpushed commits amber, uncommitted files bright.
            Text("↑\(status.ahead)").foregroundStyle(status.ahead > 0 ? Theme.block : Theme.fg3)
            Text("↓\(status.behind)").foregroundStyle(status.behind > 0 ? Theme.busy : Theme.fg3)
            Text("~\(status.changedFiles + status.untrackedFiles)")
                .foregroundStyle(status.isDirty ? Theme.fg : Theme.fg3)
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
                Text(pull == nil && watching ? "waiting for the next sync" : model.pilotLine(
                    for: ref,
                    mentionsRun: false
                ))
                .foregroundStyle(watching ? Theme.fg2 : Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(11))
            if let swarm = model.swarmPulls[ref.description] { SwarmPullLine(pull: swarm) }
            PilotGreenLine(ref: ref)
            PilotPlanLine(ref: ref)
            PilotMergeLine(ref: ref)
        }
        if let run = model.workingRun(for: ref) {
            RunCardBox(
                run: run,
                round: model.round(of: run),
                lastLine: model.lastLine(of: run),
                key: model.keyText(for: "pilot.run")
            )
            .contentShape(Rectangle())
            // Its tab, not the PR overlay the rest of the card opens.
            .onTapGesture { model.open(run: run) }
            .help("Go to the run's tab")
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

/// A run working on a PR, on its card: who, which round, how long and the key to its tab, then the last line of its
/// screen.
struct RunCardBox: View {
    let run: PilotRun
    let round: Int?
    let lastLine: String?
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StateGlyph(state: .working, size: 10)
                // A long model name gives way first: the round and how long always show.
                Text(verbatim: "run · \(run.model.map { "\(run.agent) \($0)" } ?? run.agent)")
                    .foregroundStyle(Theme.busy)
                    .lineLimit(1)
                    .truncationMode(.tail)
                TimelineView(.periodic(from: run.startedAt, by: 30)) { _ in
                    Text(verbatim: ([round.map { "round \($0)" }, RunRow.duration(run)].compactMap(\.self))
                        .map { "· \($0)" }.joined(separator: " "))
                        .foregroundStyle(Theme.busy)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                KeyCap(text: key)
            }
            if let lastLine {
                Text(verbatim: "› \(lastLine)").foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 16)
            }
        }
        .font(Theme.mono(11))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.busy.opacity(0.08)))
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

/// The agent's latest event on one line; a click opens the rest (up to eight).
private struct AgentEventsLine: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var open = false

    var body: some View {
        let log = model.events[session.id] ?? []
        VStack(alignment: .leading, spacing: 5) {
            let subagents = model.liveSubagents(of: session)
            HStack {
                SectionHeader(title: "Agent events")
                if !subagents.isEmpty {
                    Text("· \(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .help(subagents.map { $0.type ?? "subagent" }.joined(separator: ", "))
                }
                Spacer()
                if log.count > 1 {
                    Text("\(log.count) \(open ? "▾" : "▸")").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                UsageLine(session: session)
                ForEach(subagents) { subagent in
                    HStack(spacing: 8) {
                        StateGlyph(state: .working)
                        Text(subagent.type ?? "subagent").foregroundStyle(Theme.fg).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Ages.short(subagent.startedAt)).foregroundStyle(Theme.fg3)
                    }
                    .font(Theme.mono(11))
                }
            }
            if let first = log.first {
                ForEach(Array(log.prefix(open ? 8 : 1).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 8) {
                        StateGlyph(state: event.state)
                        Text(event.state.rawValue).foregroundStyle(Theme.fg)
                        Text(event.reason ?? "").foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(event.at, format: .dateTime.hour().minute()).foregroundStyle(Theme.fg3)
                    }
                    .font(Theme.mono(11))
                }
                .id(first.at)
            } else {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                    Text(session.state.state.rawValue).foregroundStyle(Theme.fg)
                    Text(session.state.reason ?? (session.state.source == .guessed ? "not reported yet" : ""))
                        .foregroundStyle(Theme.fg3).lineLimit(1)
                }
                .font(Theme.mono(11))
            }
        }
    }
}
