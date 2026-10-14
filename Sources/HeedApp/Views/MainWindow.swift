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
                    case .pilot:
                        PilotView()
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
            ForEach(Array(AppView.allCases.enumerated()), id: \.element) { index, view in
                // A hairline between views: separate without boxing them in.
                if index > 0 { Theme.line.frame(width: 1, height: 14) }
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
            if let tutor = model.tutor { TutorPill(tutor: tutor) }
            if model.filtering {
                filterLine
            } else {
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
            if model.tutor == nil, !model.tutorProgress.done.contains(Tutor.lessonID(forView: model.view.rawValue)) {
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
        case .inbox, .issues, .prs, .pilot:
            let count = model.itemIDs(model.view).count
            return "\(count == 0 ? 0 : model.cursor(in: model.view) + 1)/\(count)"
        case .repos: return "\(model.worktreeRows.isEmpty ? 0 : model.repoCursor + 1)/\(model.worktreeRows.count)"
        case .history: return "\(model.historyRows.isEmpty ? 0 : model.historyCursor + 1)/\(model.historyRows.count)"
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

    private var hints: String {
        switch model.mode {
        case .normal where model.confirmation != nil: "y or ↩ confirm · n, ⎋ or q cancel"
        case .normal where model.importPicker != nil: "type to filter · ⌃n ⌃p move · ↩ import · ⎋ cancel"
        case .normal where model.pathImport != nil: "⇥ complete · ⌃n ⌃p choose · ⌃w up a folder · ↩ import · ⎋ cancel"
        case .normal where model.filtering: "words match anywhere · ⌃w word · ⌃u clear · ↩ keep · ⎋ clear"
        case .normal where model.overlay == .diff: "j k line · n hunk · ]f file · ⇥ scope · c commit · t split · gd close"
        case .normal where model.issueReader != nil: "s start session · a add to session · gB browser · ⎋ back"
        case .normal where model.reader != nil || model.overlay == .pr:
            "j k item · space queue · s send · m auto-feed · ]p next PR · gS session · ⎋ back"
        case .normal where model.view == .repos: "o start work here · v select · dd remove · r rescan · w issues · { } repo · / filter"
        case .normal where model.view == .history: "j k move · / filter · R reopen · O new from prompt · t outcome"
        case .normal where model.view == .inbox: "↩ read · space pick · v range · s start session · a add · x mark read · t unread/all · / filter"
        case .normal where model.view == .issues: "↩ read · space pick · s start session · t filter · ⇥ repo · w all/yours · / filter"
        case .normal where model.view == .prs: "↩ open · w watch · m green · zz pause · v select · gS session · r sync · / filter"
        case .normal where model.view == .pilot: "↩ open · w watch · m green · zz pause · v select · { } group · r sync · / filter"
        case .normal: "i insert · o start work · m pin · { } group · Iw import · : command · ? keys"
        case .insert: "⇧⎋ or \(KeyCapText.of(model.config.insertEscape)) normal · ⌘/ keys"
        case .visual where model.view == .pilot || model.view == .prs:
            "\(model.pickedIDs(model.view).count) selected · z pause or resume · space toggle · ⎋ cancel"
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
        .shadow(color: .black.opacity(0.5), radius: 20).shotRegion(.commandLine)
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
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyCap(text: "n")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelConfirmation() }
                    HStack(spacing: 6) {
                        Text(confirmation.accept).fontWeight(.semibold)
                        KeyCap(text: "y")
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
