import HeedCore
import SwiftUI

extension Capability {
    /// Its icon, wherever it is named.
    var symbol: String {
        switch self {
        case .green: "checkmark"
        case .merge: "arrow.triangle.merge"
        case .copilot: "circle.circle"
        case .reviewers: "person.2"
        case .cleanup: "delete.backward"
        case .goals: "diamond"
        case .summaries: "text.alignleft"
        case .resume: "arrow.clockwise"
        case .names: "pencil"
        }
    }

    /// Its own tint, from the theme.
    var tint: Color {
        switch self {
        case .green: Theme.busy
        case .merge: Theme.done
        case .copilot: Theme.ask
        case .reviewers: OrgPalette.teal.foreground
        case .cleanup: Theme.block
        case .goals: OrgPalette.lime.foreground
        case .summaries: Theme.fg2
        case .resume: OrgPalette.sky.foreground
        case .names: OrgPalette.pink.foreground
        }
    }
}

/// A capability's icon on a tile of its tint.
struct CapabilityTile: View {
    let capability: Capability
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: capability.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(capability.tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(capability.tint.opacity(0.14)))
    }
}

/// How much of a capability is on, as a bar in its tint (not Attention's CoverageBar).
struct CapabilityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 5)
    }
}

/// A cell's state as a dot: on, asks first, off.
struct CoverageDot: View {
    let state: AutopilotCell.State

    var body: some View {
        Text(state == .on ? "●" : state == .ask ? "◐" : "○")
            .font(.system(size: 9))
            .foregroundStyle(color)
    }

    var color: Color {
        switch state {
        case .on: Theme.done
        case .ask: Theme.block
        case .off: Theme.fg3
        }
    }
}

/// Above every Autopilot view: a tab per view with its key and what is in it, and on the right what heed took off
/// your hands this week.
struct AutopilotPaneBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pane = model.view.rawValue
        let counts = model.autopilotTabCounts
        let strip = AutopilotTabs.strip(done: counts.done)
        PaneBar(
            crumb: [],
            tabs: AutopilotTabs.tabs(counts: counts).map { tab in
                PaneBarTab(id: tab.pane, title: tab.title, command: tab.command, count: tab.count)
            },
            active: pane, scope: pane, tabsRegion: .autopilotBar,
            select: { tab in model.showHistoryPane(tab.id, command: tab.command) },
            trailing: { EmptyView() }
        )
        .overlay(alignment: .trailing) {
            (Text(strip.lead).foregroundColor(Theme.fg3) + Text(strip.figure).foregroundColor(Theme.done).bold()
                + Text(strip.tail).foregroundColor(Theme.fg3))
                .font(Theme.ui(12.5))
                .lineLimit(1)
                .padding(.trailing, 20)
                .padding(.bottom, 1)
        }
    }
}

// MARK: Can do

/// `gw`, `C`: a card per thing heed can do, and the picked one's detail.
struct AutopilotCanDoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let picked = model.autopilotBrowser.capability
        let week = AutopilotDone.counts(model.autopilotWeek)
        let nudges = model.autopilotNudges
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ListScroll {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                            count: AutopilotBrowser.columns
                        ),
                        spacing: 14
                    ) {
                        ForEach(Capability.allCases) { capability in
                            CapabilityCard(
                                capability: capability, picked: capability == picked,
                                summary: model.autopilotSummary(capability), week: week[capability] ?? 0,
                                nudge: AutopilotNudges.best(capability, in: nudges)
                            )
                            .onTapGesture { model.clickAutopilotCard(capability) }
                        }
                    }
                    .padding(20)
                }
                .shotRegion(.autopilotCards)
                CapabilityDetail(capability: picked, nudge: AutopilotNudges.best(picked, in: nudges))
                    .frame(width: geometry.size.width >= 1300 ? 480 : max(360, geometry.size.width * 0.36))
                    .background(Theme.bg2)
                    .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
                    .shotRegion(.autopilotDetail)
            }
        }
    }
}

