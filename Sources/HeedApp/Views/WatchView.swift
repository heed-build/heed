import HeedCore
import SwiftUI

/// A watched PR's state, small: what the sidebar, the PRs view, Repos and the Watch view show next to a PR.
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
        case .stalled: "⏹"
        case .failing: "✕"
        case .conflicted: "⇄"
        case .changes: "●"
        case .feeding: "⟳"
        case .pending, .draft: "◌"
        case .green, .passing: "✓"
        case .paused: "⏸"
        case let .closed(merged): merged ? "✓" : "✕"
        case .unwatched: "○"
        }
    }

    var text: String {
        switch status {
        case .stuck: "stuck"
        case .stalled: "stalled"
        case let .failing(count): "\(count) failing"
        case let .changes(count): "\(count) thread\(count == 1 ? "" : "s")"
        case .feeding: "feeding"
        case let .conflicted(what): what.hasPrefix("behind") ? "behind" : "conflict"
        case .pending: "running"
        case .draft: "draft"
        case .green: "green"
        case .passing: "passing"
        case let .closed(merged): merged ? "merged" : "closed"
        case let .paused(until): until.map { PilotDuration.text($0.timeIntervalSince(Clock.now)) } ?? "paused"
        case .unwatched: "not watched"
        }
    }

    private var color: Color {
        switch status {
        case .stuck: Theme.block
        case .stalled, .failing, .conflicted: Theme.err
        case .changes: Theme.block
        case .feeding, .pending: Theme.busy
        case .green: Theme.done
        case .passing: Theme.fg2
        case .draft, .paused, .closed, .unwatched: Theme.fg3
        }
    }
}

/// Autopilot's Now (`N`, the view that was Watch): the PRs heed works on, by card (stalled first, with why and the
/// key out; then green, merge, Copilot, and the ones not watched), the PR under the cursor's detail, and on the right
/// what the other capabilities are doing now and the pilot's activity.
struct WatchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.pilotRows
        let cursor = model.cursor(in: .watch)
        let picked = model.pickedIDs(.watch)
        let sections = rows.map { AutopilotNow.section(of: model.autopilotPull($0)) }
        VStack(spacing: 0) {
            AutopilotPaneBar()
            // The helpers at work, live, above the PRs; ↩ on a tile opens it in a split in the PRs' place.
            if !model.helpers.active.isEmpty { HelperTiles() }
            if let helper = model.visibleHelper {
                HelperSplit(helper: helper)
            } else {
                prs(rows: rows, cursor: cursor, picked: picked, sections: sections)
            }
        }
    }

    private func prs(
        rows: [AppModel.PilotRow], cursor: Int, picked: Set<String>, sections: [AutopilotNow.Section?]
    ) -> some View {
        Group {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(summary(rows)).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                            Spacer()
                            FilterPill(view: .watch)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        SyncBanner(status: model.github.status, syncedAt: model.github.syncedAt)
                        ListBody(
                            count: rows.count,
                            cursor: cursor,
                            ids: rows.map(\.id),
                            empty: model.filter(for: .watch).isEmpty
                                ? "Nothing in flight. A session's PR shows here once it is open on the session's "
                                + "branch (\(model.keyText(for: "pr.track")) tracks one by hand); heed then follows its "
                                + "checks and reviews. \(model.keyText(for: "pilot.watch")) stops or starts watching one."
                                : "Nothing matches /\(model.filter(for: .watch)).",
                            hintView: .watch
                        ) { index in
                            VStack(alignment: .leading, spacing: 0) {
                                if let section = sections[index], index == 0 || sections[index - 1] != section {
                                    NowCardHeader(section: section, count: sections.count { $0 == section })
                                        .padding(.top, index == 0 ? 10 : 16)
                                }
                                PilotRowView(
                                    row: rows[index], section: sections[index], index: index, cursor: cursor,
                                    isPicked: picked.contains(rows[index].id)
                                )
                                .shotRegion(sections[index] == .stalled ? .autopilotStalled : nil)
                            }
                        }
                    }
                    .frame(width: geometry.size.width >= 1100 ? 460 : geometry.size.width * 0.45)
                    .frame(height: geometry.size.height, alignment: .top)
                    .clipped()
                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                    Group {
                        if let repo = model.mergeQueueShown {
                            MergeQueueView(repo: repo).shotRegion(.pilotDetail)
                        } else if rows.indices.contains(cursor) {
                            PilotDetail(row: rows[cursor]).shotRegion(.pilotDetail)
                        } else {
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.size.height, alignment: .top)
                    .clipped()
                    if model.inspectorVisible, geometry.size.width >= 1240 {
                        PilotActivity().frame(height: geometry.size.height, alignment: .top).clipped()
                            .shotRegion(.pilotActivity)
                    }
                }
                // Sized to what it is given: a list taller than the window must not grow the row (shots draw it
                // unscrolled).
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func summary(_ rows: [AppModel.PilotRow]) -> String {
        let watched = rows.count { $0.status != .unwatched }
        let stalled = rows.count { AutopilotNow.section(of: model.autopilotPull($0)) == .stalled }
        return "\(watched) watched" + (stalled > 0 ? " · \(stalled) stalled" : "")
    }
}

