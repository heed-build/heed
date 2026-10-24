import HeedCore
import SwiftUI

/// `gm`: one feed of everything that wants you (GitHub threads and agents), newest first, each with why it is there;
/// the filters on the left, the item under the cursor on the right with its summary, its last comments, the rule that
/// matched and what you can do.
struct AttentionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.attentionRows
        let cursor = model.cursor(in: .attention)
        let picked = model.pickedIDs(.attention)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 900 { AttentionFilters().shotRegion(.attentionFilters) }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        SectionHeader(title: model.attention.filter.title)
                        Text("\(rows.count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                        Spacer()
                        FilterPill(view: .attention)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    if let note = model.github.teams.note { TeamsNote(text: note) }
                    ListBody(
                        count: rows.count, cursor: cursor, ids: rows.map(\.id), empty: emptyText, hintView: .attention
                    ) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            let section = Self.section(rows[index].item.updatedAt)
                            if !rows[index].pinned,
                               index == 0 || rows[index - 1].pinned
                               || Self.section(rows[index - 1].item.updatedAt) != section
                            {
                                header(section)
                            } else if rows[index].pinned, index == 0 {
                                header("Pinned")
                            }
                            AttentionRow(
                                entry: rows[index], index: index, cursor: cursor,
                                summary: model.attention.summary(for: rows[index].item),
                                isPicked: picked.contains(rows[index].id)
                            )
                        }
                    }
                }
                if geometry.size.width >= 1100 {
                    Group {
                        if let entry = rows.indices.contains(cursor) ? rows[cursor] : nil {
                            AttentionDetail(entry: entry)
                        } else {
                            Color.clear.frame(width: 400)
                        }
                    }
                    .frame(width: geometry.size.width >= 1400 ? 440 : 380)
                    .background(Theme.bg2)
                    .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
                    .shotRegion(.attentionDetail)
                }
            }
        }
    }

    private func header(_ title: String) -> some View {
        SectionHeader(title: title).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
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
        case .needsMe: "Nothing wants you."
        case .muted: "Nothing muted. M mutes a thread; an ignore rule mutes what it matches."
        default: "Nothing here."
        }
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

