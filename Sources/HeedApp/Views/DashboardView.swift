import HeedCore
import SwiftUI

/// History's dashboard (`history.dashboard`): the range's headline numbers, agent time per day as a heatmap, where
/// the time went by agent and by repo, and the sessions started in it with how they went, in words. Single hue,
/// labelled; nothing is shown that was not recorded.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.dashboard
        let board = browser.board
        GeometryReader { geometry in
            ListScroll {
                VStack(alignment: .leading, spacing: 16) {
                    tiles(board)
                    if board.isEmpty {
                        Text(empty(browser))
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.fg3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            // Half the width beside the shares, all of it alone.
                            let wide = geometry.size.width >= 1000
                            Heatmap(
                                board: board,
                                width: wide ? (geometry.size.width - 56) / 2 : geometry.size.width - 40
                            )
                            .shotRegion(.dashboardHeatmap)
                            if wide {
                                Shares(board: board).shotRegion(.dashboardShares)
                            }
                        }
                        RecentSessions(board: board, cursor: browser.cursor).shotRegion(.dashboardRecent)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func empty(_ browser: DashboardBrowser) -> String {
        if browser.unavailable { return "The event log could not be opened; the dashboard has nothing to sum." }
        return "Nothing recorded in the last \(DashboardText.range(browser.range)) yet. Sessions, agent time and "
            + "PRs show here as they happen."
    }

    private func tiles(_ board: Dashboard) -> some View {
        HStack(spacing: 12) {
            StatTile(value: "\(board.sessions)", label: "sessions · \(DashboardText.range(board.days))")
            StatTile(
                value: (board.estimated ? "≈ " : "") + DashboardText.hours(board.agentTime),
                label: "agent time" + (board.estimated ? " · some estimated" : "")
            )
            StatTile(value: "\(board.merged)", label: "PRs merged")
            StatTile(value: "\(board.answered)", label: "questions you answered")
            StatTile(
                value: board.tokens == 0 ? "–" : Counts.text(board.tokens),
                label: "tokens" + (board.cost.map { " · " + String(format: "$%.2f", $0) + " reported" } ?? "")
            )
        }
        .shotRegion(.dashboardTiles)
    }
}

enum DashboardText {
    /// `7 days`, `4 weeks`, `12 weeks`.
    static func range(_ days: Int) -> String {
        days % 7 == 0 && days > 7 ? "\(days / 7) weeks" : "\(days) day\(days == 1 ? "" : "s")"
    }

    /// `62 h`, `3 h 12 m`, `41 m`.
    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 600 { return "\(minutes / 60) h" }
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) m" }
        return "\(minutes) m"
    }
}

/// A headline number with what it counts.
private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.ui(24, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(label).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// A panel with a title and what it shows.
private struct Panel<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg)
                Spacer()
                Text(note).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// Agent time per day: a column per week, Monday at the top. One hue, darker is more; each cell says its day and
/// time on hover.
private struct Heatmap: View {
    let board: Dashboard
    /// The panel's width: the cells grow to fill it (a few weeks read as well as many), within bounds.
    let width: CGFloat
    private let gap: CGFloat = 3
    private let swatch: CGFloat = 13

    var body: some View {
        let calendar = Calendar.current
        // Weeks start on Monday; the first column starts at the Monday on or before the range's start.
        let weekday = (calendar.component(.weekday, from: board.start) + 5) % 7
        let lead = weekday
        let total = lead + board.perDay.count
        let weeks = (total + 6) / 7
        // Columns share the panel's width (a few weeks are wide cells, many are narrow); rows stay short.
        let cellWidth = max(13, (width - 32 - 48) / CGFloat(weeks) - gap)
        let cell = min(28, cellWidth)
        Panel(title: "Agent time per day", note: DashboardText.range(board.days)) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0 ..< 7, id: \.self) { row in
                        Text(row % 2 == 0 ? ["Mon", "", "Wed", "", "Fri", "", "Sun"][row] : "")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.fg3)
                            .frame(height: cell)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0 ..< weeks, id: \.self) { week in
                        VStack(spacing: gap) {
                            ForEach(0 ..< 7, id: \.self) { row in
                                let index = week * 7 + row - lead
                                if board.perDay.indices.contains(index) {
                                    let seconds = board.perDay[index]
                                    let day = calendar.date(byAdding: .day, value: index, to: board.start) ?? board
                                        .start
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Self.shade(board.level(seconds)))
                                        .frame(width: cellWidth, height: cell)
                                        .help(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                            + " · " + (seconds > 0 ? DashboardText.hours(seconds) : "no agent time"))
                                } else {
                                    Color.clear.frame(width: cellWidth, height: cell)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("less").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                ForEach(0 ..< 5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3).fill(Self.shade(level)).frame(width: swatch, height: swatch)
                }
                Text("more agent time · rows are Mon to Sun").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
    }

    /// One hue, light to dark: level 0 is a day with none.
    static func shade(_ level: Int) -> Color {
        switch level {
        case 0: Theme.line
        case 1: Theme.block.opacity(0.28)
        case 2: Theme.block.opacity(0.5)
        case 3: Theme.block.opacity(0.75)
        default: Theme.block
        }
    }
}

/// Where the time went: by agent and by repo, as labelled bars against the biggest.
private struct Shares: View {
    let board: Dashboard

    var body: some View {
        Panel(title: "Where the time went", note: board.estimated ? "≈ some read from the screen" : "") {
            group("By agent", Array(board.byAgent.prefix(5)))
            group("By repo", Array(board.byRepo.prefix(5)))
        }
    }

    private func group(_ title: String, _ shares: [Dashboard.Share]) -> some View {
        let most = shares.map(\.seconds).max() ?? 1
        return VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(Theme.ui(10, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
            ForEach(shares, id: \.name) { share in
                HStack(spacing: 10) {
                    Text(share.name).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { bar in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.line)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.fg2)
                                .frame(width: max(4, bar.size.width * share.seconds / most))
                        }
                    }
                    .frame(height: 7)
                    .help("\(share.name) · \(DashboardText.hours(share.seconds))")
                    Text((share.estimated ? "≈ " : "") + DashboardText.hours(share.seconds))
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

/// The sessions started in the range, newest first, with how they went in words.
private struct RecentSessions: View {
    @Environment(AppModel.self) private var model
    let board: Dashboard
    let cursor: Int

    var body: some View {
        Panel(title: "Recent sessions", note: "\(board.recent.count) of \(board.sessions)") {
            VStack(spacing: 0) {
                ForEach(Array(board.recent.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Text(AwaySummary.dayTitle(Calendar.current.startOfDay(for: row.startedAt), now: Clock.now)
                            .lowercased())
                            .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                            .frame(width: 130, alignment: .leading)
                        Text(row.title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.fg).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.place).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                            .frame(width: 160, alignment: .leading)
                        Text(row.agentTime > 0 ? DashboardText.hours(row.agentTime) : "–")
                            .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 70, alignment: .trailing)
                        Text(row.outcome)
                            .font(Theme.mono(11)).foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                            .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(index == cursor ? Theme.bg3 : .clear)
                    .hint(model.hintLabel(for: .row(.dashboard, index)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickRow(.dashboard, index) }
                    .rightClickMenu { model.rightClickRow(.dashboard, index) } _: { model.rowMenu(.dashboard, index) }
                }
            }
        }
    }
}