private struct CapabilityCard: View {
    @Environment(AppModel.self) private var model
    let capability: Capability
    let picked: Bool
    let summary: AutopilotCoverage.Summary
    let week: Int
    let nudge: AutopilotNudge?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                CapabilityTile(capability: capability, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(capability.title).font(Theme.ui(14.5, weight: .semibold)).foregroundStyle(Theme.fg)
                    Text(subtitle).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            Text(capability.sentence).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            CapabilityBar(fraction: summary.fraction, tint: summary.fraction > 0 ? capability.tint : Theme.line)
            HStack {
                Text(summary.text).foregroundStyle(Theme.fg3)
                Spacer(minLength: 6)
                Text(trailing).foregroundStyle(week > 0 ? Theme.fg2 : Theme.fg3)
            }
            .font(Theme.mono(10.5))
            .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(picked ? Theme.bg3 : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
            picked ? Theme.fg2 : Theme.line,
            lineWidth: picked ? 1.5 : 1
        ))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let scope = capability.scope == .perRepo ? "per repo" : "everywhere"
        guard let command = capability.command else { return scope }
        return "\(model.keyText(for: command)) · \(scope)"
    }

    private var trailing: String {
        if week > 0 { return "\(week) this week" }
        if capability == .cleanup, summary.global?.state == .off, let nudge, nudge.repo == nil {
            return "would remove \(nudge.weight)"
        }
        return "none this week"
    }
}

/// The picked capability: without and with it, how it goes, what it never does, where it is on, and the way to turn
/// it on.
private struct CapabilityDetail: View {
    @Environment(AppModel.self) private var model
    let capability: Capability
    let nudge: AutopilotNudge?

