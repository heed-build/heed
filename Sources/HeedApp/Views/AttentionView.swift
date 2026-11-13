import HeedCore
import SwiftUI

/// `gm`: what wants you (GitHub threads, agents, goals), in tabs with counts; the list on the left, in For you in
/// sections by what it asks of you (New since you last looked, Waiting on you, Mentioned before); the item under the
/// cursor on the right: a thread in full (its header, actions, and the conversation with what you read folded), an
/// agent or a goal item with its card. The line at the foot says what Attention has of GitHub; a click opens Coverage
/// in the reader's place.
struct AttentionView: View {
    @Environment(AppModel.self) private var model
    /// The list's share of the width, dragged on the divider; kept between launches.
    @AppStorage("attention.listShare") private var storedShare = 0.42
    @State private var dragStart: Double?

    private var share: Double { ShotMode.active ? 0.42 : min(max(storedShare, 0.28), 0.62) }

    var body: some View {
        let listing = model.attentionListing
        let rows = listing.rows
        let cursor = model.cursor(in: .attention)
        let picked = model.pickedIDs(.attention)
        GeometryReader { geometry in
            let split = geometry.size.width >= 1000
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    AttentionTabs().shotRegion(.attentionTabs)
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    if let note = model.github.teams.note { TeamsNote(text: note) }
                    // In the space left above the coverage line, however long the list.
                    Color.clear.overlay(alignment: .top) {
                        list(listing, cursor: cursor, picked: picked, compact: split)
                    }
                    .clipped()
                    CoverageLine(coverage: model.attentionCoverage)
                }
                .frame(
                    width: split ? (geometry.size.width * share).rounded() : geometry.size.width,
                    height: geometry.size.height
                )
                .shotRegion(.attentionList)
                if split {
                    divider(width: geometry.size.width)
                    Group {
                        if model.overlay == .coverage {
                            CoverageView(coverage: model.attentionCoverage)
                        } else if let helper = model.visibleHelper {
                            // The helper you approved, in a split under the reader (zo: the whole column).
                            VStack(spacing: 0) {
                                if !model.helpers.zoomed,
                                   let entry = rows.indices.contains(cursor) ? rows[cursor] : nil
                                {
                                    AttentionReader(entry: entry).id(entry.id)
                                        .frame(height: (geometry.size.height * 0.34).rounded(), alignment: .top)
                                        .clipped()
                                    Theme.line.frame(height: 1)
                                }
                                HelperSplit(helper: helper, compact: true)
                            }
                        } else if let entry = rows.indices.contains(cursor) ? rows[cursor] : nil {
                            if entry.item.kind == .pr || entry.item.kind == .issue,
                               entry.item.repo != nil, entry.item.number != nil
                            {
                                AttentionReader(entry: entry).id(entry.id)
                            } else {
                                AttentionDetail(entry: entry).id(entry.id)
                            }
                        } else {
                            Text(listing.sections.isEmpty ? "" : "Nothing under the cursor.")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.bg2)
                    .shotRegion(.attentionDetail)
                }
            }
        }
    }

    /// The line between list and reader; dragging it moves the split.
    private func divider(width: CGFloat) -> some View {
        Theme.line.frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        let start = dragStart ?? share
                        dragStart = start
                        storedShare = min(max(start + drag.translation.width / max(width, 1), 0.28), 0.62)
                    }.onEnded { _ in dragStart = nil })
            }
    }

    private func list(
        _ listing: AttentionListing, cursor: Int, picked: Set<String>, compact: Bool
    ) -> some View {
        let rows = listing.rows
        return Group {
            if rows.isEmpty, let folded = listing.sections.first(where: \.folded) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionRow(section: folded, listing: listing)
                    Text(emptyText).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 16).padding(.top, 18)
                    Spacer(minLength: 0)
                }
            } else {
                ListBody(
                    count: rows.count, cursor: cursor, ids: rows.map(\.id), empty: emptyText, hintView: .attention
                ) { index in
                    VStack(alignment: .leading, spacing: 0) {
                        header(above: index, listing: listing)
                        AttentionRow(
                            entry: rows[index], index: index, cursor: cursor,
                            preview: preview(rows[index]), isNew: model.attentionIsNew(rows[index].item),
                            isPicked: picked.contains(rows[index].id), compact: compact,
                            nextStep: model.proposedStep(for: rows[index].item)
                        )
                        // A folded section after the last row still says what it holds.
                        if index == rows.count - 1 {
                            ForEach(listing.sections(startingAt: rows.count), id: \.kind) { section in
                                SectionRow(section: section, listing: listing)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func header(above index: Int, listing: AttentionListing) -> some View {
        let rows = listing.rows
        let sections = listing.sections(startingAt: index).filter { $0.kind != .all }
        if !sections.isEmpty {
            ForEach(sections, id: \.kind) { SectionRow(section: $0, listing: listing) }
        } else if listing.section(.all) != nil {
            // The other tabs: by when, as before.
            let section = Self.section(rows[index].item.updatedAt)
            if !rows[index].pinned,
               index == 0 || rows[index - 1].pinned || Self.section(rows[index - 1].item.updatedAt) != section
            {
                timeHeader(section)
            } else if rows[index].pinned, index == 0 {
                timeHeader("Pinned")
            }
        }
    }

    private func timeHeader(_ title: String) -> some View {
        SectionHeader(title: title).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func preview(_ entry: AttentionEntry) -> AttentionPreview? {
        let item = entry.item
        return AttentionPreview.of(
            item, detail: model.detail(of: item), summary: model.summaryPreview(item),
            isNew: model.attentionIsNew(item), seenAt: model.attention.seen.threads[item.id]
        )
    }

    /// `Now` (the last hour), `Earlier today`, `Yesterday`, `Older`.
    static func section(_ date: Date) -> String {
        let age = Clock.now.timeIntervalSince(date)
        if age < 3600 { return "Now" }
        if Calendar.current.isDate(date, inSameDayAs: Clock.now) { return "Earlier today" }
        if age < 2 * 86400 { return "Yesterday" }
        return "Older"
    }

    private var emptyText: String {
        let text = model.filter(for: .attention)
        if !text.isEmpty { return "Nothing matches /\(text)." }
        return switch model.attention.filter {
        case .forYou: "Nothing wants you. Review requests, mentions, assignments and failing checks on your PRs "
            + "land here as GitHub syncs (\(model.keyText(for: "github.sync", in: "attention")) syncs now); rules in "
            + "Settings › Attention decide what counts."
        case .muted: "Nothing muted. M mutes a thread; an ignore rule mutes what it matches."
        default: "Nothing here. \(model.keyText(for: "attention.filter", in: "attention")) steps through the tabs."
        }
    }
}

/// A For you section's header: `NEW SINCE 09:45` with `X all done · 5`, `WAITING ON YOU 4`, `MENTIONED BEFORE`
/// with `6 open · folded`; each right-hand part runs its command on a click.
private struct SectionRow: View {
    @Environment(AppModel.self) private var model
    let section: AttentionListing.Section
    let listing: AttentionListing

    var body: some View {
        HStack(spacing: 8) {
            SectionHeader(title: title, tint: section.kind == .new ? Theme.busy : Theme.fg3)
            Spacer(minLength: 8)
            switch section.kind {
            case .new:
                KeyHint("attention.done.new", scope: "attention", spacing: 5, label: "all done · \(section.total)")
            case .before:
                KeyHint(
                    "attention.fold", scope: "attention", spacing: 5,
                    label: "\(section.total) open · \(section.folded ? "folded" : "fold")"
                )
            default:
                Text("\(section.total)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 7)
        .contentShape(Rectangle())
    }

    private var title: String {
        switch section.kind {
        case .new:
            guard let left = model.attention.sectionSeen.leftAt else { return "New" }
            let day = Calendar.current.isDate(left, inSameDayAs: Clock.now)
            return "New since " + left.formatted(date: day ? .omitted : .abbreviated, time: .shortened)
        case .waiting: return "Waiting on you"
        case .before: return "Mentioned before"
        case .all: return ""
        }
    }
}

/// The tabs over the list: For you, Reviews, Mentions, My PRs, Agents, Everything, each with its count; Muted after
/// them, quieter; CI or Issues while one of those is open (`view.attention ci`, `gi`).
private struct AttentionTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.attentionCounts
        let current = model.attention.filter
        let extra = AttentionFilter.cycle.contains(current) ? [] : [current]
        HStack(alignment: .center, spacing: 8) {
            FlowLayout(spacing: 2, lineSpacing: 2) {
                ForEach(AttentionFilter.cycle + extra, id: \.self) { tab in
                    tabView(tab, count: counts[tab] ?? 0, on: current == tab)
                }
            }
            Spacer(minLength: 0)
            if !model.filter(for: .attention).isEmpty || model.filtering { FilterPill(view: .attention) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func tabView(_ tab: AttentionFilter, count: Int, on: Bool) -> some View {
        let quiet = tab == .muted
        return HStack(spacing: 5) {
            Text(tab.title).font(Theme.ui(quiet ? 12 : 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.fg : quiet ? Theme.fg3 : Theme.fg2)
            if count > 0 {
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(tab == .forYou && on ? Theme.block : Theme.fg3)
            }
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.bg3 : .clear))
        .clickRuns(CommandInvocation(name: "attention.filter", arguments: [tab.rawValue]))
    }
}

/// The foot of the list: what heed has of what GitHub has, in a line (amber when something is missing), and while the
/// ahead queue runs "summarizing 2 of 5"; a click opens Coverage in the reader's place (`:attention.coverage`).
private struct CoverageLine: View {
    @Environment(AppModel.self) private var model
    let coverage: AttentionCoverage

    var body: some View {
        let tint = coverage.mismatch ? Theme.block : Theme.fg3
        HStack(spacing: 8) {
            Image(systemName: coverage.mismatch ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(coverage.mismatch ? tint : Theme.done)
            Text(coverage.line).foregroundStyle(coverage.mismatch ? Theme.block : Theme.fg2).lineLimit(1)
            Spacer(minLength: 8)
            // The ahead queue at work, beside the trust line.
            if let progress = model.attention.summaryProgress, progress.total > 0 {
                Text(progress.text).foregroundStyle(Theme.busy).lineLimit(1).fixedSize()
                    .help("Catch-up summaries for New, written ahead ([attention] summaries)")
                Text("·").foregroundStyle(Theme.dim)
            }
            Text(model.overlay == .coverage ? "close" : "coverage").foregroundStyle(Theme.fg3)
        }
        .font(Theme.ui(11.5))
        .padding(.horizontal, 16)
        .frame(height: 30)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: "attention.coverage"))
        .shotRegion(.attentionCoverage)
    }
}

/// Coverage, in the reader's place: each source with what heed fetched against what GitHub says it has, where the
/// items went, and when it was fetched.
private struct CoverageView: View {
    @Environment(AppModel.self) private var model
    let coverage: AttentionCoverage

    var body: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Coverage").font(Theme.ui(18, weight: .semibold))
                    Text(coverage.mismatch ? "Attention is missing some of what GitHub has." : coverage.line)
                        .font(Theme.ui(12.5)).foregroundStyle(coverage.mismatch ? Theme.block : Theme.fg2)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        ForEach([
                            "Source",
                            "Fetched",
                            "GitHub has",
                            "Listed",
                            "Folded",
                            "Done",
                            "Snoozed",
                            "Muted",
                            "Fetched at",
                        ], id: \.self) { title in
                            SectionHeader(title: title)
                        }
                    }
                    Theme.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(coverage.rows, id: \.source) { row in
                        GridRow {
                            Text(row.source.title).font(Theme.ui(12.5, weight: .medium))
                            Text("\(row.fetched)\(row.capped ? "+" : "")")
                                .foregroundStyle(row.mismatch ? Theme.block : Theme.fg)
                            Text(row.total.map(String.init) ?? "–").foregroundStyle(Theme.fg2)
                            count(row, .listed)
                            count(row, .folded)
                            count(row, .done)
                            count(row, .snoozed)
                            Text(number(row.count(.muted) + row.count(.hiddenByRule))).foregroundStyle(Theme.fg2)
                            Text(row.fetchedAt.map { Ages.long($0) } ?? "–").foregroundStyle(Theme.fg3)
                        }
                        .font(Theme.mono(12))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { line in
                        Text(line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 16) {
                    KeyHint("github.sync", scope: "attention", label: "sync now", color: Theme.fg2)
                    KeyHint("attention.coverage", key: "⎋", scope: "attention", label: "close", color: Theme.fg2)
                }
            }
            .padding(24)
        }
    }

    private func count(_ row: AttentionCoverage.Row, _ fate: AttentionCoverage.Fate) -> some View {
        Text(number(row.count(fate))).foregroundStyle(Theme.fg2)
    }

    private func number(_ value: Int) -> String { value == 0 ? "·" : "\(value)" }

    private var notes: [String] {
        var lines = [
            "Heed reads every unread notification up to \(GitHub.notificationCap), keeps read ones 30 days, and "
                + "\(GitHub.issueSearchCap) issues per search, newest first.",
            "Muted counts what you muted and what an ignore rule hides, as the Muted tab lists it: "
                + "\(coverage.muted), remembered ones included (the rows count only what the last sync brought).",
        ]
        if coverage.samlHidden > 0 {
            lines.append("\(coverage.samlHidden) withheld by SAML: authorize the GitHub CLI for that org.")
        }
        return lines
    }
}

/// Without gh's `read:org` scope: team mentions are not attributed.
private struct TeamsNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3").foregroundStyle(Theme.fg3)
            Text(text).foregroundStyle(Theme.fg2).lineLimit(2)
            Spacer()
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// A two-letter mark for what an item is: `PR`, `IS`, `CI`, `AG`, …
private struct KindMark: View {
    let item: AttentionItem

    var body: some View {
        Text(text)
            .font(Theme.mono(9.5, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
    }

    private var text: String {
        switch item.kind {
        case .pr: "PR"
        case .issue: "IS"
        case .ci: "CI"
        case .release: "RL"
        case .discussion: "DI"
        case .agent: "AG"
        case .goal: "GO"
        case .other: "··"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .pr: Theme.busy
        case .issue: Theme.done
        case .ci: Theme.err
        case .agent, .goal: Theme.ask
        default: Theme.fg2
        }
    }
}

/// Why it is here, as small tags; a boosted reason in amber, with the weight.
struct ReasonTag: View {
    let text: String
    var tint = Theme.fg2
    var filled = false

    var body: some View {
        Text(text).font(Theme.mono(10.5)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(filled ? tint.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.45)))
            .fixedSize()
    }
}

private struct AttentionRow: View {
    let entry: AttentionEntry
    let index: Int
    let cursor: Int
    let preview: AttentionPreview?
    /// Something from someone else since you last looked: the blue dot.
    let isNew: Bool
    let isPicked: Bool
    /// Beside the reader: one line of reasons and preview under the title.
    var compact = true
    /// heed's next step for it, when it has one: the row's last line.
    var nextStep: NextStep?

    var body: some View {
        let item = entry.item
        HStack(alignment: .top, spacing: 8) {
            RowNumber(index: index, cursor: cursor).padding(.top, 2)
            Circle().fill(isNew ? Theme.busy : .clear).frame(width: 7, height: 7).padding(.top, 6)
            KindMark(item: item)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let repo = item.repo { RepoChip(repo: repo).fixedSize() }
                    if let number = item.number {
                        Text(verbatim: "#\(number)").font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize()
                    }
                    if let state = item.agentState { StateGlyph(state: state, size: 10) }
                    Text(item.title).font(Theme.ui(13, weight: isNew || item.kind == .agent ? .semibold : .regular))
                        .foregroundStyle(entry.lowered ? Theme.fg3 : Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Ages.short(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).fixedSize()
                }
                if compact {
                    HStack(spacing: 6) {
                        tags(limit: 2)
                        previewText.lineLimit(1)
                    }
                } else {
                    previewText.lineLimit(2)
                    FlowLayout(spacing: 5) { tags(limit: nil) }
                }
                if let step = nextStep { NextStepLine(step: step) }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .leading) {
            if index == cursor { Theme.block.frame(width: 2) }
        }
        .background(isPicked ? Theme.block.opacity(0.16) : index == cursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }

    /// Why it is here: pinned, the boosted reason with its weight, the others (at most `limit` in all), teams, and
    /// lowered, muted or snoozed.
    @ViewBuilder private func tags(limit: Int?) -> some View {
        let reasons = shownReasons(limit: limit)
        if entry.pinned { ReasonTag(text: "pinned", tint: Theme.block, filled: true) }
        if entry.weight > 0 {
            ReasonTag(
                text: String(repeating: "▲", count: entry.weight) + " " + leadReason, tint: Theme.block, filled: true
            )
        }
        ForEach(reasons, id: \.self) { reason in
            ReasonTag(text: reason.text, tint: reason.passive ? Theme.fg3 : reason.waits ? Theme.block : Theme.fg2)
        }
        if let limit, hiddenReasons(limit: limit) > 0 {
            Text("+\(hiddenReasons(limit: limit))").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).fixedSize()
        }
        ForEach(entry.item.teams.sorted().prefix(limit ?? .max), id: \.self) { team in
            ReasonTag(text: "@\(team)", tint: Theme.ask)
        }
        if entry.lowered { ReasonTag(text: "lowered", tint: Theme.fg3) }
        if entry.muted { ReasonTag(text: "muted", tint: Theme.fg3) }
        if let until = entry.mark.snoozedUntil, until > Clock.now { ReasonTag(text: "snoozed", tint: Theme.fg3) }
    }

    @ViewBuilder private var previewText: some View {
        switch preview {
        case let .comment(author, text):
            (Text("\(author): ").foregroundStyle(Theme.fg2) + Text("“\(text)”").foregroundStyle(Theme.fg2))
                .font(Theme.ui(12))
        case let .summary(text):
            Text(text).font(Theme.ui(12)).foregroundStyle(entry.lowered ? Theme.fg3 : Theme.fg2)
        case let .nothingNew(since):
            Text("nothing new since you looked, \(Ages.long(since))").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        case nil:
            EmptyView()
        }
    }

    /// The reasons besides the one shown with the weight.
    private var otherReasons: [AttentionReason] {
        entry.item.orderedReasons.filter { entry.weight <= 0 || $0.text != leadReason }
    }

    private func shownReasons(limit: Int?) -> [AttentionReason] {
        let room = limit.map { max(0, $0 - (entry.weight > 0 ? 1 : 0) - (entry.pinned ? 1 : 0)) }
        return room.map { Array(otherReasons.prefix($0)) } ?? otherReasons
    }

    private func hiddenReasons(limit: Int) -> Int { otherReasons.count - shownReasons(limit: limit).count }

    /// The reason a boost is about, shown with its weight.
    private var leadReason: String { entry.item.orderedReasons.first { !$0.passive }?.text ?? "boosted" }
}

/// An issue or PR in the reader: where it is, its title, chips for why it is here and its state, what you can do
/// with it (each with its key), the catch-up summary in its state, then the conversation as GitHub renders it, the
/// comments
/// you read folded and "new · N" where the new ones start.
private struct AttentionReader: View {
    @Environment(AppModel.self) private var model
    let entry: AttentionEntry

    var body: some View {
        let item = entry.item
        let repo = item.repo!
        let number = item.number!
        let conversation = model.conversation(repo, number)
        let key = ThreadConversation.key(repo: repo, number: number)
        ReaderScroll {
            VStack(alignment: .leading, spacing: 18) {
                ThreadHeader(
                    repo: repo, kind: item.kind == .pr ? .pr : .issue, number: number,
                    title: conversation?.title ?? item.title,
                    author: conversation?.author?.login ?? item.author, openedAt: conversation?.createdAt,
                    chips: chips(conversation), actions: actions
                )
                if let step = model.proposedStep(for: item), model.visibleHelper == nil {
                    NextStepProposal(item: item, step: step)
                }
                why
                SummaryCard(item: item)
                if let draft = model.attention.draft, draft.id == item.id {
                    card("Draft reply") {
                        Text(draft.text ?? "drafting…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let conversation {
                    ThreadConversationView(conversation: conversation, seenAt: model.seenAt(repo, number))
                } else {
                    if let digest = model.detail(of: item)?.digest, !digest.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(digest.enumerated()), id: \.offset) { _, line in
                                Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(2)
                            }
                        }
                    }
                    if let error = model.conversationErrors[key] {
                        Text("Could not load the thread: \(error)").font(Theme.ui(12)).foregroundStyle(Theme.block)
                    } else if model.conversationsLoading.contains(key) {
                        Text("Loading the thread…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    /// Why it is here, in one quiet line: the rule that matched, or the model's suggestion.
    @ViewBuilder private var why: some View {
        if let rule = entry.outcome.rule {
            HStack(spacing: 6) {
                Text("Rule \(rule.line) · \(rule.match) →").foregroundStyle(Theme.fg3)
                Text(rule.action.text).foregroundStyle(rule.action.ignore ? Theme.err : Theme.block)
            }
            .font(Theme.mono(11.5))
        } else if let level = model.attention.suggestions[entry.id]?.level {
            HStack(spacing: 6) {
                Text("No rule matched. The model suggests").foregroundStyle(Theme.fg3)
                Text(level).foregroundStyle(Theme.ask)
                Text("· a rule decides").foregroundStyle(Theme.fg3)
            }
            .font(Theme.mono(11.5))
        }
    }

    private func chips(_ conversation: ThreadConversation?) -> [ThreadHeader.Chip] {
        let item = entry.item
        var chips = item.orderedReasons.map { reason in
            ThreadHeader.Chip(
                text: reason == .reviewRequested ? "review requested from you" : reason.text,
                tint: reason.waits ? Theme.block : Theme.fg2
            )
        }
        chips += item.teams.sorted().map { ThreadHeader.Chip(text: "@\($0)", tint: Theme.ask) }
        if let state = conversation?.stateText, state != "open" {
            chips.append(ThreadHeader.Chip(text: state, tint: state == "merged" ? Theme.ask : Theme.fg2))
        } else if item.isDraft == true {
            chips.append(ThreadHeader.Chip(text: "draft"))
        }
        if let size = item.size { chips.append(ThreadHeader.Chip(text: "\(size) lines changed")) }
        if entry.muted { chips.append(ThreadHeader.Chip(text: "muted", tint: Theme.fg3)) }
        return chips
    }

    private var actions: [ThreadHeader.Action] {
        let item = entry.item
        var actions = [
            ThreadHeader.Action(
                command: "open.reader",
                label: item.kind == .pr ? "Review" : "Read",
                scope: "attention"
            ),
            ThreadHeader.Action(command: "attention.reply", label: "Reply", scope: "attention"),
        ]
        actions.append(item.session != nil
            ? ThreadHeader.Action(command: "attention.session", label: "Session", scope: "attention")
            : ThreadHeader.Action(command: "items.start", label: "Start session", scope: "attention"))
        actions += [
            ThreadHeader.Action(command: "attention.done", label: "Done", scope: "attention"),
            ThreadHeader.Action(command: "attention.snooze", label: "Snooze", scope: "attention"),
        ]
        if item.notificationID != nil {
            actions.append(ThreadHeader.Action(command: "attention.mute", label: "Mute", scope: "attention"))
        }
        if item.url != nil { actions.append(ThreadHeader.Action(command: "open.browser", label: "GitHub")) }
        return actions
    }

    private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, tint: Theme.busy)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.busy.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.busy.opacity(0.3)))
    }
}

/// The reader's scroll: `⌃e` and `⌃y` move it by half its height while the cursor stays in the list. Shots draw it
/// unscrolled, as `ListScroll` does.
private struct ReaderScroll<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content
    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = Metrics()

    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var viewport: CGFloat = 0
        var content: CGFloat = 0
    }

    var body: some View {
        if ShotMode.active {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Metrics.self) { geometry in
                    Metrics(
                        offset: geometry.contentOffset.y, viewport: geometry.containerSize.height,
                        content: geometry.contentSize.height
                    )
                } action: { _, new in metrics = new }
                .onChange(of: model.attention.readerScroll.count) {
                    let step = CGFloat(model.attention.readerScroll.direction) * metrics.viewport / 2
                    let end = max(0, metrics.content - metrics.viewport)
                    let target = min(max(0, metrics.offset + step), end)
                    withAnimation(.easeOut(duration: 0.12)) { position.scrollTo(y: target) }
                }
        }
    }
}

/// The item under the cursor: summary, the thread in three lines, why it is here, and what to do.
private struct AttentionDetail: View {
    @Environment(AppModel.self) private var model
    let entry: AttentionEntry

    var body: some View {
        let item = entry.item
        let detail = model.detail(of: item)
        let conversation = item.repo.flatMap { repo in item.number.flatMap { model.conversation(repo, $0) } }
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text([item.place, item.kind.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    Spacer()
                    Text(Ages.short(item.updatedAt)).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                Text(item.title).font(Theme.ui(15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let author = item.author {
                    Text("opened by \(author)\(item.authorIsBot ? " (bot)" : "")")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                if let key = GoalAttachAsks.key(of: item.id),
                   let ask = model.goals.attach.asks.first(where: { $0.subject.key == key })
                {
                    AskCard(decision: ask, isCursor: true, scope: "attention").shotRegion(.goalAsk)
                }
                if let (board, question) = model.swarmQuestion(for: item) {
                    SwarmAskCard(board: board, question: question, item: item.id).shotRegion(.swarmAsk)
                }
                // Agents, goals, CI runs and releases have no catch-up summary: what heed knows says it.
                section("Summary") {
                    Text(item.placeholderSummary).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                // The three-line digest until the thread itself has loaded (it goes last: it can be long).
                if conversation == nil, let digest = detail?.digest, !digest.isEmpty {
                    section("Thread in \(digest.count) line\(digest.count == 1 ? "" : "s")") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(digest.enumerated()), id: \.offset) { _, line in
                                Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(2)
                            }
                        }
                    }
                }
                section("Why you see this") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.orderedReasons.map(\.text).joined(separator: " · ")
                            +
                            (item.teams.isEmpty ? "" : " · " + item.teams.sorted().map { "@\($0)" }
                                .joined(separator: ", ")))
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        if let rule = entry.outcome.rule {
                            HStack(spacing: 6) {
                                Text("Rule \(rule.line) · \(rule.match) →").foregroundStyle(Theme.fg2)
                                Text(rule.action.text).foregroundStyle(rule.action.ignore ? Theme.err : Theme.block)
                            }
                            .font(Theme.mono(11.5))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
                        } else {
                            Text("No rule matched: recency order.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                            if let level = model.attention.suggestions[item.id]?.level {
                                HStack(spacing: 6) {
                                    Text("The model suggests").foregroundStyle(Theme.fg3)
                                    Text(level).foregroundStyle(Theme.ask)
                                    Text("· a rule decides").foregroundStyle(Theme.fg3)
                                }
                                .font(Theme.mono(11.5))
                            }
                        }
                    }
                }
                if let draft = model.attention.draft, draft.id == item.id {
                    section("Draft reply") {
                        Text(draft.text ?? "drafting…").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("Do something") {
                    VStack(alignment: .leading, spacing: 7) {
                        if GoalAttention.isRetarget(item) {
                            HStack(spacing: 14) {
                                action("goal.ask.yes", "try again", item: item.id)
                                action("goal.ask.no", "leave it", item: item.id)
                                action("open.reader", "its plan", item: item.id)
                            }
                        } else if GoalAttention.question(of: item) != nil {
                            action("open.reader", "its plan", item: item.id)
                        } else if item.reasons.contains(.swarmAsk) {
                            HStack(spacing: 14) {
                                action("goal.ask.yes", "raise the limit, go on", item: item.id)
                                action("goal.ask.no", "keep it paused", item: item.id)
                                action("open.reader", "its plan", item: item.id)
                            }
                        }
                        if item.reasons.contains(.readyToMerge) {
                            HStack(spacing: 14) {
                                action("pilot.merge.now", "merge now", item: item.id)
                                Text("set up merging").font(Theme.ui(12)).foregroundStyle(Theme.fg2).underline()
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.perform(CommandInvocation(name: "pilot.merge.setup")) }
                            }
                        }
                        if item.kind == .pr || item.kind == .issue { action(
                            "attention.reply",
                            "draft a reply",
                            item: item.id
                        ) }
                        if item.session != nil {
                            action(
                                "attention.session",
                                "go to session",
                                item: item.id,
                                detail: sessionTitle(item.session)
                            )
                        }
                        HStack(spacing: 14) {
                            action("attention.done", "done", item: item.id)
                            action("attention.snooze", "snooze", item: item.id)
                            if item.notificationID != nil { action("attention.mute", "mute thread", item: item.id) }
                        }
                        if item.url != nil { action("open.browser", "open on GitHub", item: item.id) }
                    }
                }
                if let conversation {
                    section("Thread") {
                        ThreadConversationView(
                            conversation: conversation, seenAt: model.seenAt(conversation.repo, conversation.number),
                            compact: true
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    private func sessionTitle(_ id: String?) -> String? {
        id.flatMap { id in model.sessions.first { $0.id == id }?.title }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: title)
            content()
        }
    }

    /// What the key does to the item shown, by click as by key: on this item, as a right-click on its row would.
    private func action(_ command: String, _ label: String, item id: String, detail: String? = nil) -> some View {
        KeyHint(command, target: .row(view: "attention", id: id), scope: "attention", spacing: 7) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            if let detail { Text(detail).font(Theme.ui(12, weight: .semibold)).lineLimit(1) }
        }
    }
}

/// A swarm's question in Needs you: who asks and about what, each choice with what it would change, the controller's
/// suggestion; a key for each choice, one to type, one to ask the controller, one to answer similar questions alike.
private struct SwarmAskCard: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let question: SwarmSteering.Question
    let item: String

    var body: some View {
        let armed = model.similarArmed == "\(board.swarm.id)#\(question.id)"
        let suggestion = SwarmSteering.suggestion(question, rows: board.steering)
        let target = CommandTarget.row(view: "attention", id: item)
        VStack(alignment: .leading, spacing: 12) {
            SwarmQuestionView(board: board, question: question, keyed: true, large: true)
            FlowLayout(spacing: 14, lineSpacing: 6) {
                if !question.row.options.isEmpty {
                    KeyHint(
                        "swarm.answer.option", ["1"], target: target,
                        key: question.row.options.count == 1 ? "1" : "1…\(min(question.row.options.count, 9))",
                        scope: "swarmask", label: "pick", color: Theme.fg
                    )
                }
                if suggestion != nil {
                    KeyHint("goal.ask.yes", target: target, scope: "swarmask", label: "take the suggestion")
                }
                KeyHint("swarm.answer", target: target, scope: "swarmask", label: "type an answer")
                if suggestion == nil {
                    KeyHint("swarm.controller", target: target, scope: "swarmask", label: "ask the controller")
                }
                KeyHint(
                    "swarm.similar", target: target, scope: "swarmask",
                    label: armed ? "same for similar: on" : "same for similar",
                    color: armed ? Theme.block : Theme.fg3
                )
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.ask.opacity(0.5)))
    }
}
