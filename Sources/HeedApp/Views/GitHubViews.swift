import HeedCore
import SwiftUI

/// Offline or partial-sync notice above the GitHub lists (design/screens/Empty.png).
struct SyncBanner: View {
    @Environment(AppModel.self) private var model
    let status: SyncStatus
    let syncedAt: Date?

    var body: some View {
        switch status {
        case let .offline(reason):
            banner(
                "Offline: showing what was synced \(syncedAt.map { Clock.relative($0, named: true) } ?? "never"). \(reason)",
                tint: Theme.block
            )
        case .partial:
            // Items withheld by orgs the gh token is not authorized for: shown as a count in the title bar, no banner.
            EmptyView()
        case .never:
            banner("Not synced yet: gh is being asked.", tint: Theme.fg3)
        case .ok:
            EmptyView()
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(tint)
            Text(text).foregroundStyle(tint).lineLimit(2)
            Spacer()
            KeyCap(text: model.keyText(for: "github.sync"))
            Text("sync").foregroundStyle(Theme.fg3)
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .shotRegion(.syncBanner)
    }
}

/// `4m`, `3h`, `2d`.
enum Ages {
    static func short(_ date: Date, now: Date = Clock.now) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

struct PullRequestsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.pullRows
        let cursor = model.cursor(in: .prs)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 34)
                        Group {
                            Text("PR").frame(width: 210, alignment: .leading)
                            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
                            Text("CHECKS").frame(width: 200, alignment: .leading).padding(.trailing, 12)
                            Text("REVIEW").frame(width: 150, alignment: .leading)
                            Text("WATCH").frame(width: 180, alignment: .leading)
                        }
                        .font(Theme.ui(10.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.fg3)
                        FilterPill(view: .prs).padding(.leading, 8)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: model.filter(for: .prs)
                            .isEmpty ? "No open PRs of yours." : "Nothing matches /\(model.filter(for: .prs)).",
                        hintView: .prs
                    ) { index in
                        PullRow(
                            pull: rows[index],
                            index: index,
                            cursor: cursor,
                            session: model.sessions.first { $0.trackedPRs.contains(rows[index].ref) },
                            swarm: model.swarmPulls[rows[index].ref.description],
                            pilot: model.pilotStatus(for: rows[index].ref),
                            green: model.pilot(for: rows[index].ref).green,
                            merge: model.pilot(for: rows[index].ref).merge,
                            ready: model.readyToMerge(rows[index].ref),
                            isPicked: model.pickedIDs(.prs).contains(rows[index].id)
                        )
                    }
                }
                if geometry.size.width >= 1100, rows.indices.contains(cursor) { PullDetail(pull: rows[cursor]) }
            }
        }
    }
}

private struct PullRow: View {
    let pull: PullRequest
    let index: Int
    let cursor: Int
    let session: Session?
    /// Its swarm's merge order, when a swarm opened it.
    var swarm: SwarmPull?
    let pilot: PilotStatus
    let green: AutoFeed
    var merge: MergeMode = .off
    /// Meets every merge requirement while get it merged is off.
    var ready = false
    let isPicked: Bool