/// A card's head in Now: the capability's icon and name and how many PRs it has; stalled in amber, saying heed stopped.
private struct NowCardHeader: View {
    let section: AutopilotNow.Section
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            if let capability = section.capability {
                CapabilityTile(capability: capability, size: 26)
                Text(section.title).font(Theme.ui(13.5, weight: .semibold))
            } else if section == .stalled {
                Text("STALLED · \(count)").font(Theme.ui(11.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.block)
                Text("heed stopped here and says why").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
            } else {
                Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    .frame(width: 26, height: 26)
                Text(section.title).font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.fg2)
            }
            Spacer()
            if section != .stalled {
                Text("\(count) PR\(count == 1 ? "" : "s")").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

private struct PilotRowView: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.PilotRow
    let section: AutopilotNow.Section?
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
                    if section == .green, let pipeline = model.feedback[row.ref.description], pipeline.rounds > 0 {
                        RoundPips(rounds: pipeline.rounds, of: pipeline.maxRounds)
                    }
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
                    if row.effective.merge != .off {
                        Text("· merge \(row.effective.merge.configName)").foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.mono(11))
                if let swarm = model.swarmPulls[row.ref.description] { SwarmPullLine(pull: swarm) }
                // Stalled says why, and the way out.
                if section == .stalled {
                    HStack(spacing: 6) {
                        Text(AutopilotNow.why(row.status)).foregroundStyle(Theme.block)
                        if case .stalled = row.status {
                            KeyCap(text: model.keyText(for: "pilot.retry"))
                            Text("one more round").foregroundStyle(Theme.fg3)
                        }
                    }
                    .font(Theme.ui(11.5))
                } else if section == .merge, let plan = model.mergePlan(row.ref) {
                    Text("next run: " + MergeQueueView.describe(plan)).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                        .lineLimit(1)
                } else if section == .unwatched {
                    HStack(spacing: 6) {
                        KeyCap(text: model.keyText(for: "pilot.watch"))
                        Text("watches it").foregroundStyle(Theme.fg3)
                    }
                    .font(Theme.ui(11.5))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isPicked ? Theme.block.opacity(0.18) : index == cursor ? Theme.bg3
            : section == .stalled ? Theme.block.opacity(0.06) : .clear)
        .opacity(row.status == .unwatched ? 0.6 : 1)
    }
}

