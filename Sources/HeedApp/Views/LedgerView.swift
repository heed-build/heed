import HeedCore
import SwiftUI

/// History's ledger (`history.ledger`): every piece of work with the summary heed had written of it, kept after its
/// worktree is gone; the entry under the cursor in full on the right.
struct LedgerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ledger = model.ledger
        let rows = ledger.rows
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header(count: ledger.entries.count)
                    ListBody(
                        count: rows.count, cursor: ledger.cursor, ids: rows.map(\.id), empty: empty,
                        hintView: .ledger
                    ) { index in
                        LedgerRow(
                            entry: rows[index],
                            isCursor: index == ledger.cursor,
                            writing: ledger.writing.contains(rows[index].id)
                        )
                    }
                    .shotRegion(.ledgerList)
                }
                .frame(width: geometry.size.width >= 1000 ? 420 : geometry.size.width)
                .frame(height: geometry.size.height, alignment: .top)
                .clipped()
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                if geometry.size.width >= 1000, let entry = ledger.selected {
                    LedgerDetail(
                        entry: entry, writing: ledger.writing.contains(entry.id),
                        reopenable: model.history.contains { $0.id == entry.id }
                    )
                    .frame(height: geometry.size.height)
                    .shotRegion(.ledgerDetail)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var empty: String {
        if !model.ledger.entries.isEmpty { return "Nothing matches." }
        return "No summaries yet. Heed writes one when a PR opens or merges, before a worktree is removed, or after a "
            + "day idle ([summary] when); S writes one now."
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            SectionHeader(title: "Ledger · \(count) piece\(count == 1 ? "" : "s") of work")
            Spacer(minLength: 8)
            FilterPill(view: .ledger)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct LedgerRow: View {
    let entry: LedgerEntry
    let isCursor: Bool
    let writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.branch.isEmpty ? entry.title : entry.branch)
                    .font(Theme.mono(12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                LedgerWord(text: writing ? "writing…" : entry.outcome)
            }
            Text("\(entry.place) · \(LedgerDates.span(entry))")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.fg3)
            Text(entry.summary ?? "No summary yet.")
                .font(Theme.ui(12))
                .foregroundStyle(entry.summary == nil ? Theme.fg3 : Theme.fg2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The outcome, in words.
private struct LedgerWord: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.fg2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            .fixedSize()
    }
}

enum LedgerDates {
    /// `12–14 Oct`, `14 Oct`, `since 12 Oct`.
    static func span(_ entry: LedgerEntry) -> String {
        let day = Date.FormatStyle().day().month(.abbreviated)
        guard let end = entry.endedAt else { return "since " + entry.startedAt.formatted(day) }
        let calendar = Calendar.current
        if calendar.isDate(entry.startedAt, inSameDayAs: end) { return end.formatted(day) }
        return entry.startedAt.formatted(.dateTime.day()) + "–" + end.formatted(day)
    }
}

private struct LedgerDetail: View {
    @Environment(AppModel.self) private var model
    let entry: LedgerEntry
    let writing: Bool
    let reopenable: Bool

    var body: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 14) {
                Text([entry.place, entry.branch.isEmpty ? nil : entry.branch].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.fg3)
                Text(entry.title).font(Theme.ui(18, weight: .semibold))
                section(sourceLine) {
                    Text(entry.summary ?? (writing ? "Writing…" : "No summary yet."))
                        .font(Theme.ui(13))
                        .foregroundStyle(entry.summary == nil ? Theme.fg3 : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = entry.failure {
                        Text("The last attempt failed: \(failure)")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.block)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !entry.decisions.isEmpty { section("Decisions") { bullets(entry.decisions) } }
                if !entry.followUps.isEmpty { section("Follow-ups") { bullets(entry.followUps) } }
                section("Facts") {
                    VStack(spacing: 7) {
                        fact("Lifetime", lifetime)
                        if let time = entry.agentTime {
                            fact(
                                "Agent time",
                                (entry.agentTimeEstimated ? "≈ " : "") + Durations.short(time)
                                    + " · \(entry.agent)"
                            )
                        }
                        if let diff = entry.diff { fact("Diff", diff.text) }
                        if !entry.pulls.isEmpty {
                            fact("PRs", entry.pulls.map { "#\($0.number)" }.joined(separator: ", "))
                        }
                        if let usage = entry.usage, !usage.tokens.isEmpty {
                            fact(
                                "Used",
                                [
                                    usage.model,
                                    Counts.text(usage.tokens.allInput + usage.tokens.output)
                                        + " tokens",
                                    usage.costUSD.map { String(format: "$%.2f", $0) },
                                ]
                                .compactMap(\.self).joined(separator: " · ")
                            )
                        }
                        fact("Outcome", entry.outcome)
                    }
                }
                if !entry.files.isEmpty {
                    section("Files") {
                        ForEach(entry.files, id: \.self) { file in
                            Text(file).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                Theme.line.frame(height: 1).padding(.top, 6)
                HStack(spacing: 18) {
                    keyHint("ledger.summarize", writing ? "writing…" : "write again")
                    keyHint("ledger.edit", "edit")
                    if reopenable { keyHint("history.reopen", "reopen") }
                    keyHint("history.ledger", "list")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg2)
    }

    /// `Summary · written when the PR was opened, 3 h ago`.
    private var sourceLine: String {
        guard entry.summary != nil else { return "Summary" }
        let when = entry.summarizedAt.map { ", " + Clock.relative($0, named: true) } ?? ""
        switch entry.source {
        case .edited: return "Summary · edited by you" + when
        case .signOff: return "Summary · the agent's own sign-off" + when
        default: return "Summary · written " + (entry.trigger.map { $0 == "on demand" ? "on demand" : "when \($0)" }
                ?? "") + when
        }
    }

    private var lifetime: String {
        let day = Date.FormatStyle().day().month(.abbreviated).hour().minute()
        guard let end = entry.endedAt else { return "since " + entry.startedAt.formatted(day) }
        return Durations.short(end.timeIntervalSince(entry.startedAt)) + " · " + LedgerDates.span(entry)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: title)
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text("· " + item).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.fg3)
            Spacer()
            Text(value).foregroundStyle(Theme.fg).lineLimit(1)
        }
        .font(Theme.ui(12.5))
    }

    private func keyHint(_ command: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(text: model.keyText(for: command, in: "ledger"))
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}