    var body: some View {
        HStack(spacing: 0) {
            RowNumber(index: index, cursor: cursor).frame(width: 34, alignment: .leading)
            HStack(spacing: 6) {
                RepoChip(repo: pull.ref.repo)
                Text(verbatim: "#\(pull.ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2).fixedSize()
            }
            .frame(width: 210, alignment: .leading)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(pull.title).font(Theme.ui(13)).lineLimit(1)
                HStack(spacing: 5) {
                    if let session { StateGlyph(state: session.state.state, size: 10) }
                    if let swarm {
                        SwarmPullLine(pull: swarm)
                    } else {
                        Text(pull.headBranch).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                    if pull.isDraft { Text("draft").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                CheckBar(checks: pull.checks)
                CheckText(checks: pull.checks).font(Theme.ui(11.5)).lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            .padding(.trailing, 12)
            Text(reviewText).font(Theme.ui(12.5)).foregroundStyle(reviewColor).lineLimit(1)
                .frame(width: 150, alignment: .leading)
            // Watched or not, and get it green's mode: `w` `m` `zz` act on the row (or the VISUAL picks).
            VStack(alignment: .leading, spacing: 3) {
                PilotMark(status: pilot)
                if ready {
                    Text("ready to merge").font(Theme.mono(10.5)).foregroundStyle(Theme.done)
                } else if pilot != .unwatched {
                    Text("green \(green.configName) · merge \(merge.configName)").font(Theme.mono(10.5))
                        .foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(isPicked ? Theme.block.opacity(0.18) : index == cursor ? Theme.bg3 : .clear)
    }

    private var reviewText: String {
        var text = pull.review?.text ?? "no review yet"
        if pull.unresolvedThreads > 0 { text += " · \(pull.unresolvedThreads) open" }
        return text
    }

    private var reviewColor: Color {
        switch pull.review {
        case .approved: Theme.done
        case .changesRequested: Theme.block
        default: Theme.fg2
        }
    }
}

/// Green passed, red failed, blue running, grey skipped, across the width it is given. Up to 12 checks it draws
/// one segment per check; past that one segment per state, as wide as its share and never too thin to see.
struct CheckBar: View {
    let checks: CheckSummary

    private static let skippedColor = Color(hex: 0x3A4047)
    private static let gap: CGFloat = 2
    private static let thinnest: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: Self.gap) {
                ForEach(Array(segments(width: geometry.size.width).enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 1).fill(segment.color).frame(width: segment.width, height: 4)
                }
            }
        }
        .frame(height: 4)
    }

    private var counts: [(count: Int, color: Color)] {
        [
            (checks.passed, Theme.done), (checks.failed, Theme.err), (checks.pending, Theme.busy),
            (checks.skipped, Self.skippedColor),
        ].filter { $0.count > 0 }
    }

    private func segments(width: CGFloat) -> [(color: Color, width: CGFloat)] {
        let all = counts.reduce(0) { $0 + $1.count }
        guard all > 0 else { return [] }
        if all <= 12 {
            let each = max(1, (width - Self.gap * CGFloat(all - 1)) / CGFloat(all))
            return counts.flatMap { Array(repeating: ($0.color, each), count: $0.count) }
        }
        let room = width - Self.gap * CGFloat(counts.count - 1)
        var widths = counts.map { max(Self.thinnest, room * CGFloat($0.count) / CGFloat(all)) }
        // What the thin ones were rounded up by comes off the widest.
        if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] -= widths.reduce(0, +) - room
        }
        return zip(counts, widths).map { ($0.color, max(1, $1)) }
    }
}

/// A check summary with each part in its state's colour: `10/12 passed · lint failed · 1 running`.
struct CheckText: View {
    let checks: CheckSummary

    var body: some View { Self.text(checks) }

    static func text(_ checks: CheckSummary) -> Text {
        checks.parts.enumerated().reduce(Text(verbatim: "")) { text, item in
            let part = Text(verbatim: item.element.text).foregroundStyle(color(item.element))
            return item.offset == 0 ? part : text + Text(verbatim: " · ").foregroundStyle(Theme.fg3) + part
        }
    }

    private static func color(_ part: CheckSummary.Part) -> Color {
        switch part {
        case .passed: Theme.fg2
        case .failed: Theme.err
        case .running: Theme.busy
        case .skipped, .none: Theme.fg3
        }
    }
}

private struct PullDetail: View {
    @Environment(AppModel.self) private var model
    let pull: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "\(pull.ref.repo.name) #\(pull.ref.number)")
            Text(pull.title).font(Theme.ui(15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                CheckBar(checks: pull.checks).frame(width: 280)
                CheckText(checks: pull.checks).font(Theme.mono(11.5))
            }
            if !pull.checks.failedNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Failing")
                    ForEach(pull.checks.failedNames, id: \.self) { name in
                        Text("✕ \(name)").font(Theme.mono(12)).foregroundStyle(Theme.err)
                    }
                }
            }
            Text(
                "Review: \(pull.review?.text ?? "none yet")\(pull.unresolvedThreads > 0 ? " · \(pull.unresolvedThreads) unresolved threads" : "")"
            )
            .font(Theme.ui(12.5))
            .foregroundStyle(Theme.fg2)
            // What the pilot does for it: watching, get it green and get it merged, and merging ahead of time.
            VStack(alignment: .leading, spacing: 6) {
                Text(model.pilotLine(for: pull.ref, mentionsRun: false)).font(Theme.mono(11))
                    .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                if pull.state == .open {
                    PilotGreenLine(ref: pull.ref)
                    PilotPlanLine(ref: pull.ref)
                    PilotMergeLine(ref: pull.ref)
                }
            }
            if let session = model.sessions.first(where: { $0.trackedPRs.contains(pull.ref) }) {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                    Text(session.title).font(Theme.ui(12.5))
                    Spacer()
                    KeyCap(text: model.keyText(for: "pr.session"))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
            } else {
                Text("No session tracks this PR. Sessions pick PRs up by branch, or via heed pr add.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 10) {
                KeyCap(text: model.keyText(for: "open.reader"))
                Text("read here").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                KeyCap(text: model.keyText(for: "open.browser"))
                Text("open in the browser").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }
}

/// An issue, read in the app (`go` or ↩ on an issue): what you would start a session from. Its body and comments
/// are GitHub's own rendering (`ThreadConversationView`); until they arrive, the synced text.
struct IssueReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let issue = model.issueReader {
            let conversation = model.conversation(issue.repo, issue.number)
            ListScroll {
                VStack(alignment: .leading, spacing: 18) {
                    ThreadHeader(
                        repo: issue.repo, kind: .issue, number: issue.number,
                        title: conversation?.title ?? issue.title, author: conversation?.author?.login ?? issue.author,
                        openedAt: conversation?.createdAt, chips: chips(issue, conversation),
                        actions: [
                            .init(command: "items.start", label: "Start a session", scope: "issue"),
                            .init(command: "items.add", label: "Add to this session", scope: "issue"),
                            .init(command: "open.browser", label: "GitHub", scope: "issue"),
                            .init(command: "overlay.close", label: "Close", scope: "issue"),
                        ]
                    )
                    Theme.line.frame(height: 1)
                    if let conversation {
                        ThreadConversationView(
                            conversation: conversation, seenAt: model.seenAt(issue.repo, issue.number)
                        )
                    } else {
                        fallback(issue)
                    }
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
        }
    }

