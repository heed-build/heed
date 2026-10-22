import HeedCore
import SwiftUI

/// History as a timeline (`history.timeline`): what happened, by day, on one vertical line. Worktrees that no longer
/// exist stay on it, with a dashed ring and their name struck through; the line under the cursor in full on the right.
struct HistoryTimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.timeline
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                if geometry.size.width >= 900 {
                    TimelineFilters(browser: browser).frame(height: geometry.size.height)
                        .shotRegion(.timelineFilters)
                }
                VStack(spacing: 0) {
                    header(browser)
                    TimelineLines(browser: browser).shotRegion(.timelineList)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: geometry.size.height, alignment: .top)
                .clipped()
                if geometry.size.width >= 1150, let item = browser.selected {
                    TimelineDetail(item: item, facts: browser.facts, entry: model.timelineEntry(item))
                        .frame(height: geometry.size.height)
                        .shotRegion(.timelineDetail)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// What is narrowed, as chips: the narrow window's only filter display.
    private func header(_ browser: TimelineBrowser) -> some View {
        let filter = browser.filter
        return HStack(spacing: 8) {
            FilterChip(
                label: filter.kinds.count == TimelineItem.Kind.allCases.count ? "Everything"
                    : filter.kinds.map(\.title).sorted().joined(separator: ", "),
                on: filter.kinds.count != TimelineItem.Kind.allCases.count
            )
            if let repo = filter.repo { FilterChip(label: String(repo.split(separator: "/").last ?? ""), on: true) }
            if let place = filter.place { FilterChip(label: place == "local" ? "this Mac" : "@\(place)", on: true) }
            if !filter.showGone { FilterChip(label: "removed hidden", on: true) }
            Spacer(minLength: 8)
            Text("last \(TimelineBrowser.days) days").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            FilterPill(view: .timeline)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The filters, as the keys change them: kinds (`t`), removed worktrees (`D`), repo (`r`), where (`w`). A click does
/// what the key does.
private struct TimelineFilters: View {
    @Environment(AppModel.self) private var model
    let browser: TimelineBrowser

    var body: some View {
        let filter = browser.filter
        let choices = browser.choices
        ListScroll {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Show").padding(.bottom, 2)
                ForEach(TimelineItem.Kind.allCases, id: \.self) { kind in
                    toggle(kind.title, on: filter.kinds.contains(kind), "timeline.kind", [kind.rawValue])
                }
                toggle("Removed worktrees", on: filter.showGone, "timeline.gone", []).padding(.top, 4)
                SectionHeader(title: "Repo").padding(.top, 14).padding(.bottom, 2)
                choice("all", on: filter.repo == nil, "timeline.repo", ["all"])
                ForEach(choices.repos, id: \.self) { repo in
                    choice(
                        String(repo.split(separator: "/").last ?? ""),
                        on: filter.repo == repo,
                        "timeline.repo",
                        [repo]
                    )
                }
                SectionHeader(title: "Where").padding(.top, 14).padding(.bottom, 2)
                choice("all", on: filter.place == nil, "timeline.where", ["all"])
                ForEach(choices.places, id: \.self) { place in
                    choice(
                        place == "local" ? "this Mac" : "@\(place)",
                        on: filter.place == place,
                        "timeline.where",
                        [place]
                    )
                }
            }
            .padding(18)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func toggle(_ title: String, on: Bool, _ command: String, _ arguments: [String]) -> some View {
        HStack {
            Text(title).font(Theme.ui(12.5)).foregroundStyle(on ? Theme.fg : Theme.fg3)
            Spacer()
            Text(on ? "on" : "off").font(Theme.mono(11)).foregroundStyle(on ? Theme.fg2 : Theme.fg3)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.perform(CommandInvocation(name: command, arguments: arguments)) }
    }

    private func choice(_ title: String, on: Bool, _ command: String, _ arguments: [String]) -> some View {
        Text(title)
            .font(Theme.ui(12.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.fg : Theme.fg2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.perform(CommandInvocation(name: command, arguments: arguments)) }
    }
}

/// The line itself: days, and their items on one vertical rule.
private struct TimelineLines: View {
    @Environment(AppModel.self) private var model
    let browser: TimelineBrowser

    var body: some View {
        let rows = browser.rows
        let cursor = browser.cursor
        if rows.isEmpty {
            Text(empty)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ListScroll {
                    ListStack(alignment: .leading, spacing: 0) {
                        ForEach(browser.dayGroups, id: \.start) { day in
                            TimelineDayHeader(title: day.title, start: day.start)
                            ForEach(day.indices, id: \.self) { index in
                                TimelineRow(item: rows[index], isCursor: index == cursor)
                                    .hint(model.hintLabel(for: .row(.timeline, index)))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.clickRow(.timeline, index) }
                                    .rightClickMenu { model.rightClickRow(.timeline, index) } _: {
                                        model.rowMenu(.timeline, index)
                                    }
                                    .id(rows[index].id)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: browser.cursor) {
                    if rows.indices.contains(browser.cursor) { proxy.scrollTo(rows[browser.cursor].id) }
                }
            }
        }
    }

    private var empty: String {
        if browser.unavailable { return "The event log could not be opened; the timeline has nothing to show." }
        if !browser.items.isEmpty { return "Nothing matches." }
        return "Nothing logged yet.\nSessions, worktrees, PRs and questions land here as they happen."
    }
}

/// Where the rule runs: the glyph column's center.
private let railX: CGFloat = 86

private struct TimelineDayHeader: View {
    let title: String
    let start: Date

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: railX - 25)
            RoundedRectangle(cornerRadius: 2).fill(Theme.fg2).frame(width: 9, height: 9).frame(width: 14)
            Text(
                title + (title == "Today" || title == "Yesterday"
                    ? " · " + start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : "")
            )
            .font(Theme.ui(11, weight: .semibold))
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(Theme.fg2)
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(alignment: .leading) { TimelineRail() }
    }
}

/// The vertical rule behind the glyphs.
private struct TimelineRail: View {
    var body: some View {
        Theme.line.frame(width: 1).padding(.leading, railX - 0.5)
    }
}

private struct TimelineRow: View {
    let item: TimelineItem
    let isCursor: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.fg3)
                .frame(width: railX - 32, alignment: .trailing)
                .padding(.top, 1)
            TimelineRing(gone: item.gone).frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.lead).foregroundStyle(Theme.fg)
                    Text(item.name)
                        .fontWeight(.semibold)
                        .strikethrough(item.gone, color: Theme.fg3)
                        .foregroundStyle(item.gone ? Theme.fg2 : Theme.fg)
                        .lineLimit(1)
                    if let host = item.host { HostChip(location: .host(host)).fixedSize() }
                }
                .font(Theme.ui(13))
                Text(item.saved.map { "\(item.detail) · \($0)" } ?? item.detail)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if item.saved != nil { TimelineBadge(text: "work saved") }
                TimelineBadge(text: item.badge)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.leading, 9)
        .padding(.vertical, 9)
        .background(isCursor ? Theme.bg3 : .clear)
        .background(alignment: .leading) { TimelineRail() }
    }
}

