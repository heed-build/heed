import HeedCore
import SwiftUI

/// Insights' dashboard (`history.dashboard`, where `gh` opens): a sentence about the range, four numbers set against
/// the range before with their days as a line, what shipped (j k through it, ↩ reads the PR), your bests, twelve weeks
/// of agent time, the agents' record and where the time went, and the goals that moved. Nothing is shown that heed did
/// not record; what no agent reported (cost) is left out rather than guessed.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.dashboard
        let board = browser.board
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1150
            ListScroll {
                VStack(alignment: .leading, spacing: 18) {
                    headline(board, range: browser.range).shotRegion(.dashboardHeadline)
                    if board.isEmpty, board.shipped.isEmpty {
                        Text(empty(browser))
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.fg3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        Tiles(board: board).shotRegion(.dashboardTiles)
                        if wide {
                            HStack(alignment: .top, spacing: 18) {
                                ShippedPanel(board: board, cursor: browser.cursor).shotRegion(.dashboardShipped)
                                BestsPanel(board: board).frame(width: (geometry.size.width - 76) / 3)
                                    .shotRegion(.dashboardBests)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: 18) {
                                CalendarPanel(board: board).shotRegion(.dashboardCalendar)
                                AgentsPanel(board: board).shotRegion(.dashboardAgents)
                                GoalsPanel(moved: browser.moved, next: browser.next, days: board.days)
                                    .shotRegion(.dashboardGoals)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ShippedPanel(board: board, cursor: browser.cursor).shotRegion(.dashboardShipped)
                            BestsPanel(board: board).shotRegion(.dashboardBests)
                            CalendarPanel(board: board).shotRegion(.dashboardCalendar)
                            AgentsPanel(board: board).shotRegion(.dashboardAgents)
                            GoalsPanel(moved: browser.moved, next: browser.next, days: board.days)
                                .shotRegion(.dashboardGoals)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func empty(_ browser: DashboardBrowser) -> String {
        if browser.unavailable { return "The event log could not be opened; the dashboard has nothing to sum." }
        return "Nothing recorded in the last \(DashboardText.range(browser.range)) yet. Sessions, agent time and "
            + "PRs show here as they happen."
    }

    /// The sentence, the line under it, and the range switch (`r`).
    private func headline(_ board: Dashboard, range: Int) -> some View {
        let headline = board.headline
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                (Text(headline.lead).foregroundColor(Theme.fg) + Text(headline.figure).foregroundColor(Theme.done)
                    + Text(headline.tail).foregroundColor(Theme.fg))
                    .font(Theme.ui(28, weight: .semibold))
                    .lineLimit(2)
                if !headline.detail.isEmpty {
                    Text(headline.detail).font(Theme.ui(14)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 2) {
                ForEach(Dashboard.ranges, id: \.self) { days in
                    Text(DashboardText.switchLabel(days))
                        .font(Theme.ui(12.5, weight: days == range ? .semibold : .regular))
                        .foregroundStyle(days == range ? Theme.fg : Theme.fg2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(days == range ? Theme.selected : .clear))
                        .clickRuns(CommandInvocation(name: "dashboard.range", arguments: ["\(days)"]))
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            KeyCap(text: model.keyText(for: "dashboard.range", in: "dashboard"))
        }
    }
}

enum DashboardText {
    /// `7 days`, `4 weeks`, `12 weeks`.
    static func range(_ days: Int) -> String {
        days % 7 == 0 && days > 7 ? "\(days / 7) weeks" : "\(days) day\(days == 1 ? "" : "s")"
    }

    /// The range switch: `Week`, `4 weeks`, `12 weeks`.
    static func switchLabel(_ days: Int) -> String { days == 7 ? "Week" : range(days) }

    static func hours(_ seconds: TimeInterval) -> String { DashboardWords.hours(seconds) }
}

/// A panel with a title and what it shows.
struct Panel<Content: View>: View {
    let title: String
    let note: String
    /// What a click on the note runs: the range's note cycles the range, as r does.
    var noteRuns: CommandInvocation?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                Spacer()
                Text(note).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).clickRuns(noteRuns)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }
}

/// A day-by-day line, scaled to its highest day; flat when every day is zero.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let most = max(values.max() ?? 0, 0.0001)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: geometry.size.height - CGFloat(value / most) * (geometry.size.height - 2) - 1
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 96, height: 28)
    }
}

/// The four numbers: merged, agent time, your median answer, and what a merge cost as agents reported it (or, when
/// none reported a cost, the questions you answered).
private struct Tiles: View {
    let board: Dashboard

    var body: some View {
        HStack(spacing: 14) {
            tile(
                "\(board.merged)", delta: DashboardWords.delta(
                    Double(board.merged), Double(board.mergedBefore), percent: false
                ), good: board.merged >= board.mergedBefore, label: "PRs merged",
                spark: board.mergedPerDay.map(Double.init), color: Theme.done
            )
            tile(
                (board.estimated ? "≈ " : "") + DashboardWords.hours(board.agentTime),
                delta: DashboardWords.delta(board.agentTime, board.agentTimeBefore, percent: true),
                good: board.agentTime >= board.agentTimeBefore,
                label: "agent time" + (board.mostAtOnce > 1 ? " · up to \(board.mostAtOnce) at once" : ""),
                spark: board.perDay, color: Theme.busy
            )
            tile(
                board.medianWait.map(DashboardWords.duration) ?? "–",
                delta: board.medianWait.flatMap { now in
                    board.medianWaitBefore.flatMap { before in
                        DashboardWords.delta((now / 60).rounded(), (before / 60).rounded(), percent: false)
                            .map { $0 + " m" }
                    }
                },
                good: (board.medianWait ?? 0) <= (board.medianWaitBefore ?? .infinity),
                label: board.medianWait == nil ? "no question answered" : "your median answer to an agent",
                spark: board.waitPerDay, color: Theme.ask
            )
            if let perMerge = board.costPerMerge, let cost = board.cost {
                tile(
                    String(format: "$%.2f", perMerge),
                    delta: board.costPerMergeBefore.flatMap { before in
                        before > 0 ? DashboardWords.delta(perMerge, before, percent: true) : nil
                    },
                    good: perMerge <= (board.costPerMergeBefore ?? .infinity),
                    label: "reported cost per merged PR · " + String(format: "$%.2f", cost) + " total",
                    spark: board.costPerDay, color: Theme.fg3
                )
            } else {
                tile(
                    "\(board.answered)", delta: nil, good: true, label: "questions you answered",
                    spark: board.waitPerDay.map { $0 > 0 ? 1 : 0 }, color: Theme.fg3
                )
            }
        }
    }

    private func tile(
        _ value: String, delta: String?, good: Bool, label: String, spark: [Double], color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(Theme.ui(30, weight: .semibold)).foregroundStyle(Theme.fg)
                if let delta {
                    Text(delta).font(Theme.mono(11.5, weight: .semibold))
                        .foregroundStyle(delta.hasPrefix("=") ? Theme.fg3 : good ? Theme.done : Theme.err)
                }
                Spacer(minLength: 6)
                Sparkline(values: spark, color: color).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
            Text(label).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }
}

/// What merged in the range, as cards in two columns edged in their repo's colour; j k move through them, ↩ reads
/// the PR.
private struct ShippedPanel: View {
    @Environment(AppModel.self) private var model
    let board: Dashboard
    let cursor: Int
    private let page = 6

    var body: some View {
        let shipped = board.shipped
        let first = cursor / page * page
        let shown = Array(shipped.indices.dropFirst(first).prefix(page))
        Panel(title: "Shipped", note: note) {
            if shipped.isEmpty {
                Text("Nothing merged in this \(DashboardWords.period(board.days)).")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10
                ) {
                    ForEach(shown, id: \.self) { index in
                        card(shipped[index], isCursor: index == cursor)
                            .hint(model.hintLabel(for: .row(.dashboard, index)))
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickRow(.dashboard, index) }
                            // A double-click reads the PR, as ↩ does here.
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.clickRow(.dashboard, index, open: true)
                            })
                            .rightClickMenu { model.rightClickRow(.dashboard, index) } _: {
                                model.rowMenu(.dashboard, index)
                            }
                    }
                }
                HStack(spacing: 6) {
                    if shipped.count > page {
                        Text("\(shipped.count - shown.count) more ·").foregroundStyle(Theme.fg2)
                    }
                    KeyCap(text: model.keyText(for: "row.next", in: "dashboard"))
                    KeyCap(text: model.keyText(for: "row.prev", in: "dashboard"))
                    Text("through them,").foregroundStyle(Theme.fg2)
                    KeyCap(text: model.keyText(for: "open.reader", in: "dashboard"))
                    Text("reads the PR").foregroundStyle(Theme.fg2)
                }
                .font(Theme.ui(12.5))
            }
        }
    }

    private var note: String {
        var parts = ["\(board.merged) merged"]
        if let fastest = board.fastest { parts.append("fastest \(DashboardWords.duration(fastest))") }
        if let median = board.medianToMerge {
            parts.append("median \(DashboardWords.duration(median)) from start to merge")
        }
        return parts.joined(separator: " · ")
    }

    private func card(_ item: Dashboard.Shipped, isCursor: Bool) -> some View {
        let repo = item.pull?.repo
        let edge = repo.map { $0.color.swatch } ?? Theme.fg3
        let details = [
            repo?.name, item.agent, item.took.map(DashboardWords.duration),
            DashboardWords.day(item.mergedAt, now: Clock.now),
            item.took != nil && item.took == board.fastest ? "fastest" : nil,
        ].compactMap(\.self).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(item.title).font(Theme.ui(13.5)).foregroundStyle(Theme.fg).lineLimit(1)
                if let number = item.number {
                    Text(verbatim: "#\(number)").font(Theme.ui(13.5)).foregroundStyle(Theme.fg3).fixedSize()
                }
            }
            Text(details).font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(isCursor ? Theme.selected : Theme.bg3))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(edge).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isCursor ? Theme.fg3 : .clear))
    }
}

