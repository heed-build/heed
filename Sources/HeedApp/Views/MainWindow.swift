import HeedCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    switch model.view {
                    case .sessions:
                        if model.sidebarCollapsed {
                            SessionRail()
                        } else {
                            Sidebar(width: geometry.size.width < 1000 ? 260 : 330)
                        }
                        CenterArea()
                        // The inspector gives way first on narrow windows; `gi` hides it outright.
                        if model.inspectorVisible, geometry.size.width >= 1180 { Inspector() }
                    case .repos:
                        ReposView()
                    case .history:
                        HistoryView()
                    case .inbox:
                        InboxView()
                    case .issues:
                        IssuesView()
                    case .prs:
                        PullRequestsView()
                    }
                }
            }
            StatusBar()
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
        .overlay {
            if model.overlay == .pr { PullOverlayView().padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.overlay == .diff { DiffOverlayView().padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.reader != nil { ReaderView().padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.startWork != nil { StartWorkView() }
        }
        .overlay {
            if model.resume != nil { ResumeView() }
        }
        .overlay {
            if model.firstRun != nil { FirstRunView() }
        }
        .overlay {
            if model.overlay == .help { HelpOverlay() }
        }
        .overlay(alignment: .bottom) {
            if model.mode == .command { CommandLineView().padding(.bottom, 28) }
        }
        .overlay(alignment: .bottom) {
            LeaderHints().padding(.bottom, 28)
        }
        .ignoresSafeArea()
        .onAppear {
            let open = openSettings
            model.openSettings = { open() }
        }
    }
}

struct TitleBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            // Narrow windows keep only the active view's name and drop the hint text.
            let compact = geometry.size.width < 1180
            HStack(spacing: compact ? 10 : 16) {
                // Room for the window's own traffic lights.
                Color.clear.frame(width: 60, height: 1)
                crumb
                views(compact: compact)
                Spacer(minLength: 0)
                syncStatus
                if model.blockedCount > 0 {
                    Label { Text(compact ? "\(model.blockedCount)" : "\(model.blockedCount) blocked").fixedSize() }
                        icon: { StateGlyph(state: .blocked) }
                }
                if model.askingCount > 0 {
                    Label { Text(compact ? "\(model.askingCount)" : "\(model.askingCount) asking").fixedSize() }
                        icon: { StateGlyph(state: .asking) }
                }
                HStack(spacing: 6) {
                    KeyCap(text: "ga")
                    if !compact { Text("next attention").foregroundStyle(Theme.fg3).fixedSize() }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .font(Theme.ui(12))
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    /// Unread inbox items; PRs that need you.
    private func badge(_ view: AppView) -> Int {
        switch view {
        case .inbox: model.github.inbox.count(where: \.unread)
        case .prs: model.github.pullsNeedingAttention
        default: 0
        }
    }

    @ViewBuilder private var syncStatus: some View {
        if model.view == .inbox || model.view == .issues || model.view == .prs {
            Group {
                if model.syncing {
                    Text("syncing…")
                } else if model.github.status.isOffline {
                    Text("offline").foregroundStyle(Theme.block)
                } else if let synced = model.github.syncedAt {
                    if case let .partial(hidden, _) = model.github.status {
                        Text("synced \(synced.formatted(.relative(presentation: .numeric))) · \(hidden) hidden")
                            .help("Items in orgs the gh token is not authorized for (SAML).")
                    } else {
                        Text("synced \(synced.formatted(.relative(presentation: .numeric)))")
                    }
                }
            }
            .foregroundStyle(Theme.fg3)
            .fixedSize()
        }
    }

    @ViewBuilder private var crumb: some View {
        if model.view != .sessions {
            Text(model.view == .repos ? "Repos & worktrees" : model.view.title)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.fg2)
                .lineLimit(1)
        } else if let session = model.currentSession {
            HStack(spacing: 4) {
                Text(session.repos.first?.name ?? "").foregroundStyle(Theme.fg2)
                Text("/").foregroundStyle(Theme.dim)
                Text(session.branch).fontWeight(.medium)
            }
            .font(Theme.mono(12))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 100, alignment: .leading)
            .layoutPriority(-1)
        }
    }

    /// The views as names with their key (`Inbox 7 gm`); narrow windows drop the keys, never the names.
    private func views(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(AppView.allCases) { view in
                ViewTab(
                    view: view,
                    active: model.view == view,
                    count: badge(view),
                    key: compact ? nil : model.keyCap(for: view.command)
                )
                .onTapGesture { model.perform(CommandInvocation(name: view.command)) }
            }
        }
    }
}

