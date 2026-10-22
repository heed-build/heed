import HeedCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TitleBar().shotRegion(.titleBar)
            if model.tutor != nil { TutorBanner().shotRegion(.tutorBanner) }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    switch model.view {
                    case .sessions:
                        if model.sidebarCollapsed {
                            SessionRail().shotRegion(.rail)
                        } else {
                            Sidebar(width: geometry.size.width < 1000 ? 260 : 330).shotRegion(.sidebar)
                        }
                        CenterArea().shotRegion(.center)
                        // The inspector gives way first on narrow windows; `zi` hides it outright.
                        if model.inspectorVisible, geometry.size.width >= 1180 { Inspector().shotRegion(.inspector) }
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
                    case .watch:
                        WatchView()
                    case .log:
                        CallLogView()
                    case .timeline:
                        HistoryTimelineView()
                    }
                }
            }
            StatusBar().shotRegion(.statusBar)
        }
        .background(Theme.bg)
        .overlay {
            if model.overlay == .pr { PullOverlayView().shotRegion(.pipeline).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.overlay == .diff { DiffOverlayView().shotRegion(.diffBody).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.reader != nil { ReaderView().shotRegion(.reader).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.issueReader != nil { IssueReaderView().shotRegion(.reader).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.startWork != nil, !model.startWorkStandalone { StartWorkView() }
        }
        .overlay {
            if model.resume != nil { ResumeView() }
        }
        .overlay {
            if let picker = model.importPicker { ImportPickerView(picker: picker) }
            if let state = model.taskPicker { TaskPickerView(state: state) }
            if let picker = model.hostsPicker { HostsPickerView(picker: picker) }
            if let chooser = model.hostRootsChooser { HostRootsView(chooser: chooser) }
            if let picker = model.linkPicker { LinkPickerView(picker: picker) }
            if let run = model.runReader { RunReaderView(run: run) }
            if let summary = model.awaySummary { AwaySummaryView(summary: summary) }
            if let ref = model.pilotExplain { PilotExplainerView(ref: ref) }
        }
        .overlay {
            if let state = model.pathImport { PathImportView(state: state) }
        }
        .overlay {
            if let confirmation = model.confirmation { ConfirmationView(confirmation: confirmation) }
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
        // The tutor over everything it can point at (dialogs included), then its picker over that.
        .overlayPreferenceValue(ShotRegionKey.self) { anchors in
            if let tutor = model.tutor { TutorLayer(tutor: tutor, anchors: anchors) }
        }
        .overlay {
            if let picker = model.tutorPicker { TutorPickerView(picker: picker) }
        }
        // After the overlays, so the dialogs inherit it too.
        .foregroundStyle(Theme.fg)
        .ignoresSafeArea()
        .onAppear {
            let open = openSettings
            model.openSettings = { open() }
            let reopen = openWindow
            model.reopenWindow = { reopen(id: "main") }
        }
    }
}

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            // Narrow windows keep only the active view's name and drop the hint text.
            let compact = geometry.size.width < 1180
            let width = geometry.size.width
            // What you are looking at sits in the middle of the window when the middle is free, else in the gap
            // between the views and the status.
            let gap: CGFloat = 24
            let centred = width - 2 * max(leftWidth, rightWidth) - 2 * gap
            let between = width - leftWidth - rightWidth - 2 * gap
            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // Room for the window's own traffic lights.
                        Color.clear.frame(width: 60, height: 1)
                        views(compact: compact)
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftWidth = $0 }
                    Spacer(minLength: 0)
                    HStack(spacing: compact ? 10 : 16) { status(compact: compact) }
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightWidth = $0 }
                }
                if centred >= 160 {
                    crumb.frame(maxWidth: centred)
                } else if between >= 80 {
                    crumb.frame(maxWidth: between)
                        .offset(x: (leftWidth - rightWidth) / 2)
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

    @ViewBuilder private func status(compact: Bool) -> some View {
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
        if let reminder = model.tutorReminder { TutorReminderView(reminder: reminder, compact: compact) }
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
                        Text("synced \(Clock.relative(synced)) · \(hidden) hidden")
                            .help("Items in orgs the gh token is not authorized for (SAML).")
                    } else {
                        Text("synced \(Clock.relative(synced))")
                    }
                }
            }
            .foregroundStyle(Theme.fg3)
            .fixedSize()
        }
    }

    /// What you are looking at: the session's branch and PR, or the PR, issue, worktree or history entry under the
    /// cursor (or open in a reader).
    @ViewBuilder private var crumb: some View {
        if let context = model.titleContext {
            HStack(spacing: 6) {
                // The repo and the branch or number stay whole; the title gives way.
                if let lead = context.lead {
                    Text(lead).foregroundStyle(Theme.fg2).fixedSize()
                    Text("/").foregroundStyle(Theme.dim).fixedSize()
                }
                Text(context.main).fontWeight(.medium).foregroundStyle(Theme.fg).truncationMode(.middle)
                    .layoutPriority(1)
                if let detail = context.detail { Text(detail).foregroundStyle(Theme.fg3).truncationMode(.tail) }
            }
            .font(Theme.mono(12))
            .lineLimit(1)
            .clipped()
        }
    }

    /// The views as names with their key (`Inbox 7 gm`); narrow windows drop the keys, never the names.
    private func views(compact: Bool) -> some View {
        viewTabs(compact: compact).shotRegion(.viewTabs)
    }

    private func viewTabs(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(AppView.tabs.enumerated()), id: \.element) { index, view in
                // A hairline between views: separate without boxing them in.
                if index > 0 { Theme.line.frame(width: 1, height: 14) }
                ViewTab(
                    view: view,
                    active: model.view.tab == view,
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
            if let tutor = model.tutor { TutorPill(tutor: tutor) }
            if model.filtering {
                filterLine
            } else {
                if let host = model.currentSession?.host {
                    // Where the session runs, and how the link is: after the mode pill, before anything else.
                    let palette = HostPalette.color(for: host, configured: model.config.hosts[host]?.color)
                    HStack(spacing: 6) {
                        Text("@\(host)")
                        if case let .connected(info) = model.hostStatus(host) {
                            Text("⇄ \(info.latencyMilliseconds)ms")
                        } else {
                            Text("· link down").foregroundStyle(Theme.fg3)
                        }
                    }
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background(palette.swatch.opacity(0.14))
                }
                if let session = model.currentSession {
                    HStack(spacing: 6) {
                        // A chat has no branch: its speech bubble and title instead.
                        Image(systemName: session.isChat ? "bubble.left" : "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(session.isChat ? session.title : session.branch).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                }
                if let tab = model.currentTab, let index = tab.tree.panes.firstIndex(where: { $0.id == tab.focused }) {
                    Text("pane \(index + 1) · \(tab.tree.panes[index].title)")
                        .foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 12)
                }
                if let flash = model.flash {
                    Text(flash).foregroundStyle(Theme.block).lineLimit(1).truncationMode(.middle).padding(
                        .horizontal,
                        12
                    )
                } else if let problem = model.configProblems.first {
                    Text("config.toml: \(problem.description)").foregroundStyle(Theme.err).lineLimit(1).padding(
                        .horizontal,
                        12
                    )
                } else if let problem = model.keyProblems.first {
                    Text("config: \(problem.description)").foregroundStyle(Theme.err).padding(.horizontal, 12)
                } else if let problem = model.tools?.problems.first {
                    Text(problem).foregroundStyle(Theme.err).lineLimit(1).truncationMode(.middle).padding(
                        .horizontal,
                        12
                    )
                }
            }
            Spacer()
            Text(model.pendingKeys).foregroundStyle(Theme.fg).padding(.horizontal, 12)
            // A quiet nudge until you have done this view's lesson.
            if model.tutor == nil, !model.tutorRecord.done.contains(Tutor.lessonID(forView: model.view.tab.rawValue)) {
                Text("? t tutor").foregroundStyle(Theme.fg3).padding(.leading, 12)
            }
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
        case .inbox, .issues, .prs, .watch:
            let count = model.itemIDs(model.view).count
            return "\(count == 0 ? 0 : model.cursor(in: model.view) + 1)/\(count)"
        case .repos: return "\(model.worktreeRows.isEmpty ? 0 : model.repoCursor + 1)/\(model.worktreeRows.count)"
        case .history: return "\(model.historyRows.isEmpty ? 0 : model.historyCursor + 1)/\(model.historyRows.count)"
        case .log: return "\(model.callLog.rows.isEmpty ? 0 : model.callLog.cursor + 1)/\(model.callLog.rows.count)"
        case .timeline:
            let rows = model.timeline.rows
            return "\(rows.isEmpty ? 0 : model.timeline.cursor + 1)/\(rows.count)"
        case .sessions: return "\(model.list.ordered.isEmpty ? 0 : model.cursor + 1)/\(model.list.ordered.count)"
        }
    }

    /// `/` types here, whichever view it filters; the view's pill mirrors it.
    private var filterLine: some View {
        HStack(spacing: 0) {
            Text("/").foregroundStyle(Theme.ask)
            Text(model.filter(for: model.view)).foregroundStyle(Theme.fg)
            Rectangle().fill(Theme.fg).frame(width: 7, height: 14)
            Text(
                "  \(model.view.title.lowercased()) · \(model.filterMatches) match\(model.filterMatches == 1 ? "" : "es")"
            )
            .foregroundStyle(Theme.fg3)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
    }

    /// The pilot's keys as bound: `zw watch · zg green · zm merge · zp pause` by default.
    private var pilotHints: String {
        [("pilot.watch", "watch"), ("pilot.green", "green"), ("pilot.merge", "merge"), ("pilot.pause", "pause")]
            .map { "\(model.keyText(for: $0.0)) \($0.1)" }.joined(separator: " · ")
    }

    private var hints: String {
        switch model.mode {
        case let .normal where model.confirmation.map { !$0.alternatives.isEmpty } == true:
            "y or ↩ \(model.confirmation?.accept.lowercased() ?? "confirm") · "
                + (model.confirmation?.alternatives ?? []).map { "\($0.key) \($0.label.lowercased())" }
                .joined(separator: " · ")
                + " · ⎋ \(model.confirmation?.cancel.lowercased() ?? "cancel")"
        case .normal where model.confirmation != nil: "y or ↩ confirm · n, ⎋ or q cancel"
        case .normal where model.importPicker != nil: "type to filter · ⌃n ⌃p move · ↩ import · ⎋ cancel"
        case .normal where model.hostRootsChooser?.editing != nil: "type a folder under ~ · ⌃w up a folder · ↩ done · ⎋ back"
        case .normal where model.hostRootsChooser != nil: "j k move · space pick · a add a folder · w worktrees · ↩ save · ⎋ skip"
        case .normal where model.pathImport != nil: "⇥ complete · ⌃n ⌃p choose · ⌃w up a folder · ↩ import · ⎋ cancel"
        case .normal where model.filtering: "words match anywhere · ⌃w word · ⌃u clear · ↩ keep · ⎋ clear"
        case .normal where model.overlay == .diff: "j k line · n hunk · ]f file · ⇥ scope · c commit · t split · gd close"
        case .normal where model.issueReader != nil: "s start session · a add to session · gB browser · ⎋ back"
        case .normal where model.reader != nil || model.overlay == .pr:
            "j k item · space queue · s send · \(model.keyText(for: "pilot.green")) green · h l PRs · gS session · ⎋ back"
        case .normal where model.view == .repos: "o start work here · v select · dd remove · r rescan · w issues · { } repo · / filter"
        case .normal where model.view == .history:
            "j k move · / filter · R reopen · O new from prompt · t outcome · \(model.keyText(for: "history.timeline", in: "history")) timeline"
        case .normal where model.view == .timeline:
            [
                ("timeline.kind", "kind"),
                ("timeline.repo", "repo"),
                ("timeline.where", "where"),
                ("timeline.gone", "removed"),
                ("history.reopen", "reopen"),
                ("history.timeline", "list"),
            ]
            .map { "\(model.keyText(for: $0.0, in: "timeline")) \($0.1)" }.joined(separator: " · ") + " · { } day · / search"
        case .normal where model.view == .log:
            [
                ("log.kind", "kind"),
                ("log.failed", "failed"),
                ("log.slow", "slow"),
                ("log.writes", "writes"),
                ("log.caller", "caller"),
                ("log.agent", "agent"),
                ("log.copy", "copy"),
            ]
            .map { "\(model.keyText(for: $0.0, in: "log")) \($0.1)" }.joined(separator: " · ") + " · / search"
        case .normal where model.view == .inbox: "↩ read · space pick · v range · s start session · a add · x mark read · t unread/all · / filter"
        case .normal where model.view == .issues: "↩ read · space pick · s start session · t filter · ⇥ repo · w all/yours · / filter"
        case .normal where model.view == .prs: "↩ open · \(pilotHints) · v select · gS session · r sync"
        case .normal where model.view == .watch: "↩ open · \(pilotHints) · v select · R merge now · gM queue"
        case .normal: "i insert · o start work · m pin · { } group · Iw import · : command · ? keys"
        case .insert: "⇧⎋ or \(KeyCapText.of(model.config.insertEscape)) normal · ⌘/ keys"
        case .visual where model.view == .watch || model.view == .prs:
            "\(model.pickedIDs(model.view).count) selected · \(model.keyText(for: "pilot.pause")) pause or resume · space toggle · ⎋ cancel"
        case .visual: "\(model.selectedRows.count) selected · space toggle · y copy path · o open session · ⎋ cancel"
        case .command: "⇥ complete · ↑↓ choose · ↩ run · ⎋ cancel"
        case .hint: "type a label · ⎋ cancel"
        }
    }
}

struct CommandLineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            completions
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
        .shadow(color: .black.opacity(0.5), radius: 20).shotRegion(.commandLine)
    }
}