/// Personal bests since the log began, and how long you kept the agents waiting in the range.
private struct BestsPanel: View {
    let board: Dashboard

    var body: some View {
        Panel(title: "Your best", note: board.since.map { "since " + $0.formatted(.dateTime.day().month()) } ?? "") {
            VStack(alignment: .leading, spacing: 14) {
                if board.bests.isEmpty, board.longestWait == nil {
                    Text("Bests show once something merged.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                ForEach(board.bests, id: \.kind.rawValue) { best in
                    row(icon(best.kind), title(best), best.detail + (best.current ? " · this one" : ""))
                }
                if let longest = board.longestWait {
                    row(
                        ("questionmark", Theme.ask),
                        longest <= 15 * 60 ? "No one waited long" :
                            "The longest wait: \(DashboardWords.duration(longest))",
                        longest <= 15 * 60
                            ? "every question answered within \(DashboardWords.duration(max(longest, 60))) this "
                            + DashboardWords.period(board.days)
                            : "your median answer was \(board.medianWait.map(DashboardWords.duration) ?? "–")"
                    )
                }
            }
        }
    }

    private func title(_ best: Dashboard.Best) -> String {
        switch best.kind {
        case .fastestMerge: "Fastest merge: \(best.value)"
        case .mostAtOnce: "Most at once: \(best.value)"
        case .longestStreak: "Longest streak: \(best.value)"
        case .mostInADay: "Busiest day: \(best.value)"
        }
    }

    private func icon(_ kind: Dashboard.Best.Kind) -> (String, Color) {
        switch kind {
        case .fastestMerge: ("bolt.fill", Theme.done)
        case .mostAtOnce: ("square.stack.3d.up.fill", Theme.busy)
        case .longestStreak: ("flame.fill", Theme.block)
        case .mostInADay: ("checkmark.seal.fill", Theme.done)
        }
    }

    private func row(_ icon: (String, Color), _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(icon.1)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg3))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(2)
            }
        }
    }
}

