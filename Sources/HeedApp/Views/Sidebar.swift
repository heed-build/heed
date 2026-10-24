import HeedCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var width: CGFloat = 330

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "Sessions")
                Spacer()
                CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                FilterPill(view: .sessions)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if model.sessions.isEmpty {
                // Centred where the sessions would be, rather than under an empty list.
                EmptyState(
                    title: "No sessions yet",
                    detail: "A session is one task: a prompt, a worktree, an agent and its PRs. A chat is an agent "
                        + "with no repo.",
                    actions: [.init("start work from a prompt", "work.start"), .init("new chat", "chat.new")],
                    pointer: .init("Take the tour", "tutor", arguments: ["tour"]),
                    pointerText: "New to heed?"
                )
            } else {
                sessionList(list)
            }
            Theme.line.frame(height: 1)
            HStack {
                Text("\(model.repos.count) repos · \(model.worktreeCount) worktrees").foregroundStyle(Theme.fg2)
                Spacer()
                KeyCap(text: "gr")
            }
            .font(Theme.ui(12))
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
        .frame(width: width)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func sessionList(_ list: SessionList) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ListScroll {
                    ListStack(alignment: .leading, spacing: 0) {
                        ForEach(list.sections, id: \.group) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                groupHeader(section, pins: list.pins.count)
                                ForEach(section.sessions) { session in
                                    let index = list.ordered.firstIndex(of: session) ?? 0
                                    SessionRow(
                                        session: session,
                                        number: list.lineNumber(of: index, cursor: model.cursor),
                                        isCursor: index == model.cursor,
                                        pinNumber: list.pins.firstIndex(of: session).map { $0 + 1 },
                                        hint: model.hintLabel(for: .session(session.id)),
                                        pilot: model.pilotStatus(of: session),
                                        readyToMerge: session.trackedPRs.contains(where: model.readyToMerge),
                                        group: section.group,
                                        label: Self.showsLabel(section.group, model.sessionPilot(session))
                                            ? model.watchLabel(of: session) : nil,
                                        hostColor: session.host.flatMap { model.config.hosts[$0]?.color },
                                        hostLink: session.host.map { model.hostStatus($0) },
                                        subagents: model.liveSubagents(of: session).count,
                                        pending: model.pendingChanges(of: session)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.clickSession(session.id) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        model.clickSession(session.id, insert: true)
                                    })
                                    .rightClickMenu { model.rightClickSession(session.id) } _: {
                                        model.sessionMenu(session.id)
                                    }
                                    .id(session.id)
                                    // A get it green / get it merged run working for it, under it in any group.
                                    if let run = model.workingRun(for: session) {
                                        RunChildRow(run: run, lastLine: model.lastLine(of: run))
                                            .contentShape(Rectangle())
                                            .onTapGesture { model.open(run: run) }
                                            .help("Go to the run's tab")
                                    }
                                }
                            }
                            // The tutor lights this group when it is about what needs you.
                            .shotRegion(section.group == .needsYou ? .needsYou : nil)
                        }
                    }
                }
                .onChange(of: model.cursor) {
                    if let id = model.currentSession?.id { proxy.scrollTo(id) }
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Heed's label: in Watching and Stalled instead of the agent's line; on a pinned session whenever heed acts on
    /// its PRs or one is stalled, under the agent's line (a pinned session never moves, so yours or not does not
    /// matter there).
    static func showsLabel(_ group: SessionGroup, _ pilot: SessionPilot) -> Bool {
        switch group {
        case .watching, .stalled: true
        case .pinned:
            if case .stalled = pilot.status { true } else { pilot.acting }
        case .needsYou, .working, .chats, .parked: false
        }
    }

    /// Needs you in amber, Stalled in red, Watching in heed's working blue; the rest quiet.
    static func tint(_ group: SessionGroup) -> Color {
        switch group {
        case .needsYou: Theme.block
        case .stalled: Theme.err
        case .watching: Theme.busy
        case .pinned, .working, .chats, .parked: Theme.fg3
        }
    }

    private func groupHeader(_ section: SessionList.Section, pins: Int) -> some View {
        HStack(spacing: 6) {
            if section.group == .pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.fg3)
            }
            let count = section.group == .pinned ? "\(pins)/\(SessionGroup.maxPins)" : "\(section.sessions.count)"
            SectionHeader(
                title: "\(section.group.rawValue) · \(count)",
                tint: Self.tint(section.group)
            )
            if section.group == .chats {
                Text("no repo, no worktree").font(Theme.ui(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer()
            if section.group == .pinned { KeyCap(text: "'") }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct SessionRow: View {
    let session: Session
    let number: Int
    let isCursor: Bool
    let pinNumber: Int?
    let hint: String?
    /// The most urgent pilot state among the session's PRs.
    var pilot: PilotStatus?
    /// One of its PRs meets every merge requirement while get it merged is off for it.
    var readyToMerge = false
    /// The group it is shown in: in Watching the row is one line plus heed's label, unless the cursor is on it.
    var group: SessionGroup = .working
    /// What heed is doing about its PRs ("getting it merged · waiting for checks"), shown instead of the agent's line.
    var label: String?
    /// For a session on a host: its colour (`[hosts.x] color`) and how the link stands.
    var hostColor: String?
    var hostLink: HostStatus?
    /// Subagents its agent has running, appended to the agent's line.
    var subagents = 0
    /// Commits ahead and files changed over its worktrees: the `↑N` and `~N` chips.
    var pending = PendingChanges()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 1)
            StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if session.isChat { ChatGlyph() }
                    Text(session.worktreeName)
                        .font(Theme.ui(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.title)
                    Spacer(minLength: 4)
                    PendingChips(pending: pending, hasPR: !session.trackedPRs.isEmpty)
                    if let pinNumber { KeyCap(text: "'\(pinNumber)") }
                    if readyToMerge {
                        Text("✓ ready").font(Theme.mono(10.5)).foregroundStyle(Theme.done).fixedSize()
                            .help("A PR of this session is ready to merge, and get it merged is off: zM merges it")
                    } else if let pilot, pilot != .unwatched {
                        PilotMark(status: pilot, compact: true)
                    }
                    if let host = session.host { HostChip(location: .host(host), color: hostColor) }
                    if !session.trackedPRs.isEmpty {
                        Text("\(session.trackedPRs.count) PR")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                    }
                }
                if let chat = session.chat {
                    ChatFolderChip(chat: chat)
                } else if !compact {
                    FlowChips(repos: session.involvedRepos)
                }
                // A pinned session keeps its agent's line, with heed's under it.
                if label == nil || group == .pinned {
                    // Working: the spinner says it, so just the agent, its model and how full its context is; the
                    // command it runs changes with every hook and would make the list jump. Always one line,
                    // whatever the state says.
                    agentLine
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.fg3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let label {
                    Text(label)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(isStalled ? Theme.err : Theme.busy)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isStalled, !compact {
                        HStack(spacing: 6) {
                            KeyCap(text: "zr")
                            Text("another round").foregroundStyle(Theme.fg3)
                        }
                        .font(Theme.ui(11.5))
                    }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, compact ? 6 : 9)
        // Watching asks to be left be: a little quieter than what is yours.
        .opacity(compact ? 0.8 : 1)
        .background(isCursor ? Theme.bg3 : .clear)
        // A session on a host gets a rail in the host's colour: dashed while the link is down, dimmed when offline.
        .overlay(alignment: .leading) {
            if let host = session.host {
                let palette = HostPalette.color(for: host, configured: hostColor)
                if hostLink?.isConnected == false {
                    Rectangle().stroke(palette.swatch, style: StrokeStyle(lineWidth: 3, dash: [4, 4]))
                        .frame(width: 1.5).padding(.vertical, 4).opacity(0.7)
                } else {
                    palette.swatch.frame(width: 3).padding(.vertical, 4)
                }
            } else if session.isChat {
                // A chat's rail is neutral: it belongs to no repo.
                Theme.fg3.opacity(0.5).frame(width: 3).padding(.vertical, 4)
            }
        }
        .opacity(isOffline ? 0.55 : 1)
        .overlay(alignment: .topLeading) {
            if let hint { HintBadge(label: hint).padding(.leading, 8).padding(.top, 8) }
        }
    }

    /// `claude · model-a · ctx 38% · 2 subagents`, the percentage amber once the context is 80% full.
    private var agentLine: Text {
        let line = AgentUsage.line(
            agent: session.agent, working: session.state.state == .working, activity: session.activity,
            usage: session.usage, subagents: subagents
        )
        var text = Text(line.lead)
        if let context = line.context {
            let part = Text(context).foregroundStyle(line.contextIsHigh ? Theme.block : Theme.fg3)
            text = Text("\(text) · \(part)")
        }
        if let count = line.subagents { text = Text("\(text) · \(count)") }
        if let activity = line.activity { text = Text("\(text) · \(activity)") }
        return text
    }

    private var isOffline: Bool { if case .offline = hostLink { true } else { false } }
    private var isStalled: Bool { if case .stalled = pilot { true } else { false } }
    /// One line plus heed's label: Watching, unless the cursor is on it.
    private var compact: Bool { group == .watching && !isCursor }
}

/// `↑3 ~2` on a session's row: commits not pushed (amber) and files not committed, each only when there are any.
/// Commits with no PR to carry them say so on hover.
struct PendingChips: View {
    let pending: PendingChanges
    let hasPR: Bool

    var body: some View {
        if pending.ahead > 0 {
            chip("↑\(pending.ahead)", Theme.block)
                .help(hasPR
                    ? "\(pending.ahead) commit\(pending.ahead == 1 ? "" : "s") not pushed"
                    : "\(pending.ahead) commit\(pending.ahead == 1 ? "" : "s"), no PR yet")
        }
        if pending.dirty > 0 {
            chip("~\(pending.dirty)", Theme.fg2)
                .help("\(pending.dirty) file\(pending.dirty == 1 ? "" : "s") not committed")
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(Theme.mono(10.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
            .fixedSize()
    }
}

/// A run working for a session, under its row: `↳`, the goal and PR in heed's blue, how long, then who runs it and
/// the last line of its screen.
struct RunChildRow: View {
    let run: PilotRun
    let lastLine: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("↳").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            StateGlyph(state: .working, size: 10).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(run.goal.rawValue) #\(run.ref.number)")
                        .font(Theme.ui(12, weight: .medium))
                        .foregroundStyle(Theme.busy)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: run.startedAt, by: 30)) { _ in
                        Text(RunRow.duration(run)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    }
                }
                Text(verbatim: ([run.model.map { "\(run.agent) \($0)" } ?? run.agent] + [lastLine].compactMap(\.self))
                    .joined(separator: " · "))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.fg3)
                    .truncationMode(.tail)
            }
        }
        .lineLimit(1)
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Theme.busy.opacity(0.05))
        .overlay(alignment: .leading) {
            Theme.busy.opacity(0.5).frame(width: 2).padding(.vertical, 2).padding(.leading, 32)
        }
    }
}