extension CommandLineView {
    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 10

    /// Every match, ten rows tall at most and scrolled to the one ⇥ / ↓ took.
    @ViewBuilder private var completions: some View {
        let matches = model.commandCompletions
        if !matches.isEmpty {
            ScrollViewReader { proxy in
                ListScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        // A shot draws what the window would show: the first ten (it cannot clip a list).
                        let shown = ShotMode.active ? Array(matches.prefix(Self.visibleRows)) : matches
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, match in
                            row(match, selected: index == model.completionIndex).id(index)
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(min(matches.count, Self.visibleRows)))
                .onChange(of: model.completionIndex) { _, index in
                    if let index { proxy.scrollTo(index) }
                }
            }
            Theme.line.frame(height: 1)
        }
    }

    private func row(_ match: CommandCompletion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(match.label).font(Theme.mono(12)).lineLimit(1)
            if let args = match.arguments { Text(args).font(Theme.mono(12)).foregroundStyle(Theme.fg3) }
            if match.kind == .alias {
                Text("alias").font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
            }
            Spacer(minLength: 12)
            Text(match.summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
            if match.kind == .command, let key = model.keyLabel(for: match.label) {
                Text(key).font(Theme.mono(11)).foregroundStyle(Theme.fg2)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.selected : .clear)
    }
}

