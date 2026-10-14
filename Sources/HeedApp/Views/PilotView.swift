import HeedCore
import SwiftUI

/// A watched PR's state, small: what the sidebar, the PRs view, Repos and the Pilot view show next to a PR.
struct PilotMark: View {
    let status: PilotStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(glyph)
            if !compact || text.count <= 4 { Text(text) }
        }
        .font(Theme.mono(compact ? 10.5 : 11.5, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }

    private var glyph: String {
        switch status {
        case .stuck: "⚠"
        case .failing: "✕"
        case .changes: "●"
        case .feeding: "⟳"
        case .pending: "◌"
        case .passing: "✓"
        case .paused: "⏸"
        case .unwatched: "○"
        }
    }

    var text: String {
        switch status {
        case .stuck: "stuck"
        case let .failing(count): "\(count) failing"
        case let .changes(count): "\(count) thread\(count == 1 ? "" : "s")"
        case .feeding: "feeding"
        case .pending: "running"
        case .passing: "passing"
        case let .paused(until): until.map { PilotDuration.text($0.timeIntervalSince(Clock.now)) } ?? "paused"
        case .unwatched: "not watched"
        }
    }

    private var color: Color {
        switch status {
        case .stuck: Theme.block
        case .failing: Theme.err
        case .changes: Theme.block
        case .feeding, .pending: Theme.busy
        case .passing: Theme.done
        case .paused, .unwatched: Theme.fg3
        }
    }
}

/// `gw`: the watched PRs by state, the selected PR's items and timeline, and what the pilot has been doing.
struct PilotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.pilotRows
        let cursor = model.cursor(in: .pilot)
        let picked = model.pickedIDs(.pilot)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        SectionHeader(title: "Pilot")
                        Text(summary(rows)).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        Spacer()
                        FilterPill(view: .pilot)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                    ListBody(
                        count: rows.count,
                        cursor: cursor,
                        ids: rows.map(\.id),
                        empty: model.filter(for: .pilot).isEmpty
                            ? "No PRs yet. Sessions pick PRs up by branch; watching is on unless an org or repo says off."
                            : "Nothing matches /\(model.filter(for: .pilot)).",
                        hintView: .pilot
                    ) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || rows[index - 1].status.group != rows[index].status.group {
                                let group = rows[index].status.group
                                SectionHeader(
                                    title: "\(group.rawValue) · \(rows.count { $0.status.group == group })",
                                    tint: group == .needsYou ? Theme.block : Theme.fg3
                                )
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                            }
                            PilotRowView(
                                row: rows[index], index: index, cursor: cursor,
                                isPicked: picked.contains(rows[index].id)
                            )
                        }
                    }
                }
                .frame(width: geometry.size.width >= 1100 ? 440 : geometry.size.width * 0.45)
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                if rows.indices.contains(cursor) {
                    PilotDetail(row: rows[cursor]).shotRegion(.pilotDetail)
                } else {
                    Spacer()
                }
                if model.inspectorVisible, geometry.size.width >= 1240 {
                    PilotActivity().shotRegion(.pilotActivity)
                }
            }
        }
    }

    private func summary(_ rows: [AppModel.PilotRow]) -> String {
        let watched = rows.count { $0.status != .unwatched }
        let stuck = rows.count(where: \.status.needsYou)
        return "\(watched) watched" + (stuck > 0 ? " · \(stuck) need you" : "")
    }
}

private struct PilotRowView: View {
    let row: AppModel.PilotRow
    let index: Int
    let cursor: Int
    let isPicked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RowNumber(index: index, cursor: cursor).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RepoChip(repo: row.ref.repo)
                    Text(verbatim: "#\(row.ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                    Spacer(minLength: 4)
                    PilotMark(status: row.status)
                }
                Text(row.title).font(Theme.ui(13)).lineLimit(1)
                HStack(spacing: 6) {
                    if let session = row.session {
                        StateGlyph(state: session.state.state, size: 10)
                        Text(session.agent).foregroundStyle(Theme.fg3)
                    } else {
                        Text("no session").foregroundStyle(Theme.fg3)
                    }
                    if row.effective.watching {
                        Text("· green \(row.effective.green.configName)").foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.mono(11))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isPicked ? Theme.block.opacity(0.18) : index == cursor ? Theme.bg3 : .clear)
        .opacity(row.status == .unwatched ? 0.6 : 1)
    }
}

/// The selected PR: where it stands, why, its items, and everything the pilot did about it.
private struct PilotDetail: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.PilotRow

    var body: some View {
        let pipeline = model.feedback[row.ref.description]
        let timeline = model.pilotTimeline(row.ref)
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        RepoChip(repo: row.ref.repo)
                        Text(verbatim: "#\(row.ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                        PilotMark(status: row.status)
                    }
                    Text(row.title).font(Theme.ui(16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(model.pilotLine(for: row.ref)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    keyHint("↩", "open")
                    keyHint("w", row.effective.watching ? "stop watching" : "watch")
                    keyHint("m", "green")
                    keyHint("zz", pipeline?.isPaused(Clock.now) == true ? "resume" : "pause")
                }
                if let pipeline, !pipeline.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Items")
                        ForEach(pipeline.items.filter { $0.status != .resolved }) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.status.rawValue).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                                    .frame(width: 70, alignment: .leading)
                                Text(item.promptLine).font(Theme.ui(12.5)).lineLimit(2)
                            }
                        }
                        let resolved = pipeline.count(.resolved)
                        if resolved > 0 {
                            Text("\(resolved) resolved").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Timeline")
                    if timeline.isEmpty {
                        Text("Nothing yet: the pilot logs here what it notices and does for this PR.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(timeline.prefix(40)) { event in
                        PilotEventRow(event: event, showPR: false)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
    }
}

/// Everything the pilot did lately, across PRs.
private struct PilotActivity: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Activity")
                Spacer()
                KeyCap(text: "zi")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ListScroll {
                VStack(alignment: .leading, spacing: 8) {
                    if model.pilotLog.isEmpty {
                        Text("The pilot has not done anything yet.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(model.pilotLog.prefix(80)) { event in
                        PilotEventRow(event: event, showPR: true)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }
}

private struct PilotEventRow: View {
    let event: PilotEvent
    let showPR: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.at, format: .dateTime.hour().minute()).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text).font(Theme.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                if showPR {
                    Text(verbatim: "\(event.ref.repo.name)#\(event.ref.number)").font(Theme.mono(11))
                        .foregroundStyle(Theme.fg3)
                }
            }
        }
    }

    private var color: Color {
        switch event.kind {
        case .items, .waiting: Theme.block
        case .sent, .queued: Theme.busy
        case .addressed, .resolved: Theme.done
        case .stuck: Theme.err
        case .watch, .green, .pause: Theme.fg3
        }
    }
}
