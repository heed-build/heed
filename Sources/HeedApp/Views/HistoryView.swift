import HeedCore
import SwiftUI

/// Insights › History (`history.list`): one filter column (what to show, outcome, repo, where), the work that ended by
/// day with its story on the line under it and what belongs to no session as quiet lines, and the piece of work under
/// the cursor told in full on the right. `e` unfolds every event as its own line: what the timeline was.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.historyBrowser
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                if geometry.size.width >= 900 {
                    HistoryFilters(browser: browser).frame(height: geometry.size.height)
                        .shotRegion(.historyFilters)
                }
                VStack(spacing: 0) {
                    header(browser, chips: geometry.size.width < 900)
                    HistoryLines(browser: browser).shotRegion(.historyList)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: geometry.size.height, alignment: .top)
                .clipped()
                if geometry.size.width >= 1150, let line = browser.selected {
                    Group {
                        if let entry = browser.selectedEntry {
                            HistoryDetail(entry: entry, story: browser.story(of: entry.id), facts: browser.facts)
                        } else if case let .event(item) = line {
                            EventDetail(item: item, facts: browser.facts)
                        }
                    }
                    .frame(height: geometry.size.height)
                    .shotRegion(.historyDetail)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// What it shows, and in a narrow window (no filter column) what is narrowed, as chips; a click on one takes the
    /// narrowing off.
    private func header(_ browser: HistoryBrowser, chips: Bool) -> some View {
        let filter = browser.filter
        return HStack(spacing: 8) {
            Text(browser.everyEvent ? "every event · last \(HistoryBrowser.days) days" : "the work that ended")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            if chips {
                if let outcome = browser.outcome {
                    FilterChip(label: outcome.rawValue, on: true)
                        .clickRuns(CommandInvocation(name: "history.outcome", arguments: ["all"]))
                }
                if let repo = filter.repo {
                    FilterChip(label: String(repo.split(separator: "/").last ?? ""), on: true)
                        .clickRuns(CommandInvocation(name: "timeline.repo", arguments: ["all"]))
                }
                if let place = filter.place {
                    FilterChip(label: place == "local" ? "this Mac" : "@\(place)", on: true)
                        .clickRuns(CommandInvocation(name: "timeline.where", arguments: ["all"]))
                }
            }
            Spacer(minLength: 8)
            FilterPill(view: .history)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The filter column, as the keys change it: what to show (`e`, kinds `K`, removed worktrees `c`), the outcome (`t`),
/// the repo (`r`), where (`w`). A click does what the key does.
private struct HistoryFilters: View {
    @Environment(AppModel.self) private var model
    let browser: HistoryBrowser

    var body: some View {
        let filter = browser.filter
        let choices = browser.choices
        let counts = browser.outcomeCounts
        let repoCounts = browser.repoCounts
        ListScroll {
            VStack(alignment: .leading, spacing: 6) {
                heading("Show", "history.events")
                choice(
                    "Work",
                    note: "sessions, chats",
                    on: !browser.everyEvent,
                    "history.events",
                    [],
                    enabled:
                    browser.everyEvent
                )
                choice("Every event", on: browser.everyEvent, "history.events", [], enabled: !browser.everyEvent)
                if browser.everyEvent {
                    heading("Kinds", "timeline.kind").padding(.top, 10)
                    ForEach(TimelineItem.Kind.allCases, id: \.self) { kind in
                        toggle(kind.title, on: filter.kinds.contains(kind), "timeline.kind", [kind.rawValue])
                    }
                }
                heading("Outcome", "history.outcome").padding(.top, 14)
                choice(
                    "All", count: counts.values.reduce(0, +), on: browser.outcome == nil, "history.outcome", ["all"]
                )
                ForEach(Outcome.allCases, id: \.self) { outcome in
                    if let count = counts[outcome] {
                        choice(
                            outcome.rawValue.prefix(1).uppercased() + outcome.rawValue.dropFirst(), count: count,
                            on: browser.outcome == outcome, "history.outcome", [outcome.rawValue]
                        )
                    }
                }
                heading("Repo", "timeline.repo").padding(.top, 14)
                choice("all", on: filter.repo == nil, "timeline.repo", ["all"])
                ForEach(choices.repos, id: \.self) { repo in
                    choice(
                        String(repo.split(separator: "/").last ?? ""), count: repoCounts[repo],
                        on: filter.repo == repo, "timeline.repo", [repo]
                    )
                }
                heading("Where", "timeline.where").padding(.top, 14)
                choice("all", on: filter.place == nil, "timeline.where", ["all"])
                ForEach(choices.places, id: \.self) { place in
                    choice(
                        place == "local" ? "this Mac" : "@\(place)", on: filter.place == place, "timeline.where",
                        [place]
                    )
                }
                toggle("Removed worktrees", on: filter.showGone, "timeline.gone", []).padding(.top, 14)
            }
            .padding(18)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func heading(_ title: String, _ command: String) -> some View {
        HStack {
            SectionHeader(title: title)
            Spacer()
            KeyCap(text: model.keyText(for: command, in: "history"))
        }
        .padding(.bottom, 2)
    }

    private func choice(
        _ title: String, note: String? = nil, count: Int? = nil, on: Bool, _ command: String, _ arguments: [String],
        enabled: Bool = true
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.ui(12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.fg : Theme.fg2)
            Spacer(minLength: 4)
            if let note { Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
            if let count { Text("\(count)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard enabled else { return }
            model.perform(CommandInvocation(name: command, arguments: arguments))
        }
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
}

/// The days, and their lines: a piece of work with its story, a quiet line, or (unfolded) one event.
private struct HistoryLines: View {
    @Environment(AppModel.self) private var model
    let browser: HistoryBrowser

    var body: some View {
        let lines = browser.lines
        let cursor = browser.cursor
        if lines.isEmpty {
            empty
        } else {
            GeometryReader { geometry in
                let compact = geometry.size.width < 700
                ScrollViewReader { proxy in
                    ListScroll {
                        ListStack(alignment: .leading, spacing: 0) {
                            ForEach(browser.feed.days, id: \.start) { day in
                                DayHeader(day: day)
                                ForEach(day.indices, id: \.self) { index in
                                    line(lines[index], isCursor: index == cursor, compact: compact)
                                        .hint(model.hintLabel(for: .row(.history, index)))
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.clickRow(.history, index) }
                                        // A double-click reopens, as ↩ does here.
                                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                                            model.clickRow(.history, index, open: true)
                                        })
                                        .rightClickMenu { model.rightClickRow(.history, index) } _: {
                                            model.rowMenu(.history, index)
                                        }
                                        .id(lines[index].id)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: browser.cursor) {
                        if lines.indices.contains(browser.cursor) { proxy.scrollTo(lines[browser.cursor].id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ line: HistoryFeed.Line, isCursor: Bool, compact: Bool) -> some View {
        switch line {
        case let .work(work) where work.quiet: QuietWorkRow(work: work, isCursor: isCursor)
        case let .work(work): WorkRow(work: work, isCursor: isCursor, compact: compact)
        case let .event(item) where browser.everyEvent: EventRow(item: item, isCursor: isCursor)
        case let .event(item): QuietEventRow(item: item, isCursor: isCursor)
        }
    }

    @ViewBuilder
    private var empty: some View {
        if model.history.isEmpty, browser.items.isEmpty {
            EmptyState(
                title: "Nothing ended yet",
                detail: "A session lands here when you close it (\(model.keyText(for: "session.close"))) or its "
                    + "worktree is removed, with its prompt, branch, PRs, what happened to it and how it ended; "
                    + "\(model.keyText(for: "history.reopen", in: "history")) brings one back.",
                actions: [
                    .init("every event: sessions, worktrees and PRs as they happened", "history.events"),
                    .init("the ledger: a summary of each piece of work", "history.ledger"),
                ]
            )
        } else {
            Text(browser.unavailable && browser.everyEvent
                ? "The event log could not be opened; there are no events to show." : "Nothing matches.")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// `TODAY · TUE 13 OCT   3 merged · 1 question answered`.
private struct DayHeader: View {
    let day: HistoryFeed.Day

    var body: some View {
        HStack(spacing: 14) {
            Text(day.title + (day.title == "Today" || day.title == "Yesterday"
                    ? " · " + day.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : ""))
                .font(Theme.ui(11, weight: .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(Theme.fg)
            Text(day.totals.text).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

/// How a piece of work ended, in words, outlined in its colour.
struct OutcomeBadge: View {
    let outcome: Outcome

    var body: some View {
        Text(outcome.rawValue)
            .font(Theme.mono(11))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .frame(minWidth: 84, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.45)))
            .fixedSize()
    }

    private var tint: Color {
        switch outcome {
        case .merged, .promoted: Theme.done
        case .abandoned: Theme.fg2
        case .closed, .cleanedUp: Theme.fg3
        }
    }
}

/// A piece of work: how it ended, its title and PR, repo, agent and how long, and under it its story in one line.
private struct WorkRow: View {
    let work: HistoryFeed.Work
    let isCursor: Bool
    let compact: Bool

    var body: some View {
        let session = work.entry.session
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                OutcomeGlyph(outcome: work.entry.outcome).frame(width: 16)
                HStack(spacing: 5) {
                    Text(session.title).font(Theme.ui(13.5)).foregroundStyle(Theme.fg).lineLimit(1)
                    if let pull = session.trackedPRs.last {
                        Text(verbatim: "#\(pull.number)").font(Theme.ui(13.5)).foregroundStyle(Theme.fg3).fixedSize()
                    }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                if let repo = session.repos.first { RepoChip(repo: repo).fixedSize() }
                if let host = session.host { HostChip(location: .host(host)).fixedSize() }
                if !compact {
                    Text(session.agent).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                        .frame(width: 70, alignment: .leading)
                    Text(Durations.short(work.entry.duration)).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                        .frame(width: 60, alignment: .trailing)
                }
                OutcomeBadge(outcome: work.entry.outcome)
            }
            if !story.isEmpty {
                StoryLine(parts: story).padding(.leading, 26)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(isCursor ? Theme.bg3 : .clear)
    }

    private var story: [(Date, String)] {
        work.story.compactMap { item in
            HistoryFeed.storyWord(item, outcome: work.entry.outcome).map { (item.at, $0) }
        }
    }
}

/// `06:31 started ── 07:36 PR #2810 ── 08:39 merged`: one line, cut at its end when it is long.
private struct StoryLine: View {
    let parts: [(Date, String)]

    var body: some View {
        parts.enumerated().reduce(Text("")) { text, element in
            let (index, part) = element
            let time = Text(part.0, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .foregroundColor(Theme.fg3)
            let word = Text(" " + part.1).foregroundColor(tint(part.1))
            return text + (index > 0 ? Text("  ──  ").foregroundColor(Theme.line) : Text("")) + time + word
        }
        .font(Theme.mono(11.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func tint(_ word: String) -> Color {
        if word == "merged" { return Theme.done }
        if word == "you answered" { return Theme.ask }
        if word == "abandoned" { return Theme.fg2 }
        return Theme.fg2
    }
}

/// A chat that ended: a quiet line in its day, as it has no repo or PR to tell.
private struct QuietWorkRow: View {
    let work: HistoryFeed.Work
    let isCursor: Bool

    var body: some View {
        let session = work.entry.session
        HStack(spacing: 10) {
            ChatGlyph().frame(width: 16)
            Text(work.entry.closedAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            (Text("Chat ").foregroundColor(Theme.fg2) + Text(session.title).foregroundColor(Theme.fg)
                + Text(" · \(session.agent) · \(Durations.short(work.entry.duration))").foregroundColor(Theme.fg3))
                .font(Theme.ui(12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            OutcomeBadge(outcome: work.entry.outcome)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(isCursor ? Theme.bg3 : .clear)
    }
}

/// An event of no session (a worktree made by hand, a PR merged outside a session): a quiet line in its day.
private struct QuietEventRow: View {
    let item: TimelineItem
    let isCursor: Bool

    var body: some View {
        HStack(spacing: 10) {
            TimelineRing(gone: item.gone).frame(width: 16)
            Text(item.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            (Text(item.lead + " ").foregroundColor(Theme.fg2) + Text(item.name).foregroundColor(Theme.fg)
                + Text(item.detail.isEmpty ? "" : " · " + item.detail).foregroundColor(Theme.fg3))
                .font(Theme.ui(12.5))
                .strikethrough(item.gone, color: Theme.fg3)
                .lineLimit(1)
            Spacer(minLength: 8)
            TimelineBadge(text: item.badge)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(isCursor ? Theme.bg3 : .clear)
    }
}

/// Where the rule of the unfolded events runs: the glyph column's center.
private let railX: CGFloat = 86

/// One event as its own line (every event unfolded): its time, a ring on the day's rule, what happened.
private struct EventRow: View {
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
        .background(alignment: .leading) { Theme.line.frame(width: 1).padding(.leading, railX - 0.5) }
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

/// A piece of work in full: its prompt, what happened to it, the ledger's summary, how to resume it, and the keys.
private struct HistoryDetail: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry
    let story: [TimelineItem]
    let facts: TimelineFacts

    var body: some View {
        let session = entry.session
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "\(entry.outcome.rawValue) \(Clock.relative(entry.closedAt, named: true))")
                Spacer()
                if session.isChat {
                    ChatKindChip()
                } else if let repo = session.repos.first {
                    RepoChip(repo: repo)
                }
            }
            Text(session.title).font(Theme.ui(17, weight: .semibold))
            Text(session.prompt.isEmpty ? "(no prompt)" : session.prompt)
                .font(Theme.mono(12))
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            SectionHeader(title: "What happened").padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                if story.isEmpty {
                    // No event log: the session's own lines.
                    ForEach(Array(session.timeline.suffix(8).enumerated()), id: \.offset) { _, event in
                        storyRow(event.at, event.text, Theme.fg3)
                    }
                } else {
                    ForEach(story.suffix(9)) { item in
                        storyRow(item.at, HistoryFeed.storySentence(item, agent: session.agent), dot(item.event))
                    }
                }
                if let time = facts.agentTime, time > 0 {
                    Text("Its agent worked " + (facts.estimated ? "about " : "") + DashboardWords.hours(time) + ".")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2).padding(.top, 2)
                }
            }
            if let summary = model.ledger.entries[entry.id]?.summary, !summary.isEmpty {
                SectionHeader(title: "From the ledger").padding(.top, 4)
                (Text(summary).foregroundColor(Theme.fg2)
                    + Text(" \(model.keyText(for: "history.ledger", in: "history")) opens it")
                    .foregroundColor(Theme.fg3))
                    .font(Theme.ui(12.5))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let id = session.agentSessionID,
               let command = model.settings.agent(session.agent)?.resumeCommand(id: id)
            {
                Text(command.posix)
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack(spacing: 16) {
                hint("history.reopen", "reopen")
                hint("history.again", session.isChat ? "new chat" : "new from prompt")
                if !session.trackedPRs.isEmpty { hint("open.browser", "PR") }
                hint("history.events", "every event")
            }
        }
        .padding(22)
        .frame(width: 400)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func storyRow(_ at: Date, _ text: String, _ dot: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                .frame(width: 42, alignment: .leading)
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineLimit(2)
        }
    }

    private func dot(_ event: EventKind) -> Color {
        switch event {
        case .sessionStarted, .sessionReopened: Theme.busy
        case .questionAnswered: Theme.ask
        case .pullMerged: Theme.done
        case .worktreeRemoved, .worktreeArchived, .sessionClosed: Theme.fg3
        default: Theme.fg2
        }
    }

    private func hint(_ command: String, _ text: String) -> some View {
        KeyHint(command, scope: "history") {
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}

/// An event of no session that ended: what it is, when, and the worktree's life when it is about one.
private struct EventDetail: View {
    let item: TimelineItem
    let facts: TimelineFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: [item.repository?.name, item.place, item.kind.title.lowercased()].compactMap(\.self)
                .joined(separator: " · "))
            Text(item.name)
                .font(Theme.ui(17, weight: .semibold))
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
                Text("This worktree no longer exists.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
            if let lived = facts.lived {
                HStack {
                    Text("Lived").foregroundStyle(Theme.fg3)
                    Spacer()
                    Text(lived.to.map { "\(day(lived.from)) → \(day($0))" } ?? "since \(day(lived.from))")
                        .foregroundStyle(Theme.fg)
                }
                .font(Theme.ui(12.5))
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            KeyHint("history.events", scope: "history") {
                Text("every event, or folded into work").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            }
        }
        .padding(22)
        .frame(width: 400)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

enum Durations {
    /// `2h 10m`, `41m`.
    static func short(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
}
