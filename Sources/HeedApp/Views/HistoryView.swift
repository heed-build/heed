import HeedCore
import SwiftUI

/// Closed sessions, grouped by day (design/screens/History.png).
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                list.shotRegion(.historyList)
                if geometry.size.width >= 880, let entry = model.selectedHistory {
                    HistoryDetail(entry: entry).shotRegion(.historyDetail)
                }
            }
        }
    }

    private var list: some View {
        let rows = model.historyRows
        let cursor = model.historyCursor
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                chip("All", on: model.historyOutcome == nil)
                ForEach(Outcome.allCases, id: \.self) { outcome in
                    chip(
                        outcome.rawValue.prefix(1).uppercased() + outcome.rawValue.dropFirst(),
                        on: model.historyOutcome == outcome
                    )
                }
                Spacer()
                FilterPill(view: .history)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

            GeometryReader { geometry in
                let compact = geometry.size.width < 760
                ScrollViewReader { proxy in
                    ListScroll {
                        ListStack(alignment: .leading, spacing: 0) {
                            ForEach(groups(rows), id: \.title) { group in
                                SectionHeader(title: group.title)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 14)
                                    .padding(.bottom, 6)
                                ForEach(group.indices, id: \.self) { index in
                                    HistoryRow(
                                        entry: rows[index],
                                        number: index == cursor ? index + 1 : abs(index - cursor),
                                        isCursor: index == cursor,
                                        compact: compact
                                    )
                                    .hint(model.hintLabel(for: .row(.history, index)))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.clickRow(.history, index) }
                                    .rightClickMenu { model.rightClickRow(.history, index) } _: {
                                        model.rowMenu(.history, index)
                                    }
                                    .id(rows[index].id)
                                }
                            }
                        }
                    }
                    .onChange(of: model.historyCursor) {
                        if rows.indices.contains(model.historyCursor) { proxy.scrollTo(rows[model.historyCursor].id) }
                    }
                }
            }
            if rows.isEmpty {
                Text(model.history.isEmpty ? "Closed sessions land here (x on a session)." : "Nothing matches.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chip(_ label: String, on: Bool) -> some View {
        Text(label)
            .font(Theme.ui(12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.ink : Theme.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.inverse : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.line))
            .fixedSize()
    }

    private struct Group {
        let title: String
        let indices: [Int]
    }

    private func groups(_ rows: [HistoryEntry]) -> [Group] {
        let calendar = Calendar.current
        let now = Clock.now
        func title(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return "This week" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 14 { return "Last week" }
            return "Older"
        }
        var result: [Group] = []
        for (index, entry) in rows.enumerated() {
            let name = title(entry.closedAt)
            if result.last?.title == name {
                result[result.count - 1] = Group(title: name, indices: result[result.count - 1].indices + [index])
            } else {
                result.append(Group(title: name, indices: [index]))
            }
        }
        return result
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let number: Int
    let isCursor: Bool
    /// Narrow list: only title, repo and outcome.
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 24, alignment: .trailing)
            OutcomeGlyph(outcome: entry.outcome)
            HStack(spacing: 4) {
                Text(entry.session.title).font(Theme.ui(13)).lineLimit(1)
                if let pull = entry.session.trackedPRs.first {
                    Text(verbatim: "#\(pull.number)").font(Theme.ui(13)).foregroundStyle(Theme.fg3).fixedSize()
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if entry.session.isChat {
                ChatKindChip().fixedSize()
            } else if let repo = entry.session.repos.first {
                RepoChip(repo: repo).fixedSize()
            }
            if !compact {
                Text(entry.session.agent).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                    .frame(width: 76, alignment: .leading)
                Text(Durations.short(entry.duration)).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                    .frame(width: 64, alignment: .leading)
            }
            Text(entry.outcome.rawValue).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                .frame(width: 84, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(isCursor ? Theme.bg3 : .clear)
    }
}

/// Outcome glyphs reuse the state shapes: merged is done, closed a hollow square, abandoned a hollow circle, cleaned
/// up a dotted ring.
struct OutcomeGlyph: View {
    let outcome: Outcome

    var body: some View {
        switch outcome {
        case .merged: StateGlyph(state: .done)
        case .closed: StateGlyph(state: .exited)
        case .abandoned: StateGlyph(state: .idle)
        case .promoted:
            Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.done).frame(width: 12, height: 12)
        case .cleanedUp:
            Circle().strokeBorder(Theme.fg3, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(
                width: 12,
                height: 12
            )
        }
    }
}

private struct HistoryDetail: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(
                    title: "\(entry.outcome.rawValue) \(Clock.relative(entry.closedAt, named: true))"
                )
                Spacer()
                if entry.session.isChat {
                    ChatKindChip()
                } else if let repo = entry.session.repos.first {
                    RepoChip(repo: repo)
                }
            }
            Text(entry.session.title).font(Theme.ui(16, weight: .semibold))
            Text(entry.session.prompt.isEmpty ? "(no prompt)" : entry.session.prompt)
                .font(Theme.mono(12))
                .lineLimit(3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.session.timeline.suffix(12).enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .foregroundStyle(Theme.fg3)
                            .frame(width: 92, alignment: .leading)
                        Text(event.text).foregroundStyle(Theme.fg)
                    }
                    .font(Theme.mono(12))
                }
            }
            Text(
                entry.session.chat.map { chat in
                    "A chat in \(chat.kind == .scratch ? "a scratch folder, " : "")\(Paths.tilde(chat.path)). Heed keeps only the prompt, the session id and this timeline; the transcript belongs to the agent."
                } ?? "Branch \(entry.session.branch). Heed keeps only the prompt, the session id and this timeline; the transcript belongs to the agent."
            )
            .font(Theme.ui(12))
            .foregroundStyle(Theme.fg2)
            .fixedSize(horizontal: false, vertical: true)
            if let id = entry.session.agentSessionID,
               let command = model.settings.agent(entry.session.agent)?.resumeCommand(id: id)
            {
                Text(command.posix)
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            }
            Spacer()
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                keyRow(
                    "R",
                    "reopen: resume the agent; recreates the worktree if cleaned up. If the agent has dropped the session, starts fresh with the same prompt"
                )
                keyRow("O", "start a new session from this prompt")
                keyRow("t", "cycle the outcome filter")
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Durations {
    /// `2h 10m`, `41m`.
    static func short(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
}
