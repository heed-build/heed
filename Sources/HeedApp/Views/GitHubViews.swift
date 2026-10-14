import HeedCore
import SwiftUI

/// Offline or partial-sync notice above the GitHub lists (design/screens/Empty.png).
struct SyncBanner: View {
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
            KeyCap(text: "r")
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

private struct KindBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Theme.mono(10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 52)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.14)))
    }
}

private struct Checkbox: View {
    let on: Bool

    var body: some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 13))
            .foregroundStyle(on ? Theme.block : Theme.fg3)
    }
}

/// The right-hand panel of Inbox and Issues: what `s` will start.
private struct PickedPanel: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: count > 1 ? "Start session from \(count) items" : "Start session from this item")
            Text(model.itemsPromptPreview.isEmpty ? "Nothing selected." : model.itemsPromptPreview)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.fg2)
                .lineLimit(14)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            Text("Start work opens with this prompt; repo, worktree and agent are guessed there.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Theme.line.frame(height: 1)
            keyRow("s", "start one session")
            keyRow("a", "add to the current session instead")
            if model.view == .inbox { keyRow("m", "mark read, no session") }
            keyRow("space v", "pick · pick a range")
            keyRow("o", "open in the browser")
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.inboxRows
        let picked = model.pickedIDs(.inbox)
        let cursor = model.cursor(in: .inbox)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(InboxFilter.allCases, id: \.self) { filter in
                            FilterChip(label: filter.rawValue, on: model.inboxFilter == filter)
                        }
                        KeyCap(text: "t")
                        Spacer()
                        FilterPill(view: .inbox)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44).shotRegion(.chips)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: model.filter(for: .inbox)
                            .isEmpty ? "Inbox zero." : "Nothing matches /\(model.filter(for: .inbox)).",
                        hintView: .inbox
                    ) { index in
                        let item = rows[index]
                        HStack(spacing: 10) {
                            RowNumber(index: index, cursor: cursor)
                            Checkbox(on: picked.contains(item.id))
                            KindBadge(text: item.kind.rawValue, tint: tint(item.kind))
                            RepoChip(repo: item.repo).fixedSize()
                            HStack(spacing: 4) {
                                Text(item.title).font(Theme.ui(13)).foregroundStyle(item.unread ? Theme.fg : Theme.fg3)
                                    .lineLimit(1)
                                if let number = item.number {
                                    Text(verbatim: "#\(number)").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                                        .fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.reasonText).font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize()
                            Text(Ages.short(item.updatedAt)).font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .rowStyle(isCursor: index == cursor, isPicked: picked.contains(item.id))
                    }
                }
                if geometry.size
                    .width >=
                    1100 { PickedPanel(count: max(picked.count, rows.isEmpty ? 0 : 1)).shotRegion(.pickedPanel) }
            }
        }
    }

    private func tint(_ kind: InboxItem.Kind) -> Color {
        switch kind {
        case .pr: Theme.busy
        case .issue: Theme.done
        case .ci: Theme.err
        default: Theme.fg2
        }
    }
}

struct IssuesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.issueRows
        let picked = model.pickedIDs(.issues)
        let cursor = model.cursor(in: .issues)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 900 { IssueRepoColumn().shotRegion(.issueRepos) }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(IssueFilter.allCases, id: \.self) { filter in
                            FilterChip(label: filter.rawValue, on: model.issueFilter == filter)
                        }
                        KeyCap(text: "t")
                        Spacer()
                        FilterPill(view: .issues)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44).shotRegion(.chips)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: emptyText,
                        hintView: .issues
                    ) { index in
                        let issue = rows[index]
                        HStack(spacing: 10) {
                            RowNumber(index: index, cursor: cursor)
                            Checkbox(on: picked.contains(issue.id))
                            RepoChip(repo: issue.repo).fixedSize()
                            HStack(spacing: 4) {
                                Text(issue.title).font(Theme.ui(13)).lineLimit(1)
                                Text(verbatim: "#\(issue.number)").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                                    .fixedSize()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if issue.assigned { InvolvementTag(text: "assigned") }
                            if issue.mentioned { InvolvementTag(text: "mentioned") }
                            ForEach(issue.labels.prefix(2), id: \.self) { label in
                                Text(label).font(Theme.mono(10.5)).foregroundStyle(Theme.fg2)
                                    .padding(.horizontal, 6)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                                    .fixedSize()
                            }
                            Text(Ages.short(issue.updatedAt)).font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .rowStyle(isCursor: index == cursor, isPicked: picked.contains(issue.id))
                    }
                }
                if geometry.size
                    .width >=
                    1300 { PickedPanel(count: max(picked.count, rows.isEmpty ? 0 : 1)).shotRegion(.pickedPanel) }
            }
        }
    }

    private var emptyText: String {
        let filter = model.filter(for: .issues)
        if !filter.isEmpty { return "Nothing matches /\(filter)." }
        switch model.issueFilter {
        case .all: return "No open issues assigned to you, mentioning you, or in repos showing all issues."
        case .assigned: return "No open issues assigned to you."
        case .mentioned: return "No open issues mentioning you."
        case .watched: return "No repos show all issues. w on an issue (I in Repos) turns it on for its repo."
        }
    }
}