    private func chips(_ issue: Issue, _ conversation: ThreadConversation?) -> [ThreadHeader.Chip] {
        let state = conversation?.stateText ?? "open"
        var chips = [ThreadHeader.Chip(text: state, tint: state == "open" ? Theme.done : Theme.ask)]
        if issue.assigned { chips.append(.init(text: "assigned to you", tint: Theme.block)) }
        if issue.mentioned { chips.append(.init(text: "mentions you", tint: Theme.block)) }
        chips += (conversation?.labels ?? issue.labels).map { ThreadHeader.Chip(text: $0) }
        return chips
    }

    /// What there is before the conversation loads (or when it cannot): the synced text, and why.
    @ViewBuilder private func fallback(_ issue: Issue) -> some View {
        let key = ThreadConversation.key(repo: issue.repo, number: issue.number)
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.body.isEmpty ? "Not assigned to you, so only its title is synced." : issue.body)
                .font(Theme.ui(13)).foregroundStyle(issue.body.isEmpty ? Theme.fg3 : Theme.fg)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error = model.conversationErrors[key] {
                Text("Could not load the thread: \(error). gB opens it on GitHub.").font(Theme.ui(12))
                    .foregroundStyle(Theme.err)
            } else if model.conversationsLoading.contains(key) {
                Text("Loading the thread…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

// MARK: Shared list pieces

/// What `/` filters this view by. Typing happens in the status bar; the pill only shows the result, lights up while
/// the filter is being typed, and clears on click.
struct FilterPill: View {
    @Environment(AppModel.self) private var model
    let view: AppView

    var body: some View {
        pill.shotRegion(.filterPill)
    }

    @ViewBuilder private var pill: some View {
        let text = model.filter(for: view)
        let typing = model.filtering && model.view == view
        if text.isEmpty, !typing {
            HStack(spacing: 6) {
                KeyCap(text: model.keyText(for: "session.filter"))
                Text("filter").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        } else {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                    .foregroundStyle(typing ? Theme.ask : Theme.fg3)
                Text(text.isEmpty ? "…" : text).font(Theme.mono(12)).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .leading)
                if !text.isEmpty {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.fg3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearFilter(view) }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(typing ? Theme.ask.opacity(0.12) : Theme.bg3))
            .overlay(Capsule().strokeBorder(typing ? Theme.ask.opacity(0.6) : Theme.line))
            .fixedSize()
        }
    }
}

struct FilterChip: View {
    let label: String
    let on: Bool

    var body: some View {
        Text(label)
            .font(Theme.ui(12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.ink : Theme.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.inverse : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.line))
            .fixedSize()
    }
}

struct RowNumber: View {
    let index: Int
    let cursor: Int

    var body: some View {
        Text("\(index == cursor ? index + 1 : abs(index - cursor))")
            .font(Theme.mono(11, weight: index == cursor ? .bold : .regular))
            .foregroundStyle(index == cursor ? Theme.fg : Theme.fg3)
            .frame(width: 24, alignment: .trailing)
    }
}

/// A scrolling list that keeps the cursor row in view.
struct ListBody<Row: View>: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let cursor: Int
    let ids: [String]
    let empty: String
    /// The view whose rows get hint labels in HINT mode.
    var hintView: AppView?
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        rows.shotRegion(.list)
    }