/// Asks before anything destructive: what will happen, what is kept and why; y or ↩ goes ahead, n, ⎋ or q does not.
struct ConfirmationView: View {
    @Environment(AppModel.self) private var model
    let confirmation: AppModel.Confirmation

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 14) {
                Text(confirmation.title).font(Theme.ui(15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(confirmation.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(confirmation.destructive ? Theme.err : Theme.fg3)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg2)
                if !confirmation.kept.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kept").font(Theme.ui(11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.fg3)
                        ForEach(confirmation.kept, id: \.self) { line in
                            Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.block)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    // Cancelling that does what accepting does (Keep) needs no button of its own; ⎋ still works.
                    if confirmation.cancel != confirmation.accept {
                        HStack(spacing: 6) {
                            Text(confirmation.cancel)
                            KeyCap(text: "n")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .contentShape(Rectangle())
                        .onTapGesture { model.cancelConfirmation() }
                    }
                    ForEach(confirmation.alternatives, id: \.key) { alternative in
                        HStack(spacing: 6) {
                            Text(alternative.label)
                            KeyCap(text: alternative.key)
                        }
                        .foregroundStyle(alternative.destructive ? Theme.err : Theme.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(alternative.destructive ? Theme.err.opacity(0.6) : Theme.line))
                        .contentShape(Rectangle())
                        .onTapGesture { model.chooseAlternative(alternative.key) }
                    }
                    HStack(spacing: 6) {
                        Text(confirmation.accept).fontWeight(.semibold)
                        KeyCap(text: "↩")
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(confirmation.destructive ? Theme.err : Theme.inverse))
                    .contentShape(Rectangle())
                    .onTapGesture { model.acceptConfirmation() }
                }
                .font(Theme.ui(12.5))
            }
            .padding(22)
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30).shotRegion(.confirm)
        }
    }
}