/// Twelve weeks of agent time per day: a column per week, Monday at the top. One hue, stronger is more; each cell
/// says its day and time on hover.
private struct CalendarPanel: View {
    let board: Dashboard
    private let gap: CGFloat = 5
    private let cell: CGFloat = 18

    var body: some View {
        let calendar = Calendar.current
        // Weeks start on Monday; the first column starts at the Monday on or before the calendar's first day.
        let lead = (calendar.component(.weekday, from: board.calendarStart) + 5) % 7
        let weeks = (lead + board.calendar.count + 6) / 7
        Panel(title: "\(weeks) weeks", note: "agent time per day") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0 ..< 7, id: \.self) { row in
                        Text(["Mon", "", "Wed", "", "Fri", "", "Sun"][row])
                            .font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                            .frame(height: cell)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0 ..< weeks, id: \.self) { week in
                        VStack(spacing: gap) {
                            ForEach(0 ..< 7, id: \.self) { row in
                                let index = week * 7 + row - lead
                                if board.calendar.indices.contains(index) {
                                    let seconds = board.calendar[index]
                                    let day = calendar.date(byAdding: .day, value: index, to: board.calendarStart)
                                        ?? board.calendarStart
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Self.shade(board.level(seconds, in: board.calendar)))
                                        .frame(width: cell, height: cell)
                                        .help(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                            + " · " + (seconds > 0 ? DashboardWords.hours(seconds) : "no agent time"))
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Text("less").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                ForEach(0 ..< 5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3).fill(Self.shade(level)).frame(width: 11, height: 11)
                }
                Text("more").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
    }

    /// One hue, faint to full: level 0 is a day with none.
    static func shade(_ level: Int) -> Color {
        switch level {
        case 0: Theme.bg3
        case 1: Theme.block.opacity(0.22)
        case 2: Theme.block.opacity(0.45)
        case 3: Theme.block.opacity(0.7)
        default: Theme.block
        }
    }
}

/// The agents' record (what their sessions that ended came to, and their time), and where the time went by repo.
private struct AgentsPanel: View {
    @Environment(AppModel.self) private var model
    let board: Dashboard