/// Get it green's rounds so far, of the most it sends without a new approval.
struct RoundPips: View {
    let rounds: Int
    let of: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< max(of, 1), id: \.self) { index in
                Capsule().fill(index < rounds ? Theme.busy : Theme.line).frame(width: 14, height: 4)
            }
        }
        .help("round \(rounds) of \(of)")
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
                    if row.status.group != .done {
                        PilotGreenLine(ref: row.ref)
                        PilotPlanLine(ref: row.ref)
                        PilotMergeLine(ref: row.ref)
                    }
                }
                // Whole hints wrap to a new line on a narrow window; none breaks inside its words.
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    KeyHint("open.reader", key: "↩", spacing: 5, label: "open")
                    KeyHint(
                        "pilot.watch", target: .pull(row.ref), spacing: 5,
                        label: row.effective.watching ? "stop watching" : "watch"
                    )
                    KeyHint("pilot.green", target: .pull(row.ref), spacing: 5, label: "green")
                    KeyHint(
                        "pilot.merge", target: .pull(row.ref), spacing: 5,
                        label: row.effective.merge.next == .off ? "stop merging"
                            : "merge \(row.effective.merge.next.configName)"
                    )
                    KeyHint(
                        "pilot.pause", target: .pull(row.ref), spacing: 5,
                        label: pipeline?.isPaused(Clock.now) == true ? "resume" : "pause"
                    )
                    if let pipeline, !CopilotAsk.items(
                        pipeline,
                        settings: model.pilotSettings(for: row.ref),
                        everything: true
                    ).isEmpty {
                        KeyHint(
                            "pilot.copilot",
                            target: .pull(row.ref),
                            scope: "watch",
                            spacing: 5,
                            label: "ask Copilot"
                        )
                    }
                }
                // The verdict, rule by rule: what holds the PR back from green, or that nothing does.
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Green")
                    if let detail = model.pullDetails[row.ref.description] {
                        ForEach(GreenVerdict.of(detail).rules) { rule in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(rule.state == .pass ? "✓" : rule.state == .fail ? "✕" : "◌")
                                    .foregroundStyle(rule.state == .pass ? Theme.done
                                        : rule.state == .fail ? Theme.err : Theme.busy)
                                    .frame(width: 14)
                                Text(rule.name).font(Theme.ui(12.5)).frame(width: 150, alignment: .leading)
                                Text(rule.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                            }
                        }
                    } else {
                        Text("Not fetched yet: heed fetches a watched PR's detail when it moves.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                }
                MergeSection(ref: row.ref, mode: row.effective.merge)
                if let pipeline, !pipeline.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Items")
                        ForEach(pipeline.items.filter { $0.status != .resolved }) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.status.rawValue).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                                    .frame(width: 70, alignment: .leading)
                                Text(item.copilotAskedAt == nil ? item.promptLine
                                    : "\(item.text) Copilot was asked \(Clock.relative(item.copilotAskedAt!))")
                                    .font(Theme.ui(12.5)).lineLimit(2)
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
}