/// `I` in Sessions: worktrees without a session (main checkouts last), narrowed as you type; ↩ imports one.
struct ImportPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: Typeahead<Worktree>

    var body: some View {
        let matches = picker.matches
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import a worktree").font(Theme.ui(15, weight: .semibold))
                    Text(
                        "Worktrees of your repos that Heed does not manage yet. Importing resumes the agent session kept there, else starts the agent fresh. Elsewhere on disk? Ip imports a path."
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                .padding(18)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    Text(picker.query + "▌").font(Theme.mono(12.5))
                    Spacer()
                    Text("\(matches.count) of \(picker.items.count)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                ScrollViewReader { proxy in
                    ListScroll {
                        ListStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, worktree in
                                // Repo and branch, the path small below: room to read, and the matches marked.
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 10) {
                                        RepoChip(repo: worktree.repo, highlight: picker.query).fixedSize()
                                        Highlighted(
                                            text: worktree.branch ?? "detached \(worktree.head)", query: picker.query
                                        )
                                        .font(Theme.mono(12.5))
                                        .lineLimit(1)
                                        if worktree.isMain {
                                            Text("main checkout").font(Theme.ui(11)).foregroundStyle(Theme.fg3)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    WorktreePath(
                                        path: worktree.path,
                                        roots: model.settings.pathRoots,
                                        query: picker.query
                                    )
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(index == picker.cursor ? Theme.bg3 : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { model.pickImport(worktree) }
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: picker.cursor) { proxy.scrollTo(picker.cursor) }
                }
                .frame(maxHeight: 380)
                if AppModel.looksLikePath(picker.query), matches.isEmpty {
                    HStack(spacing: 8) {
                        KeyCap(text: "↩")
                        Text("import the worktree at \(picker.query)").font(Theme.mono(12))
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                HStack {
                    Text("⌃n ⌃p move · ↩ import · ⎋ cancel · Ip (in Sessions) imports a path").font(Theme.ui(11.5))
                        .foregroundStyle(Theme.fg3)
                    Spacer()
                }
                .padding(14)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 30).shotRegion(.picker)
        }
    }
}

/// `!`: the session's tasks, pinned and discovered (mise, make, package.json), narrowed by typing; ↩ runs one in a tab.
struct TaskPickerView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.TaskPickerState

    var body: some View {
        let picker = state.picker
        let matches = picker.matches
        ZStack {
            Color.black.opacity(0.5).onTapGesture { model.cancelTaskPicker() }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run a task").font(Theme.ui(15, weight: .semibold))
                    Text("Pinned in config, and found in the worktree: mise tasks, make targets, package.json scripts. "
                        + "Each runs in a tab of its own.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                .padding(18)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    Text(picker.query + "▌").font(Theme.mono(12.5))
                    Spacer()
                    Text(state.loading ? "reading…" : "\(matches.count) of \(picker.items.count)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                ScrollViewReader { proxy in
                    ListScroll {
                        ListStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.offset) { index, task in
                                HStack(spacing: 10) {
                                    Highlighted(text: task.name, query: picker.query)
                                        .font(Theme.mono(12.5, weight: .semibold)).lineLimit(1).fixedSize()
                                    Text(task.detail ?? task.command).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    Text(task.source.rawValue).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                                        .padding(.horizontal, 5)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(index == picker.cursor ? Theme.bg3 : .clear)
                                .overlay(alignment: .leading) {
                                    if index == picker.cursor { Theme.block.frame(width: 2) }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.pickTask(task) }
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: picker.cursor) { proxy.scrollTo(picker.cursor) }
                }
                .frame(maxHeight: 380)
                if matches.isEmpty, !state.loading {
                    Text(picker.items.isEmpty ? "No tasks here." : "No task matches.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                ForEach(state.notes, id: \.self) { note in
                    Text(note).font(Theme.ui(12)).foregroundStyle(Theme.block)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
                HStack {
                    Text("⌃n ⌃p move · ↩ run · ⌃r read again · ⎋ cancel").font(Theme.ui(11.5))
                        .foregroundStyle(Theme.fg3)
                    Spacer()
                }
                .padding(14)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 30).shotRegion(.picker)
        }
    }
}

/// `P` in Sessions: a path with directory completion and a preview of what is there; ↩ imports that worktree.
struct PathImportView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.PathImport

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import a path").font(Theme.ui(15, weight: .semibold))
                    Text(
                        "Any worktree of any repo, wherever it is. A repo Heed does not know is added (and kept in [worktrees] repo_paths)."
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    Text(state.query + "▌").font(Theme.mono(12.5)).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Theme.pane)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                if let preview = state.preview {
                    HStack(spacing: 8) {
                        Image(systemName: state.importable ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(state.importable ? Theme.done : Theme.fg3)
                        Text(preview).font(Theme.mono(12)).foregroundStyle(state.importable ? Theme.fg : Theme.fg3)
                            .lineLimit(1)
                        Spacer()
                        if state.importable {
                            KeyCap(text: "↩")
                            Text("import").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.candidates.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                            Text((path as NSString).lastPathComponent + "/").font(Theme.mono(12))
                            Spacer()
                            if index == state.cursor { KeyCap(text: "⇥") }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)
                        .background(index == state.cursor ? Theme.bg3 : .clear)
                    }
                    if state.candidates.isEmpty {
                        Text("No folders here to complete.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 6)
                HStack {
                    Text("⇥ complete · ⌃n ⌃p choose · ⌃w up a folder · ↩ import · ⎋ cancel")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    Spacer()
                }
                .padding(14)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 30).shotRegion(.picker)
        }
    }
}

/// The title bar's gentle nudge towards the tutor: the tour, this view's lesson, or one left halfway. Click to start
/// it,
/// × (or `:tutor.hide`) to stop being reminded of it.
private struct TutorReminderView: View {
    @Environment(AppModel.self) private var model
    let reminder: TutorReminder
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { model.startRemindedLesson() } label: {
                HStack(spacing: 6) {
                    Text(compact ? "tutor" : reminder.text).fixedSize()
                    if let key = model.keyLabel(for: "tutor") { KeyCap(text: key) }
                }
            }
            .buttonStyle(.plain)
            .help("Start the lesson")
            Button { model.hideTutorReminder() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Stop reminding me (:tutor.hide)")
        }
        .foregroundStyle(Theme.block)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.block.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Theme.block.opacity(0.35)))
        .shotRegion(.tutorReminder)
    }
}

/// `gH`: the hosts heed drives over ssh and the ones in ~/.ssh/config or on your tailnet it could add, with the
/// selected host's checks.
struct HostsPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: Typeahead<AppModel.HostRow>

    var body: some View {
        let matches = picker.matches
        let selected = matches.indices.contains(picker.cursor) ? matches[picker.cursor] : nil
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hosts").font(Theme.ui(15, weight: .semibold))
                    Text(
                        "Machines heed drives over ssh, with your own config, keys and agent. ↩ adds one from ~/.ssh/config or your tailnet, or checks one again."
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                .padding(18)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    Text(picker.query + "▌").font(Theme.mono(12.5))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text(
                                "No hosts in ~/.ssh/config or on your tailnet. Add [hosts.<name>] ssh = \"user@address\" to config.toml."
                            )
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg3).padding(18)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, row in
                            let palette = HostPalette.color(
                                for: row.name,
                                configured: model.config.hosts[row.name]?.color
                            )
                            // The machines on your tailnet that are not hosts yet, under their own heading.
                            if row.machine != nil, index == 0 || matches[index - 1].machine == nil {
                                Text("ON YOUR TAILNET").font(Theme.ui(10.5, weight: .semibold)).tracking(0.7)
                                    .foregroundStyle(Theme.fg3)
                                    .padding(.horizontal, 18).padding(.top, index == 0 ? 8 : 12).padding(.bottom, 4)
                            }
                            HStack(spacing: 10) {
                                if let machine = row.machine {
                                    Circle().fill(machine.online ? Theme.done : Theme.fg3.opacity(0.6))
                                        .frame(width: 7, height: 7).frame(width: 9)
                                } else {
                                    RoundedRectangle(cornerRadius: 2).fill(palette.swatch).frame(width: 9, height: 9)
                                }
                                Highlighted(text: row.name, query: picker.query).font(Theme.mono(13, weight: .semibold))
                                    .foregroundStyle(row.machine?.online == false ? Theme.fg3 : Theme.fg)
                                Spacer(minLength: 8)
                                if let machine = row.machine {
                                    if machine.hasTailscaleSSH {
                                        Text("Tailscale SSH").font(Theme.mono(10)).foregroundStyle(Theme.fg2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Theme.bg3))
                                    }
                                    Text("\(machine.os)\(machine.online ? "" : " · offline") · add")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                                } else {
                                    Text(row.configured ? row.summary : "\(row.summary) · add")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(index == picker.cursor ? Theme.bg3 : .clear)
                            .overlay(alignment: .leading) {
                                if index == picker.cursor { Theme.block.frame(width: 2) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.pickHost(row) }
                        }
                    }
                    .frame(width: 330, alignment: .leading)
                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                    HostChecks(row: selected).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, alignment: .top)
                HStack(spacing: 14) {
                    Spacer()
                    Text("⌃n ⌃p move · ↩ add or check · ⌃r where repos are · ⎋ close").font(Theme.mono(11))
                        .foregroundStyle(Theme.fg3)
                }
                .padding(14)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 720)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }
}