    var body: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    CapabilityTile(capability: capability, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(capability.title).font(Theme.ui(22, weight: .semibold))
                        Text(capability.tagline).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    compare("Without", capability.without, tint: Theme.fg3)
                    compare("With", capability.with, tint: capability.tint)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "How it goes")
                    ForEach(Array(capability.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(Theme.mono(10.5, weight: .semibold)).foregroundStyle(Theme.fg2)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Theme.bg3))
                            Text(step).font(Theme.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "It never")
                    ForEach(capability.never, id: \.self) { rail in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("·").foregroundStyle(Theme.fg3)
                            Text(rail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Where it's on")
                    if capability.scope == .perRepo {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(model.autopilotRepos, id: \.slug) { repo in
                                RepoStateChip(repo: repo, cell: model.autopilotCell(capability, repo: repo))
                            }
                        }
                    } else {
                        let cell = AutopilotCoverage.global(capability, config: model.config)
                        HStack(spacing: 6) {
                            CoverageDot(state: cell.state)
                            Text("everywhere: \(cell.value)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                        }
                    }
                }
                if let nudge {
                    Text(nudge.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 10, lineSpacing: 8) {
                    if capability.scope == .perRepo {
                        if let repo = model.autopilotHere(capability) {
                            AutopilotButton(
                                "Turn on for \(repo.name)",
                                "autopilot.on",
                                scope: "autopilot",
                                primary: true
                            )
                        }
                        AutopilotButton("All repos", "autopilot.everywhere", scope: "autopilot")
                    } else if AutopilotCoverage.global(capability, config: model.config).state != .on {
                        AutopilotButton("Turn on", "autopilot.on", scope: "autopilot", primary: true)
                    } else {
                        AutopilotButton("Turn off", "autopilot.off", scope: "autopilot")
                    }
                    AutopilotButton("What it did", "autopilot.open", scope: "autopilot")
                    AutopilotButton("Settings", "autopilot.settings", scope: "autopilot")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compare(_ name: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name.uppercased()).font(Theme.ui(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(tint)
                .frame(width: 64, alignment: .leading)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(name == "With" ? Theme.fg : Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A repo and the capability's state there: `● docs-toolkit`, `◐ markgraph · ask`.
private struct RepoStateChip: View {
    let repo: Repo
    let cell: AutopilotCell

    var body: some View {
        HStack(spacing: 5) {
            CoverageDot(state: cell.state)
            Text(repo.name + (cell.state == .on ? "" : " · \(cell.value)"))
                .font(Theme.mono(11))
                .foregroundStyle(cell.state == .off ? Theme.fg3 : cell.state == .ask ? Theme.block : Theme.done)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg3))
    }
}

/// A button-sized key hint: what it does and its key, which a click runs.
struct AutopilotButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    let command: String
    let arguments: [String]
    let scope: String
    var primary = false

    init(_ label: String, _ command: String, _ arguments: [String] = [], scope: String, primary: Bool = false) {
        self.label = label
        self.command = command
        self.arguments = arguments
        self.scope = scope
        self.primary = primary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(primary ? Theme.ink : Theme.fg)
                .lineLimit(1)
            Text(model.keyText(for: command, in: scope))
                .font(Theme.mono(10.5))
                .foregroundStyle(primary ? Theme.inverse : Theme.fg2)
                .padding(.horizontal, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(primary ? Theme.ink : Theme.keyCap))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Theme.keyCapBorder))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command, arguments: arguments))
    }
}

// MARK: Where

/// `W`: repos by capability, each cell on, asking first or off, and what would help each repo most.
struct AutopilotWhereView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.autopilotRepos
        let browser = model.autopilotBrowser
        let nudges = model.autopilotNudges
        let week = model.autopilotWeek
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Which repos let heed help").font(Theme.ui(20, weight: .semibold))
                    HStack(spacing: 6) {
                        CoverageDot(state: .on)
                        Text("on")
                        CoverageDot(state: .ask)
                        Text("asks you first")
                        CoverageDot(state: .off)
                        Text("off · counts are this week")
                    }
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                if repos.isEmpty {
                    Text("No repos yet: a repo shows here once heed knows it (gr adds one).")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                } else {
                    matrix(repos: repos, browser: browser, nudges: nudges, week: week).shotRegion(.autopilotMatrix)
                    if let repo = model.autopilotWhereRepo {
                        WhereFooter(repo: repo, capability: browser.whereCapability, nudges: nudges)
                            .shotRegion(.autopilotFooter)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func matrix(
        repos: [Repo], browser: AutopilotBrowser, nudges: [AutopilotNudge], week: [AutopilotEntry]
    ) -> some View {
        let columns = AutopilotBrowser.whereColumns
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                SectionHeader(title: "Repo").frame(width: 190, alignment: .leading)
                ForEach(columns) { capability in
                    HStack(spacing: 5) {
                        Image(systemName: capability.symbol).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(capability.tint)
                        SectionHeader(title: capability.title)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SectionHeader(title: "Could help").frame(width: 230, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            ForEach(Array(repos.enumerated()), id: \.element.slug) { row, repo in
                let counts = AutopilotDone.counts(week.filter { $0.repo == repo.slug })
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        RepoChip(repo: repo)
                        Text(model.autopilotRepoLine(repo)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    }
                    .frame(width: 190, alignment: .leading)
                    ForEach(Array(columns.enumerated()), id: \.element) { column, capability in
                        let cell = model.autopilotCell(capability, repo: repo)
                        let picked = row == browser.row && column == browser.column
                        WhereCell(cell: cell, count: counts[capability] ?? 0, global: capability.scope == .everywhere)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(picked ? Theme.fg : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickAutopilotCell(row: row, column: column) }
                    }
                    Text(AutopilotNudges.couldHelp(repo.slug, in: nudges)?.short ?? "")
                        .font(Theme.ui(12)).foregroundStyle(Theme.block)
                        .lineLimit(2)
                        .frame(width: 230, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(row == browser.row ? Theme.bg3 : .clear)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct WhereCell: View {
    let cell: AutopilotCell
    let count: Int
    let global: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                CoverageDot(state: cell.state)
                Text(cell.value).foregroundStyle(color)
            }
            .font(Theme.mono(11.5))
            if let note = cell.note ?? (count > 0 ? "\(count) this week" : nil) {
                Text(note).font(Theme.mono(10.5)).foregroundStyle(cell.warning ? Theme.err : Theme.fg3)
                    .lineLimit(1)
            }
        }
        .opacity(global && cell.state != .off ? 0.85 : 1)
    }

    private var color: Color {
        switch cell.state {
        case .on: Theme.done
        case .ask: Theme.block
        case .off: Theme.fg3
        }
    }
}

/// What the cell under the cursor means, and the keys that change it.
private struct WhereFooter: View {
    @Environment(AppModel.self) private var model
    let repo: Repo
    let capability: Capability
    let nudges: [AutopilotNudge]

    var body: some View {
        let cell = model.autopilotCell(capability, repo: repo)
        let place = capability.scope == .perRepo ? " in \(repo.name)" : ""
        let word = cell.state == .on ? "is on (\(cell.value))" : cell.state == .ask ? "asks first" : "is off"
        let nudge = nudges.first { $0.capability == capability && ($0.repo == repo.slug || $0.repo == nil) }
        HStack(alignment: .center, spacing: 16) {
            CapabilityTile(capability: capability, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                (Text("\(capability.title)\(place)").bold() + Text(" \(word)."))
                    .font(Theme.ui(14))
                Text(nudge?.text ?? capability.sentence).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if cell.state != .on { AutopilotButton("Turn on", "autopilot.on", scope: "where", primary: true) }
            if cell.state != .ask { AutopilotButton("Ask me first", "autopilot.ask", scope: "where") }
            if cell.state != .off { AutopilotButton("Turn off", "autopilot.off", scope: "where") }
            AutopilotButton("What it does", "autopilot.cando", [capability.rawValue], scope: "where")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }
}

// MARK: Done

/// `D`: what heed did on its own this week, by day, narrowed by capability and repo.
struct AutopilotDoneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let week = model.autopilotWeek
        let days = model.autopilotDays
        let cursor = model.autopilotBrowser.doneCursor
        // Sized to what it is given: a day list taller than the window must not grow the row (shots draw it
        // unscrolled).
        GeometryReader { geometry in
            HStack(spacing: 0) {
                DoneRail(week: week).frame(width: 230).frame(height: geometry.size.height, alignment: .top).clipped()
                    .shotRegion(.autopilotRail)
                Theme.line.frame(width: 1)
                if days.isEmpty {
                    EmptyState(
                        title: "Nothing done on its own yet",
                        detail: "What heed sends, fixes, merges, asks and names on your behalf shows here by day. "
                            + "Can do turns a capability on.",
                        actions: [.init("Can do", "autopilot.cando")]
                    )
                } else {
                    ScrollViewReader { _ in
                        ListScroll {
                            VStack(alignment: .leading, spacing: 4) {
                                let starts = dayStarts(days)
                                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                                    HStack(spacing: 12) {
                                        Text(day.title.uppercased()).font(Theme.ui(11.5, weight: .bold)).tracking(0.6)
                                        Text(day.totals).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                                    }
                                    .padding(.top, index == 0 ? 0 : 14)
                                    .padding(.bottom, 4)
                                    ForEach(Array(day.entries.enumerated()), id: \.element.id) { offset, entry in
                                        let line = starts[index] + offset
                                        DoneRow(entry: entry, selected: line == cursor)
                                            .id(entry.id)
                                            .onTapGesture { model.clickRow(.autopilotDone, line) }
                                    }
                                }
                            }
                            .padding(.horizontal, 26)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: geometry.size.height, alignment: .top)
                    .clipped()
                    .shotRegion(.autopilotDone)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func dayStarts(_ days: [AutopilotDone.Day]) -> [Int] {
        var starts: [Int] = []
        var total = 0
        for day in days {
            starts.append(total)
            total += day.entries.count
        }
        return starts
    }
}

private struct DoneRow: View {
    let entry: AutopilotEntry
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(entry.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                .frame(width: 48, alignment: .leading)
            CapabilityTile(capability: entry.capability, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).font(Theme.ui(13)).lineLimit(1)
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(place).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.bg3 : .clear))
        .contentShape(Rectangle())
    }

    private var place: String {
        if let ref = entry.ref { return "\(ref.repo.name) #\(ref.number)" }
        return entry.repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? ""
    }
}

/// Done's filters: by capability (`t`) and by repo (`r`), each with this week's count.
private struct DoneRail: View {
    @Environment(AppModel.self) private var model
    let week: [AutopilotEntry]

    var body: some View {
        let browser = model.autopilotBrowser
        let counts = AutopilotDone.counts(week)
        let repos = AutopilotDone.repoCounts(week)
        ListScroll {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionHeader(title: "What")
                    Spacer()
                    KeyCap(text: model.keyText(for: "autopilot.what", in: "done"))
                }
                railRow("Everything", nil, count: week.count, active: browser.doneCapability == nil)
                    .clickRuns(CommandInvocation(name: "autopilot.what", arguments: ["all"]))
                ForEach(Capability.allCases.filter { counts[$0] != nil }) { capability in
                    railRow(
                        capability.title,
                        capability,
                        count: counts[capability] ?? 0,
                        active: browser.doneCapability == capability
                    )
                    .clickRuns(CommandInvocation(name: "autopilot.what", arguments: [capability.rawValue]))
                }
                HStack {
                    SectionHeader(title: "Repo")
                    Spacer()
                    KeyCap(text: model.keyText(for: "autopilot.repo", in: "done"))
                }
                .padding(.top, 14)
                railRow("all", nil, count: nil, active: browser.doneRepo == nil)
                    .clickRuns(CommandInvocation(name: "autopilot.repo", arguments: ["all"]))
                ForEach(repos.keys.sorted(), id: \.self) { slug in
                    railRow(
                        String(slug.split(separator: "/").last ?? ""),
                        nil,
                        count: repos[slug],
                        active: browser.doneRepo == slug
                    )
                    .clickRuns(CommandInvocation(name: "autopilot.repo", arguments: [slug]))
                }
            }
            .padding(20)
        }
        .background(Theme.bg2)
    }

    private func railRow(_ title: String, _ capability: Capability?, count: Int?, active: Bool) -> some View {
        HStack(spacing: 8) {
            if let capability {
                Image(systemName: capability.symbol).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(capability.tint).frame(width: 14)
            }
            Text(title).font(Theme.ui(13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.fg : Theme.fg2)
            Spacer()
            if let count { Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.fg3) }
        }
        .padding(.vertical, 2)
    }
}