/// The left column: the filters with their counts, the sort, and where summaries come from.
private struct AttentionFilters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.attentionCounts
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AttentionFilter.allCases, id: \.self) { filter in
                    row(filter.title, count: counts[filter] ?? 0, on: model.attention.filter == filter)
                        .contentShape(Rectangle())
                        .onTapGesture { model.perform(CommandInvocation(
                            name: "attention.filter",
                            arguments: [filter.rawValue]
                        )) }
                }
            }
            .padding(.vertical, 10)
            SectionHeader(title: "Sort").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(AttentionSort.allCases, id: \.self) { sort in
                row(sort.title, count: nil, on: model.attention.sort == sort)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.attention.sort != sort { model.perform(CommandInvocation(name: "attention.sort")) }
                    }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                keyRow(model.keyText(for: "attention.filter", in: "attention"), "next filter")
                keyRow(model.keyText(for: "attention.sort", in: "attention"), "sort")
                Text(model.config.llm.enabled ? "Summaries by heed's model calls" : "Summaries are off ([llm])")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
            .padding(16)
        }
        .frame(width: 210)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func row(_ title: String, count: Int?, on: Bool) -> some View {
        HStack {
            Text(title).font(Theme.ui(12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.fg : Theme.fg2)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.bg3 : .clear))
        .padding(.horizontal, 8)
    }

    private func keyRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            KeyCap(text: key).frame(minWidth: 18)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
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
        case .other: "··"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .pr: Theme.busy
        case .issue: Theme.done
        case .ci: Theme.err
        case .agent: Theme.ask
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
    let summary: String?
    let isPicked: Bool

    var body: some View {
        let item = entry.item
        HStack(alignment: .top, spacing: 10) {
            RowNumber(index: index, cursor: cursor).padding(.top, 2)
            KindMark(item: item)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let repo = item.repo { RepoChip(repo: repo).fixedSize() }
                    if let number = item.number {
                        Text(verbatim: "#\(number)").font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize()
                    }
                    if let state = item.agentState { StateGlyph(state: state, size: 10) }
                    Text(item.title).font(Theme.ui(
                        13,
                        weight: item.unread || item.kind == .agent ? .semibold : .regular
                    ))
                    .foregroundStyle(entry.lowered ? Theme.fg3 : Theme.fg)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Ages.short(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).fixedSize()
                }
                if let summary {
                    Text(summary).font(Theme.ui(12)).foregroundStyle(entry.lowered ? Theme.fg3 : Theme.fg2)
                        .lineLimit(2)
                }
                FlowLayout(spacing: 5) {
                    if entry.pinned { ReasonTag(text: "pinned", tint: Theme.block, filled: true) }
                    if entry.weight > 0 {
                        ReasonTag(
                            text: String(repeating: "▲", count: entry.weight) + " " + leadReason,
                            tint: Theme.block, filled: true
                        )
                    }
                    ForEach(otherReasons, id: \.self) { reason in
                        ReasonTag(text: reason.text, tint: reason.passive ? Theme.fg3 : Theme.fg2)
                    }
                    ForEach(item.teams.sorted(), id: \.self) { team in ReasonTag(text: "@\(team)", tint: Theme.ask) }
                    if entry.lowered { ReasonTag(text: "lowered", tint: Theme.fg3) }
                    if entry.muted { ReasonTag(text: "muted", tint: Theme.fg3) }
                    if let until = entry.mark.snoozedUntil, until > Clock.now {
                        ReasonTag(text: "snoozed", tint: Theme.fg3)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .leading) {
            if index == cursor { Theme.block.frame(width: 2) }
        }
        .background(isPicked ? Theme.block.opacity(0.16) : index == cursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }

    /// The reasons besides the one shown with the weight.
    private var otherReasons: [AttentionReason] {
        entry.item.orderedReasons.filter { entry.weight <= 0 || $0.text != leadReason }
    }

    /// The reason a boost is about, shown with its weight.
    private var leadReason: String { entry.item.orderedReasons.first { !$0.passive }?.text ?? "boosted" }
}

/// The item under the cursor: summary, the thread in three lines, why it is here, and what to do.
private struct AttentionDetail: View {
    @Environment(AppModel.self) private var model
    let entry: AttentionEntry

    var body: some View {
        let item = entry.item
        let detail = model.detail(of: item)
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
                section("Summary") {
                    if let summary = model.attention.summary(for: item) {
                        Text(summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.attention.summarizing.contains(item.id) {
                        Text("summarizing…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    } else {
                        Text(item.kind == .agent ? "An agent waiting on you." : "No summary yet.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                }
                if let digest = detail?.digest, !digest.isEmpty {
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
                        if item.reasons.contains(.readyToMerge) {
                            HStack(spacing: 14) {
                                action("pilot.merge.now", "merge now").contentShape(Rectangle())
                                    .onTapGesture { model.perform(CommandInvocation(name: "pilot.merge.now")) }
                                Text("set up merging").font(Theme.ui(12)).foregroundStyle(Theme.fg2).underline()
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.perform(CommandInvocation(name: "pilot.merge.setup")) }
                            }
                        }
                        if item.kind == .pr || item.kind == .issue { action("attention.reply", "draft a reply") }
                        if item.session != nil {
                            action("attention.session", "go to session", detail: sessionTitle(item.session))
                        }
                        HStack(spacing: 14) {
                            action("attention.done", "done")
                            action("attention.snooze", "snooze")
                            if item.notificationID != nil { action("attention.mute", "mute thread") }
                        }
                        if item.url != nil { action("open.browser", "open on GitHub") }
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

    private func action(_ command: String, _ label: String, detail: String? = nil) -> some View {
        HStack(spacing: 7) {
            KeyCap(text: model.keyText(for: command, in: "attention"))
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            if let detail { Text(detail).font(Theme.ui(12, weight: .semibold)).lineLimit(1) }
        }
    }
}