/// A host's checks: connected and how fast, git, zmx, agents; or what stops heed from reaching it.
private struct HostChecks: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.HostRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row {
                Text(row.configured ? "CHECKS FOR @\(row.name)" : "@\(row.name) IS NOT ADDED YET")
                    .font(Theme.ui(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
                if row.configured {
                    switch model.hostStatus(row.name) {
                    case .unknown:
                        check(nil, "checking…")
                    case let .connected(info):
                        if let machine = model.tailnetMachine(for: row.name) {
                            check(true, "connected in \(info.latencyMilliseconds) ms over your tailnet" + (
                                machine.hasTailscaleSSH ? ", with Tailscale SSH" : " through your ssh agent"
                            ))
                            check(true, (info.link.map { "\($0.label) · " } ?? "") + machine.dnsName)
                        } else {
                            check(true, "connected in \(info.latencyMilliseconds) ms through your ssh agent")
                        }
                        check(true, "\(info.platform)")
                        check(info.git != nil, info.git.map { "git \($0)" } ?? "git not found")
                        check(
                            info.zmx != nil,
                            info.zmx.map { "zmx \($0): sessions here outlive the link" }
                                ?? "zmx not installed: sessions here end when the link drops"
                        )
                        if info.zmx == nil { ZmxInstallHint(commands: ZmxInstall.commands(
                            platform: info.platform,
                            os: info.os
                        )) }
                        check(
                            !info.agents.isEmpty,
                            info.agents.isEmpty ? "no agents found" : "agents: \(info.agents.joined(separator: ", "))"
                        )
                        RepoRootsCheck(host: row.name)
                    case let .needsAuth(detail):
                        check(false, "ssh needs your key: \(detail)", color: Theme.ask)
                        Text("Unlock or add your key (ssh-add), then ↩ checks again.").font(Theme.ui(12))
                            .foregroundStyle(Theme.fg3)
                    case .hostKeyChanged:
                        check(false, "host key changed: blocked", color: Theme.err)
                        Text(
                            "The key does not match known_hosts. Check it with the host's owner before connecting by hand."
                        )
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                    case .unknownHostKey:
                        check(false, "host key not known yet", color: Theme.block)
                        Text(
                            "Connect once in a terminal (ssh \(model.config.hosts[row.name]?.ssh ?? row.name)) to check and accept its key."
                        )
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                    case let .offline(reason, lastSeen):
                        check(false, "offline: \(reason)", color: Theme.fg3)
                        if let lastSeen {
                            Text("last seen \(Clock.relative(lastSeen))").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        }
                    case let .tailscale(issue):
                        TailscaleIssueView(issue: issue)
                    }
                } else if let machine = row.machine {
                    check(
                        machine.online,
                        machine.online ? "online on your tailnet" : "offline"
                            + (machine.lastSeen.map { ": last seen \(Clock.relative($0))" } ?? ""),
                        color: Theme.fg3
                    )
                    check(
                        machine.hasTailscaleSSH,
                        machine.hasTailscaleSSH
                            ? "Tailscale SSH: your tailnet identity logs you in, no key needed"
                            : "no Tailscale SSH: your own ssh keys log in",
                        color: Theme.fg3
                    )
                    Text(machine.dnsName).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).textSelection(.enabled)
                    Text(
                        "↩ adds it to config.toml as [hosts.\(row.name)] tailscale = \"\(machine.name)\" and checks it."
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("↩ adds it to config.toml as [hosts.\(row.name)] and checks it.").font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(18)
    }

    private func check(_ ok: Bool?, _ text: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ok == nil ? "◌" : ok! ? "✓" : "–").foregroundStyle(color ?? (ok == true ? Theme.done : Theme.fg3))
                .frame(width: 12)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(ok == false ? (color ?? Theme.fg2) : Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where heed looks for repos on a host that answers, and how many it found there; none says how to choose folders.
private struct RepoRootsCheck: View {
    @Environment(AppModel.self) private var model
    let host: String

    var body: some View {
        let roots = (model.config.hosts[host]?.repoRoots ?? HostConfig.defaultRepoRoots).joined(separator: ", ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch model.repoCount(on: host) {
            case nil:
                Text("◌").foregroundStyle(Theme.fg3).frame(width: 12)
                Text("looking for repos under \(roots)…").font(Theme.ui(12.5))
            case 0?:
                Text("–").foregroundStyle(Theme.block).frame(width: 12)
                (Text("no repos under \(roots): ").foregroundStyle(Theme.block)
                    + Text("⌃r chooses folders").foregroundStyle(Theme.fg2))
                    .font(Theme.ui(12.5)).fixedSize(horizontal: false, vertical: true)
            case let count?:
                Text("✓").foregroundStyle(Theme.done).frame(width: 12)
                Text("\(count) repo\(count == 1 ? "" : "s") under \(roots)").font(Theme.ui(12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Where are your projects on @host?": the folders found there with their repos, picked with space, a line to add one
/// by hand, and where worktrees go. ↩ writes them to config.toml; ⎋ leaves config as it is.
struct HostRootsView: View {
    @Environment(AppModel.self) private var model
    let chooser: HostRootsChooser

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .onTapGesture { model.cancelHostRootsChooser() }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where are your projects on @\(chooser.host)?").font(Theme.ui(15, weight: .semibold))
                    Text(
                        "Heed looks for repos in these folders, two levels deep. The ones holding repos are picked; space picks or drops one."
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chooser.rows.enumerated()), id: \.element.folder.path) { index, row in
                        line(index) {
                            Image(systemName: row.chosen ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12)).foregroundStyle(row.chosen ? Theme.done : Theme.fg3)
                            Text(row.folder.path).font(Theme.mono(12.5, weight: .semibold))
                                .foregroundStyle(row.chosen ? Theme.fg : Theme.fg2)
                            Spacer(minLength: 8)
                            Text(row.folder.repos.map { "\($0) repo\($0 == 1 ? "" : "s")" } ?? "added by you")
                                .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        }
                    }
                    if chooser.rows.isEmpty {
                        Text("No folders with repos found in the usual places.").font(Theme.ui(12))
                            .foregroundStyle(Theme.fg3).padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    line(chooser.addRow) {
                        Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.fg3).frame(width: 14)
                        if case let .folder(text) = chooser.editing {
                            Text(text + "▌").font(Theme.mono(12.5))
                        } else {
                            Text("add a folder…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        }
                        Spacer(minLength: 8)
                        KeyCap(text: "a")
                    }
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                line(chooser.worktreeRow) {
                    Text("worktrees go in").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                    if case let .worktreeRoot(text) = chooser.editing {
                        Text(text + "▌").font(Theme.mono(12.5))
                    } else {
                        Text(chooser.worktreeRoot).font(Theme.mono(12.5, weight: .semibold))
                    }
                    Spacer(minLength: 8)
                    KeyCap(text: "w")
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
                if let problem = chooser.problem {
                    Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.block)
                        .padding(.horizontal, 18).padding(.bottom, 8)
                }
                HStack(spacing: 14) {
                    Text("Saved to config.toml as [hosts.\(chooser.host)] repo_roots and worktree_root.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    Spacer()
                    Text("↩ save · ⎋ skip").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(14)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }

    private func line(_ index: Int, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(index == chooser.cursor ? Theme.bg3 : .clear)
            .overlay(alignment: .leading) { if index == chooser.cursor { Theme.block.frame(width: 2) } }
    }
}

/// What Tailscale needs before heed can reach a host over the tailnet, and how to get there.
private struct TailscaleIssueView: View {
    let issue: TailscaleIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch issue {
            case .notInstalled:
                line("Tailscale is not installed", color: Theme.block)
                hint("This host is on your tailnet. Install Tailscale on this Mac, then ↩ checks again:")
                ForEach(TailscaleCLI.install, id: \.self) { command in
                    Text(command).font(Theme.mono(11.5)).textSelection(.enabled).padding(.leading, 20)
                }
            case .off:
                line("Tailscale is off", color: Theme.block)
                hint("Turn it on from Tailscale in the menu bar, then ↩ checks again.")
            case let .needsLogin(url):
                line("Sign in to Tailscale", color: Theme.ask)
                hint(url == nil
                    ? "Sign in from Tailscale in the menu bar, then ↩ checks again."
                    : "↩ opens the sign-in page in your browser; sign in there, then ↩ checks again.")
            case let .checkAuth(url):
                line("Tailscale SSH wants you to confirm it is you", color: Theme.ask)
                hint(
                    "↩ opens \(URL(string: url)?.host ?? "the page") in your browser; confirm there, then ↩ checks again."
                )
            }
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("–").foregroundStyle(color).frame(width: 12)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(color)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
    }
}

/// How to install zmx (heed ships none): the lines for this machine, selectable, and where to read more.
struct ZmxInstallHint: View {
    let commands: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commands
                .isEmpty ? "Install zmx there, then ↩ checks again:" : "To install it there, then ↩ checks again:")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            ForEach(commands, id: \.self) { line in
                Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pane))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("or see \(ZmxInstall.site)").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.leading, 20)
    }
}

/// `gB` / `gR` with several places to go: the session's PRs and issues (or repos), numbered.
struct LinkPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: LinkPicker

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .onTapGesture { model.cancelLinkPicker() }
            VStack(alignment: .leading, spacing: 0) {
                Text(picker.title).font(Theme.ui(15, weight: .semibold)).padding(18)
                ForEach(Array(picker.links.enumerated()), id: \.element) { index, link in
                    // A heading where the kind changes: pull requests, then issues.
                    if index == 0 || kind(picker.links[index - 1]) != kind(link), let heading = kind(link) {
                        Text(heading).font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 18).padding(.top, index == 0 ? 0 : 8).padding(.bottom, 2)
                    }
                    HStack(spacing: 10) {
                        Text(index < 9 ? "\(index + 1)" : " ").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                            .frame(width: 12)
                        Image(systemName: icon(link)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint(link))
                        Text(link.label).font(Theme.mono(12.5, weight: .semibold))
                        Text(title(link)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(state(link)).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(index == picker.cursor ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if index == picker.cursor { Theme.block.frame(width: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(link, browser: true) }
                }
                HStack(spacing: 14) {
                    hint("1–9", "open")
                    hint("j k ↩", "move, open")
                    hint("o", "open ones")
                    hint("p", "open PRs")
                    hint("a", "all")
                    hint("⎋", "close")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.picker)
        }
    }

    private func kind(_ link: SessionLink) -> String? {
        switch link {
        case .pull: "Pull requests"
        case .issue: "Issues"
        case .repo: nil
        }
    }

    private func tint(_ link: SessionLink) -> Color {
        switch link {
        case let .pull(ref):
            switch model.github.pull(ref)?.state {
            case .open: Theme.done
            case .merged: Theme.ask
            case .closed: Theme.err
            case nil: Theme.fg3
            }
        case let .issue(ref): model.issueInfo[ref].map { $0.closed ? Theme.ask : Theme.done } ?? Theme.fg3
        case .repo: Theme.fg3
        }
    }

    private func icon(_ link: SessionLink) -> String {
        switch link {
        case .pull: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        case .repo: "folder"
        }
    }

    private func title(_ link: SessionLink) -> String {
        switch link {
        case let .pull(ref): model.github.pull(ref)?.title ?? ""
        case let .issue(ref): model.issue(for: ref)?.title ?? ""
        case .repo: ""
        }
    }

    private func state(_ link: SessionLink) -> String {
        switch link {
        case let .pull(ref): model.github.pull(ref).map { $0.state.rawValue.lowercased() } ?? ""
        case let .issue(ref): model.issueInfo[ref].map { $0.closed ? "closed" : "open" } ?? ""
        case .repo: ""
        }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: keys)
            Text(text).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
        }
    }
}