private struct FlowChips: View {
    let repos: [Repo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(repos, id: \.self) { RepoChip(repo: $0) }
        }
    }
}

/// HINT mode's letter badge.
struct HintBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.modeColor(.hint)))
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

/// The collapsed sidebar: one row per session with its number, state and pin, so moving and jumping still work.
struct SessionRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                .padding(.vertical, 12)
            ListScroll {
                VStack(spacing: 2) {
                    ForEach(Array(list.ordered.enumerated()), id: \.element.id) { index, session in
                        let isCursor = index == model.cursor
                        VStack(spacing: 4) {
                            Text("\(list.lineNumber(of: index, cursor: model.cursor))")
                                .font(Theme.mono(10, weight: isCursor ? .bold : .regular))
                                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                            StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                            if let pin = list.pins.firstIndex(of: session) {
                                Text("'\(pin + 1)").font(Theme.mono(9)).foregroundStyle(Theme.fg3)
                            }
                        }
                        .frame(width: 44)
                        .padding(.vertical, 8)
                        .background(isCursor ? Theme.bg3 : .clear)
                        .overlay(alignment: .topLeading) {
                            if let hint = model.hintLabel(for: .session(session.id)) { HintBadge(label: hint) }
                        }
                        .help(session.title)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickSession(session.id) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.clickSession(session.id, insert: true)
                        })
                        .rightClickMenu { model.rightClickSession(session.id) } _: { model.sessionMenu(session.id) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 48)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }
}

/// A small chevron button that collapses or expands a pane, with its key in the tooltip.
struct CollapseButton: View {
    let systemImage: String
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.fg3)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("collapse / expand (\(key))")
    }
}