    @ViewBuilder private var rows: some View {
        if count == 0 {
            Text(empty).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ListScroll {
                    ListStack(spacing: 0) {
                        // Keyed by row id, not position: under a filter the same position holds another row, and a
                        // row keyed by position kept the tap handler of the one it replaced.
                        ForEach(Array(ids.prefix(count).enumerated()), id: \.element) { index, id in
                            row(index)
                                .hint(hintView.flatMap { model.hintLabel(for: .row($0, index)) })
                                .contentShape(Rectangle())
                                .onTapGesture { if let hintView { model.clickRow(hintView, index) } }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if let hintView { model.clickRow(hintView, index, open: true) }
                                })
                                .rightClickMenu { hintView.map { model.rightClickRow($0, index) } ?? false } _: {
                                    hintView.map { model.rowMenu($0, index) } ?? []
                                }
                                .id(id)
                        }
                    }
                }
                .onChange(of: cursor) { reveal(proxy) }
            }
        }
    }
}

private extension ListBody {
    /// Scrolls the cursor row into view. Rows differ in height (section headers, summaries, wrapped tags), and a lazy
    /// stack only estimates the offset of rows it has not laid out, so the first jump can land short of the row; a
    /// second one, once the rows around it exist, settles on it.
    func reveal(_ proxy: ScrollViewProxy) {
        guard ids.indices.contains(cursor) else { return }
        let id = ids[cursor]
        proxy.scrollTo(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard ids.indices.contains(cursor), ids[cursor] == id else { return }
            proxy.scrollTo(id)
        }
    }
}

extension View {
    /// A HINT label over the row's leading edge.
    func hint(_ label: String?) -> some View {
        overlay(alignment: .leading) {
            if let label { HintBadge(label: label).padding(.leading, 6) }
        }
    }

    func rowStyle(isCursor: Bool, isPicked: Bool) -> some View {
        padding(.horizontal, 16)
            .frame(height: 44)
            .background(isPicked ? Theme.block.opacity(0.16) : isCursor ? Theme.bg3 : .clear)
    }
}