private struct ViewTab: View {
    let view: AppView
    let active: Bool
    let count: Int
    let key: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(view.title).foregroundStyle(active ? Theme.fg : Theme.fg2)
            if count > 0 { Text("\(count)").foregroundStyle(Theme.block) }
            if let key {
                Text(key)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.keyCapBorder))
            }
        }
        .font(Theme.ui(12.5, weight: active ? .semibold : .regular))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, key == nil ? 7 : 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text(model.mode.label)
                .font(Theme.mono(11.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Theme.modeColor(model.mode))
            if let session = model.currentSession {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(session.branch)
                }
                .padding(.horizontal, 12)
            }
            if let tab = model.currentTab, let index = tab.tree.panes.firstIndex(where: { $0.id == tab.focused }) {
                Text("pane \(index + 1) · \(tab.tree.panes[index].title)")
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 12)
            }
            if let flash = model.flash {
                Text(flash).foregroundStyle(Theme.block).padding(.horizontal, 12)
            } else if let problem = model.configProblems.first {
                Text("config.toml: \(problem.description)").foregroundStyle(Theme.err).lineLimit(1).padding(
                    .horizontal,
                    12
                )
            } else if let problem = model.keyProblems.first {
                Text("config: \(problem.description)").foregroundStyle(Theme.err).padding(.horizontal, 12)
            }
            Spacer()
            Text(model.pendingKeys).foregroundStyle(Theme.fg).padding(.horizontal, 12)
            Text(hints).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head).padding(.horizontal, 12)
            Text(position).foregroundStyle(Theme.fg2).padding(.horizontal, 12)
        }
        .font(Theme.mono(11.5))
        .frame(height: 28)
        .background(Theme.bg3)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var position: String {
        switch model.view {
        case .inbox, .issues, .prs:
            let count = model.itemIDs(model.view).count
            return "\(count == 0 ? 0 : model.cursor(in: model.view) + 1)/\(count)"
        case .repos: return "\(model.worktreeRows.isEmpty ? 0 : model.repoCursor + 1)/\(model.worktreeRows.count)"
        case .history: return "\(model.historyRows.isEmpty ? 0 : model.historyCursor + 1)/\(model.historyRows.count)"
        case .sessions: return "\(model.list.ordered.isEmpty ? 0 : model.cursor + 1)/\(model.list.ordered.count)"
        }
    }

    private var hints: String {
        switch model.mode {
        case .normal where model.filtering: "type to filter · ↩ keep · ⎋ clear"
        case .normal where model.overlay == .diff: "j k line · n hunk · ]f file · ⇥ scope · c commit · t split · gd close"
        case .normal where model.reader != nil || model.overlay == .pr:
            "j k item · space queue · s send · m auto-feed · ]p next PR · gS session · ⎋ back"
        case .normal where model.view == .repos: "v select · n new worktree · R rescan · ⎋ back to sessions"
        case .normal where model.view == .history: "j k move · / search · R reopen · O new from prompt · t outcome"
        case .normal where model.view == .inbox: "space pick · v range · s start session · a add · m read · o open · t filter"
        case .normal where model.view == .issues: "space pick · v range · s start session · a add · o open"
        case .normal where model.view == .prs: "j k move · o open · gS session · r sync"
        case .normal: "i insert · o start work · gp PR overlay · : command · ? keys"
        case .insert: "\(KeyCapText.of(DefaultKeys.insertEscape)) normal · ⌘/ keys"
        case .visual: "\(model.selectedRows.count) selected · space toggle · y copy path · o open session · ⎋ cancel"
        case .command: "⇥ complete · ↩ run · ⎋ cancel"
        case .hint: "type a label · ⎋ cancel"
        }
    }
}

/// Key notation as key-cap text: `<C-w>v` reads `⌃w v`.
enum KeyCapText {
    static func of(_ notation: String) -> String {
        guard let strokes = try? KeyNotation.parse(notation) else { return notation }
        return of(strokes)
    }

    /// Runs of plain characters share a cap (`gg`, `'1`); a modified or named key stands alone (`⌃w v`).
    static func of(_ strokes: [KeyStroke]) -> String {
        var parts: [String] = []
        var previousPlain = false
        for stroke in strokes {
            let plain = stroke.modifiers.isEmpty && !stroke.isNamed
            if plain, previousPlain {
                parts[parts.count - 1] += stroke.glyph
            } else {
                parts.append(stroke.glyph)
            }
            previousPlain = plain
        }
        return parts.joined(separator: " ")
    }
}

struct CommandLineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.commandCompletions, id: \.name) { spec in
                HStack {
                    Text(spec.name).font(Theme.mono(12))
                    if let args = spec.arguments { Text(args).font(Theme.mono(12)).foregroundStyle(Theme.fg3) }
                    Spacer()
                    Text(spec.summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            HStack(spacing: 0) {
                Text(":").foregroundStyle(Theme.ask)
                Text(model.commandText)
                Rectangle().fill(Theme.fg).frame(width: 7, height: 15)
                Spacer()
            }
            .font(Theme.mono(13))
            .padding(12)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 20)
    }
}

/// Views not built yet say which step brings them.
struct ComingView: View {
    let view: AppView

    var body: some View {
        VStack(spacing: 10) {
            Text(view.title).font(Theme.ui(15, weight: .medium))
            Text("GitHub arrives in step 6.")
                .foregroundStyle(Theme.fg3)
            HStack(spacing: 6) {
                KeyCap(text: "⎋")
                Text("back to sessions").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