    var body: some View {
        Panel(title: "Your agents", note: "merged / ended · time") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(board.agents.prefix(5), id: \.agent) { score in
                    HStack(spacing: 12) {
                        Text(score.agent).font(Theme.mono(13)).foregroundStyle(Theme.fg).lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                        record(score).frame(height: 7)
                        Text("\(score.merged) / \(score.ended)").font(Theme.mono(12.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 52, alignment: .trailing)
                        Text((score.estimated ? "≈ " : "") + short(score.seconds))
                            .font(Theme.mono(12.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Where the time went").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                Spacer()
                Text("by repo").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            .padding(.top, 6)
            let most = board.byRepo.map(\.seconds).max() ?? 1
            VStack(alignment: .leading, spacing: 10) {
                ForEach(board.byRepo.prefix(5), id: \.name) { share in
                    HStack(spacing: 12) {
                        Text(share.name).font(Theme.mono(13)).foregroundStyle(Theme.fg).lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Theme.bg3)
                                RoundedRectangle(cornerRadius: 3).fill(color(of: share.name))
                                    .frame(width: max(4, bar.size.width * share.seconds / most))
                            }
                        }
                        .frame(height: 7)
                        Text((share.estimated ? "≈ " : "") + short(share.seconds))
                            .font(Theme.mono(12.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Merged in green and abandoned in red, out of the sessions that ended.
    private func record(_ score: Dashboard.AgentScore) -> some View {
        GeometryReader { bar in
            let ended = CGFloat(max(score.ended, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.bg3)
                HStack(spacing: 0) {
                    Theme.done.frame(width: bar.size.width * CGFloat(score.merged) / ended)
                    Theme.err.frame(width: bar.size.width * CGFloat(score.abandoned) / ended)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .help("\(score.merged) merged, \(score.abandoned) abandoned, of \(score.ended) that ended")
    }

    private func short(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? "\(Int((seconds / 3600).rounded())) h" : "\(Int(seconds / 60)) m"
    }

    private func color(of name: String) -> Color {
        model.repos.first { $0.repo.name == name }?.repo.color.swatch ?? Theme.fg2
    }
}

/// Goals that moved in the range (what came in for them), and what the goal closest to done still needs.
private struct GoalsPanel: View {
    @Environment(AppModel.self) private var model
    let moved: [DashboardGoals.Moved]
    let next: DashboardGoals.Next?
    let days: Int

    var body: some View {
        Panel(title: "Goals that moved", note: "this \(DashboardWords.period(days))") {
            VStack(alignment: .leading, spacing: 12) {
                if moved.isEmpty {
                    Text("No goal moved in this \(DashboardWords.period(days)).")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                ForEach(moved.prefix(4)) { goal in
                    HStack(spacing: 12) {
                        ScoreRing(score: goal.score, size: 32)
                        (Text(goal.title).foregroundColor(Theme.fg)
                            + Text(goal.done ? "  done" : "").foregroundColor(Theme.fg3))
                            .font(Theme.ui(13.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(steps(goal)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                    }
                }
            }
            if let next {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next up").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                    Spacer()
                    Text("from your goals").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(.top, 6)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(next.title) still needs \(next.missing.prefix(2).joined(separator: " and ")).")
                        .font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                KeyHint("view.goals") {
                    Text("goes there").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
            }
        }
    }

    private func steps(_ goal: DashboardGoals.Moved) -> String {
        var parts: [String] = []
        if goal.merged > 0 { parts.append("\(goal.merged) merged") }
        let rest = goal.steps - goal.merged
        if rest > 0 { parts.append("\(rest) step\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