/// The Issues repo column: repos with issues showing, most first. An eye marks repos that show every open issue;
/// the rest show only issues assigned to you or mentioning you.
private struct IssueRepoColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.issueRepoCounts
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Repos").padding(.horizontal, 16).padding(.vertical, 14)
            row(name: "All", count: repos.map(\.count).reduce(0, +), repo: nil)
            ListScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(repos, id: \.repo) { entry in
                        row(name: entry.repo.name, count: entry.count, repo: entry.repo)
                    }
                }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                keyRow("⇥", "next repo")
                keyRow("w", "all issues / only yours")
                HStack(spacing: 8) {
                    Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(Theme.fg2).frame(width: 18)
                    Text("shows all open issues").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                }
            }
            .padding(16)
        }
        .frame(width: 220)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func row(name: String, count: Int, repo: Repo?) -> some View {
        let selected = model.issueRepo == repo
        return HStack(spacing: 8) {
            if let repo { OrgTile(org: repo.org, color: repo.color, size: 16) }
            Text(name).font(Theme.mono(12.5)).foregroundStyle(selected ? Theme.fg : Theme.fg2)
                .lineLimit(1).truncationMode(.middle)
            if let repo, model.config.issues.visibility(repo) == .all {
                Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            }
            Spacer()
            Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(selected ? Theme.bg3 : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.pickIssueRepo(repo) }
    }

    private func keyRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            KeyCap(text: key).frame(width: 18)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}

private struct InvolvementTag: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.ui(11)).foregroundStyle(Theme.ask)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().strokeBorder(Theme.ask.opacity(0.5)))
            .fixedSize()
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
                            Text("CHECKS").frame(width: 130, alignment: .leading)
                            Text("REVIEW").frame(width: 150, alignment: .leading)
                            Text("PILOT").frame(width: 130, alignment: .leading)
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
                            pilot: model.pilotStatus(for: rows[index].ref),
                            green: model.pilot(for: rows[index].ref).green,
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
    let pilot: PilotStatus
    let green: AutoFeed
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
                    Text(pull.headBranch).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    if pull.isDraft { Text("draft").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                CheckBar(checks: pull.checks)
                Text(pull.checks.text).font(Theme.mono(11))
                    .foregroundStyle(pull.checks.failed > 0 ? Theme.err : Theme.fg3)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            Text(reviewText).font(Theme.ui(12.5)).foregroundStyle(reviewColor).lineLimit(1)
                .frame(width: 150, alignment: .leading)
            // Watched or not, and get it green's mode: `w` `m` `zz` act on the row (or the VISUAL picks).
            VStack(alignment: .leading, spacing: 3) {
                PilotMark(status: pilot)
                if pilot != .unwatched {
                    Text("green \(green.configName)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
            .frame(width: 130, alignment: .leading)
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

/// Segmented bar: green passed, red failed, blue running, grey skipped.
struct CheckBar: View {
    let checks: CheckSummary

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< min(segments.count, 12), id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).fill(segments[index]).frame(width: 12, height: 4)
            }
        }
    }

    private var segments: [Color] {
        Array(repeating: Theme.done, count: checks.passed) + Array(repeating: Theme.err, count: checks.failed)
            + Array(repeating: Theme.busy, count: checks.pending) + Array(
                repeating: Color(hex: 0x3A4047),
                count: checks.skipped
            )
    }
}

private struct PullDetail: View {
    @Environment(AppModel.self) private var model
    let pull: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "\(pull.ref.repo.name) #\(pull.ref.number)")
            Text(pull.title).font(Theme.ui(15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                CheckBar(checks: pull.checks)
                Text(pull.checks.text).font(Theme.mono(11.5))
                    .foregroundStyle(pull.checks.failed > 0 ? Theme.err : Theme.fg2)
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
            if let session = model.sessions.first(where: { $0.trackedPRs.contains(pull.ref) }) {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                    Text(session.title).font(Theme.ui(12.5))
                    Spacer()
                    KeyCap(text: "gS")
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
                KeyCap(text: "↩")
                Text("read here").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                KeyCap(text: "gB")
                Text("open in the browser").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }
}

/// An issue, read in the app (`go` or ↩ on an issue): what you would start a session from.
struct IssueReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let issue = model.issueReader {
            ListScroll {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        RepoChip(repo: issue.repo)
                        Text(verbatim: "#\(issue.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                        ForEach(issue.labels, id: \.self) { label in
                            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.fg2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().strokeBorder(Theme.line))
                        }
                        Spacer()
                        KeyCap(text: "go")
                        Text("close").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    Text(issue.title).font(Theme.ui(17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = issue.author {
                        Text("opened by \(author)").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    Group {
                        if issue.body.isEmpty {
                            Text("Not assigned to you, so only its title is synced. gB opens it on GitHub.")
                                .foregroundStyle(Theme.fg3)
                        } else {
                            Text((try? AttributedString(
                                markdown: issue.body,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            )) ?? AttributedString(issue.body))
                        }
                    }
                    .font(Theme.ui(13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { KeyCap(text: "s"); Text("start a session from it") }
                        HStack(spacing: 6) { KeyCap(text: "a"); Text("add it to this session") }
                        HStack(spacing: 6) { KeyCap(text: "gB"); Text("open on GitHub") }
                    }
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg2)
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
        }
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
                KeyCap(text: "/")
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
                        ForEach(0 ..< count, id: \.self) { index in
                            row(index)
                                .hint(hintView.flatMap { model.hintLabel(for: .row($0, index)) })
                                .id(ids[index])
                        }
                    }
                }
                .onChange(of: cursor) {
                    if ids.indices.contains(cursor) { proxy.scrollTo(ids[cursor]) }
                }
            }
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