/// Now's right column: what the capabilities that are not about one PR are doing (merge queues, cleanup, summaries,
/// goal asks), then everything the pilot did lately, across PRs.
private struct PilotActivity: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Also now")
                Spacer()
                KeyCap(text: model.keyText(for: "inspector.toggle"))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ListScroll {
                VStack(alignment: .leading, spacing: 14) {
                    let queues = model.mergeQueues
                    if !queues.isEmpty {
                        NowSideCard(capability: .merge, note: "\(queues.count) queue\(queues.count == 1 ? "" : "s")") {
                            ForEach(queues.keys.sorted(), id: \.self) { repo in
                                MergeQueueLine(repo: repo, count: queues[repo]?.count ?? 0)
                            }
                        }
                    }
                    cleanup
                    summaries
                    goals
                    Theme.line.frame(height: 1)
                    SectionHeader(title: "Activity")
                    if model.pilotLog.isEmpty {
                        Text("The pilot has not done anything yet.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(model.pilotLog.prefix(60)) { event in
                        PilotEventRow(event: event, showPR: true)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 330)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    @ViewBuilder private var cleanup: some View {
        let on = model.config.cleanup.enabled
        let plan = on ? model.sweepPlan : model.sweepPlanIfOn
        let count = plan.removals.count
        NowSideCard(capability: .cleanup, note: on ? "hourly" : "off") {
            Text(count == 0 ? "Nothing idle enough to remove on the next run."
                : "\(count) worktree\(count == 1 ? "" : "s") \(on ? "go" : "would go") on the next run: idle "
                + "\(model.config.cleanup.idleDays)+ days, work pushed.")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if !on { KeyHint("autopilot.cando", ["cleanup"], scope: "watch", label: "turn on in Can do") }
        }
    }

    @ViewBuilder private var summaries: some View {
        let progress = model.attention.summaryProgress
        let mode = model.config.attention.summaries
        NowSideCard(capability: .summaries, note: mode == .ahead ? "ahead" : mode == .open ? "on open" : "off") {
            Text(progress.map { "writing \($0.done) of \($0.total) catch-ups ahead" }
                ?? "None in flight: written after a sync, for For you's New.")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }

    @ViewBuilder private var goals: some View {
        let asks = model.goals.attach.asks
        if !asks.isEmpty {
            NowSideCard(capability: .goals, note: "\(asks.count) ask\(asks.count == 1 ? "" : "s")") {
                ForEach(asks.prefix(3), id: \.id) { ask in
                    Text(ask.subject.title).font(Theme.ui(12)).lineLimit(1)
                }
                Text("Attention and Goals › Unassigned answer them: y n m i.").font(Theme.ui(11.5))
                    .foregroundStyle(Theme.fg3)
            }
        }
    }
}

/// A small card on Now's right: a capability's icon and name, a note, and what it is doing.
private struct NowSideCard<Content: View>: View {
    let capability: Capability
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CapabilityTile(capability: capability, size: 24)
                Text(capability.title).font(Theme.ui(13, weight: .semibold))
                Spacer()
                Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
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
        case .retry: Theme.busy
        case .helperDone: Theme.done
        case .watch, .green, .pause, .merge: Theme.fg3
        case .autoMerge, .updated: Theme.busy
        case .merged: Theme.done
        case .held: Theme.block
        case .copilot, .review: Theme.busy
        }
    }
}

/// A PR's get it merged: its mode, GitHub's auto-merge, what the next run would do, and what the last one did.
private struct MergeSection: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef
    let mode: MergeMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Merge")
            if mode == .off {
                Text(
                    "Off: \(model.keyText(for: "pilot.merge")) turns get it merged on: auto (GitHub's auto-merge), then heed (heed merges by its rules)."
                )
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            } else {
                let detail = model.pullDetails[ref.description]
                line(
                    "Mode",
                    mode == .heed ? "heed: heed merges once every rule below holds"
                        : "auto: GitHub merges once its requirements are met"
                )
                if mode == .heed, let detail {
                    let verdict = HeedMerge.verdict(
                        detail, settings: model.pilotSettings(for: ref),
                        selfReview: model.feedback[ref.description]?.selfReview, now: Clock.now
                    )
                    ForEach(verdict.rules) { rule in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(rule.state == .pass ? "✓" : rule.state == .fail ? "✕" : "◌")
                                .foregroundStyle(rule.state == .pass ? Theme.done
                                    : rule.state == .fail ? Theme.err : Theme.busy)
                                .frame(width: 14)
                            Text(rule.name).font(Theme.ui(12.5)).frame(width: 150, alignment: .leading)
                            Text(rule.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if let detail {
                    line(
                        "Auto-merge",
                        detail.autoMergeEnabled == true
                            ? "on" + (detail.autoMergeMethod.map { " (\($0))" } ?? "") : "off"
                    )
                }
                if let action = model.mergePlan(ref) { line("Next run", MergeQueueView.describe(action)) }
                if let next = model.nextMergeRun(ref.repo.slug) {
                    line(
                        "Queue",
                        "\(ref.repo.slug) runs " + MergeQueueView.when(next) + " · \(model.keyText(for: "merge.queue")) shows it"
                    )
                } else {
                    line(
                        "Queue",
                        "\(ref.repo.slug) runs only when asked (\(model.keyText(for: "merge.run", in: "watch")), :merge.run)"
                    )
                }
                if let last = model.mergeRuns[ref.repo.slug]?.first,
                   let entry = last.lines.first(where: { $0.ref == ref })
                {
                    line("Last run", "\(entry.action): \(entry.detail)")
                }
            }
        }
    }

    private func line(_ name: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(Theme.ui(12.5)).frame(width: 172, alignment: .leading)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One repo's queue in the activity column: its PRs and when it runs.
private struct MergeQueueLine: View {
    @Environment(AppModel.self) private var model
    let repo: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(repo).font(Theme.mono(11.5)).lineLimit(1)
            Spacer(minLength: 4)
            Text(summary).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
    }

    private var summary: String {
        let prs = "\(count) PR\(count == 1 ? "" : "s")"
        if model.mergeRunning.contains(repo) { return "\(prs) · running" }
        return prs + " · " + (model.nextMergeRun(repo).map(MergeQueueView.when) ?? "manual")
    }
}

/// `gM`: a repo's merge queue: its PRs with what the next run does to each, and the runs so far.
struct MergeQueueView: View {
    @Environment(AppModel.self) private var model
    let repo: String

    var body: some View {
        // A swarm's PRs in its merge order, in the places they hold among the rest (as a run takes them).
        let refs = MergeQueue.sorted(model.mergeQueues[repo] ?? [], order: model.swarmMergeOrder)
        let runs = model.mergeRuns[repo] ?? []
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Merge queue").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    Text(repo).font(Theme.ui(16, weight: .semibold))
                    Text(header).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    KeyHint("merge.run", [repo], scope: "watch", spacing: 5, label: "run now")
                    KeyHint("merge.queue", spacing: 5, label: "back to the PR")
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "PRs · \(refs.count)")
                    if refs.isEmpty {
                        Text("No PRs here with merge on: \(model.keyText(for: "pilot.merge")) on a PR adds it.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.fg3)
                    }
                    ForEach(refs, id: \.self) { ref in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "#\(ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                                .frame(width: 56, alignment: .leading)
                            PilotMark(status: model.pilotStatus(for: ref)).frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.github.pull(ref)?.title ?? model.pullDetails[ref.description]?
                                    .title ?? "#\(ref.number)")
                                    .font(Theme.ui(12.5))
                                    .lineLimit(1)
                                if let swarm = model.swarmPulls[ref.description] { SwarmPullLine(pull: swarm) }
                                Text(model.mergePlan(ref).map(Self.describe) ?? "not fetched yet")
                                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(2)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Runs")
                    if runs.isEmpty {
                        Text("Not run yet.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(runs.prefix(20)) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(run.at, format: .dateTime.month().day().hour().minute())
                                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                                Text(run.why).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                            }
                            if run.lines.isEmpty {
                                Text("nothing to do").font(Theme.ui(12)).foregroundStyle(Theme.fg3).padding(
                                    .leading,
                                    14
                                )
                            }
                            ForEach(Array(run.lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(color(line)).frame(width: 6, height: 6)
                                    Text(verbatim: "#\(line.ref.number)").font(Theme.mono(11.5))
                                        .foregroundStyle(Theme.fg2)
                                    Text("\(line.action): \(line.detail)").font(Theme.ui(12.5))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.leading, 14)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: String {
        if model.mergeRunning.contains(repo) { return "running now" }
        let next = model.nextMergeRun(repo).map { "next run " + Self.when($0) } ?? "runs only when asked"
        let last = model.mergeRuns[repo]?.first.map { " · last run \(Self.when($0.at))" } ?? ""
        return next + last
    }

    private func color(_ line: MergeRun.Line) -> Color {
        if !line.ok { return Theme.err }
        return switch line.action {
        case "held": Theme.block
        case "waiting": Theme.fg3
        default: Theme.busy
        }
    }

    static func describe(_ action: MergeQueue.Action) -> String {
        switch action {
        case let .enableAutoMerge(method): "turn auto-merge on (\(method))"
        case let .merge(method, admin): "merge (\(method)\(admin ? ", --admin if refused" : ""))"
        case .selfReview: "run the self-review, then merge if it approves"
        case let .disableAutoMerge(reason): "turn auto-merge off: \(reason)"
        case .updateBranch: "bring the branch up to date"
        case let .waiting(text): text
        case let .hold(reason): "hold: \(reason)"
        }
    }

    /// `in 42m`, `3m ago`, `now`.
    static func when(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(Clock.now)
        if abs(seconds) < 60 { return "now" }
        return seconds > 0 ? "in \(PilotDuration.text(seconds))" : "\(PilotDuration.text(-seconds)) ago"
    }
}

/// A swarm PR's place in its swarm's merge order, on every row it shows on: `swarm 1 · 2/4 · after #412`, and held
/// while what it waits for is unmerged.
struct SwarmPullLine: View {
    let pull: SwarmPull

    var body: some View {
        HStack(spacing: 6) {
            Text("swarm \(pull.number) · \(pull.label)").foregroundStyle(Theme.fg2)
            if pull.hold != nil { Text("held").foregroundStyle(Theme.block) }
        }
        .font(Theme.mono(11))
        .lineLimit(1)
        .help(pull.hold.map { "Held: \($0)" } ?? "Its place in the swarm's merge order")
    }
}