/// A live thing is a solid ring; a worktree that no longer exists, a dashed one.
private struct TimelineRing: View {
    let gone: Bool

    var body: some View {
        Circle()
            .strokeBorder(gone ? Theme.fg3 : Theme.fg, style: StrokeStyle(lineWidth: 1.5, dash: gone ? [2, 2] : []))
            .background(Circle().fill(Theme.bg))
            .frame(width: 11, height: 11)
    }
}

/// What happened, in words: outcome is never colour alone.
private struct TimelineBadge: View {
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

private struct TimelineDetail: View {
    @Environment(AppModel.self) private var model
    let item: TimelineItem
    let facts: TimelineFacts
    let entry: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Selected")
            Text([item.repository?.name, item.place, item.kind.title.lowercased()].compactMap(\.self)
                .joined(separator: " · "))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.fg3)
            Text(item.name)
                .font(Theme.ui(16, weight: .semibold))
                .strikethrough(item.gone, color: Theme.fg3)
            Text("\(item.lead) \(item.at.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg2)
            if let saved = item.saved {
                Text(saved.prefix(1).uppercased() + saved.dropFirst() + " before removing it.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            } else if item.gone {
                Text("This worktree no longer exists.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg2)
            }
            VStack(spacing: 8) {
                if let lived = facts.lived {
                    fact("Lived", lived.to.map { "\(day(lived.from)) → \(day($0))" } ?? "since \(day(lived.from))")
                }
                if item.session != nil {
                    fact(
                        "Agent time",
                        facts.agentTime.map { (facts.estimated ? "≈ " : "") + Durations.short($0) } ?? "not recorded"
                    )
                }
                if let entry { fact("Session", entry.outcome.rawValue) }
            }
            Spacer()
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                if entry != nil {
                    keyRow(
                        model.keyText(for: "history.reopen", in: "timeline"),
                        "reopen the session, recreating its worktree (from what was saved, when its branch is gone)"
                    )
                }
                keyRow(model.keyText(for: "history.timeline", in: "timeline"), "back to History's list")
            }
        }
        .padding(22)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.fg3)
            Spacer()
            Text(value).foregroundStyle(Theme.fg)
        }
        .font(Theme.ui(12.5))
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
