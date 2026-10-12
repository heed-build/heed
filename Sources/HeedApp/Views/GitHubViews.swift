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
                "Offline: showing what was synced \(syncedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never"). \(reason)",
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
    }
}

/// `4m`, `3h`, `2d`.
enum Ages {
    static func short(_ date: Date, now: Date = Date()) -> String {
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
                        Spacer()
                        KeyCap(text: "t")
                        Text("filter").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(count: rows.count, cursor: cursor, ids: rows.map(\.id), empty: "Inbox zero.") { index in
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
                if geometry.size.width >= 1100 { PickedPanel(count: max(picked.count, rows.isEmpty ? 0 : 1)) }
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
        let rows = model.github.issues
        let picked = model.pickedIDs(.issues)
        let cursor = model.cursor(in: .issues)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Assigned to you").font(Theme.ui(12.5, weight: .medium))
                        Spacer()
                        Text("\(rows.count) open").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: "No open issues assigned to you."
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
                if geometry.size.width >= 1100 { PickedPanel(count: max(picked.count, rows.isEmpty ? 0 : 1)) }
            }
        }
    }
}

struct PullRequestsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.github.pulls
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
                        }
                        .font(Theme.ui(10.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: "No open PRs of yours."
                    ) { index in
                        PullRow(
                            pull: rows[index],
                            index: index,
                            cursor: cursor,
                            session: model.sessions.first { $0.trackedPRs.contains(rows[index].ref) }
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
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(index == cursor ? Theme.bg3 : .clear)
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
            Text("The feedback queue and auto-feed arrive in step 7.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            Spacer()
            HStack(spacing: 10) {
                KeyCap(text: "o")
                Text("open in the browser").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }
}

// MARK: Shared list pieces

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
    let count: Int
    let cursor: Int
    let ids: [String]
    let empty: String
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        if count == 0 {
            Text(empty).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0 ..< count, id: \.self) { index in
                            row(index).id(ids[index])
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
    func rowStyle(isCursor: Bool, isPicked: Bool) -> some View {
        padding(.horizontal, 16)
            .frame(height: 44)
            .background(isPicked ? Theme.block.opacity(0.16) : isCursor ? Theme.bg3 : .clear)
    }
}
