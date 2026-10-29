import HeedCore
import SwiftUI

/// A swarm's agents (`goal.agents`, `W`; deck p12): on the left every worker with what it is doing, for how long and
/// against its estimate (amber over it or stuck); in the middle the one under the cursor, its stuck signal, its
/// progress notes and its activity; on the right what changed since you last looked and what needs you. Once the swarm
/// is done, its end-of-build summary instead.
struct GoalAgentsPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        if let board = goals.board, board.swarm.goal == goal.id {
            if let summary = model.summaryShown(board) {
                SwarmSummaryView(board: board, summary: summary).shotRegion(.swarmSummary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SwarmUsageHeader(board: board)
                    HStack(alignment: .top, spacing: 16) {
                        AgentList(board: board).frame(width: 290).shotRegion(.swarmAgents)
                        if let task = goals.selectedAgentTask {
                            AgentDetail(board: board, task: task).shotRegion(.swarmAgent)
                        } else {
                            EmptyState(
                                title: "No agent has worked yet",
                                detail: "Workers start on the approved plan's ready tasks; each shows here with what "
                                    + "it does, for how long, and whether it looks stuck.",
                                actions: [EmptyState.Action("The plan", "goal.swarm")]
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        ListScroll {
                            VStack(alignment: .leading, spacing: 16) {
                                SinceYouLooked(board: board).shotRegion(.swarmDigest)
                                NeedsYouQueue(board: board, scope: "goalagents").shotRegion(.swarmNeedsYou)
                            }
                        }
                        .frame(width: 330)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(20)
            }
        } else {
            EmptyState(
                title: "No swarm on this goal",
                detail: "A swarm's agents show here once its plan runs: what each does, for how long, and whether it "
                    + "looks stuck.",
                actions: [EmptyState.Action("Swarm this goal", "swarm.start")]
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The swarm's numbers in a line: its state, agents at work, time and money against its limits, tokens.
struct SwarmUsageHeader: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let swarm = board.swarm
        let usage = model.swarmUsage(swarm)
        let rollup = model.swarmRollup(swarm)
        let limits = swarm.settings.limits
        HStack(spacing: 10) {
            Text("Swarm \(swarm.number)").font(Theme.ui(16, weight: .semibold))
            Text(swarm.status.rawValue).font(Theme.mono(10.5)).foregroundStyle(statusColor(swarm.status))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(statusColor(swarm.status).opacity(0.6)))
            Spacer(minLength: 12)
            Text(
                [
                    "\(swarm.liveWorkers.count) live · max \(limits.agents)",
                    "\(SwarmEstimate.text(max(Int(usage.elapsed / 60), 0))) of \(String(format: "%g", limits.hours)) h",
                    "\(AgentUsage.dollars(rollup.dollars)) of $\(String(format: "%g", limits.dollars))",
                    rollup.tokens > 0 ? SwarmUsageRollup.tokens(rollup.tokens) : nil,
                ].compactMap(\.self).joined(separator: " · ")
            )
            .font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
            .help("Stuck when: \(swarm.settings.stuck.line)")
        }
    }

    private func statusColor(_ status: GoalSwarm.Status) -> Color {
        switch status {
        case .running: Theme.busy
        case .paused: Theme.block
        case .landing, .done: Theme.done
        case .planning, .stopped: Theme.fg3
        }
    }
}

// MARK: The list

/// What a worker shows in the list and the detail: its word, what it does now, how long, against its estimate.
struct AgentFacts {
    var word: String
    var color: Color
    var doing: String
    var minutes: Int
    var estimate: Int?
    var signal: SwarmStuck.Signal?
    var live: Bool
    /// What the screen reads and who read it: `screen: stuck · Hunch 84%`, or heed's guess when
    /// Hunch does not read screens; nil when neither says anything.
    var screen: String?

    /// Over its estimate or stuck: amber.
    var amber: Bool { live && (signal?.strong == true || (estimate.map { minutes > $0 } ?? false)) }

    @MainActor
    init(_ task: SwarmTask, board: SwarmBoard, model: AppModel) {
        let live = model.liveWorker(on: task.id)
        let state = live.flatMap { model.runStates[$0.paneID] }
        let signal = model.stuckSignal(task.id, board: board)
        let last = model.workerActivity[task.id]?.last
        let status = model.swarmSchedule(board)?.states[task.id]
        let worker = board.swarm.lastWorker(on: task.id)
        let started = live?.startedAt ?? worker?.startedAt ?? Clock.now
        let ended = live == nil ? worker?.endedAt ?? Clock.now : Clock.now
        self.live = live != nil
        self.signal = signal
        if let live, let reading = model.hunchReading(pane: live.paneID) {
            screen = "screen: \(reading.state.rawValue) · Hunch \(Int((reading.confidence * 100).rounded()))%"
                + (reading.counts ? "" : ", unsure: heed's guess stands")
        } else if let read = signal?.reasons.lazy.compactMap({ reason -> String? in
            if case let .screen(label, source) = reason { "screen: \(label.rawValue) · \(source.title)" } else { nil }
        }).first {
            screen = read
        }
        estimate = task.estimate
        minutes = max(Int(ended.timeIntervalSince(started) / 60), 0)
        if live != nil, signal?.strong == true {
            word = "stuck"
            color = Theme.block
        } else if live != nil, state == .asking || signal?.reasons.contains(where: {
            if case .waitingOnYou = $0 { true } else { false }
        }) == true {
            word = "asking"
            color = Theme.ask
        } else if live != nil, state == .blocked {
            word = "blocked"
            color = Theme.block
        } else if live != nil {
            word = "working"
            color = Theme.busy
        } else {
            word = status.map { $0.state == .pr ? "PR" : $0.state.rawValue } ?? "idle"
            color = status?.state.landed == true ? Theme.done : Theme.fg3
        }
        let since = last.map { max(Int(Clock.now.timeIntervalSince($0.at) / 60), 0) }
        if live == nil {
            doing = status?.reason ?? worker?.outcome?.text ?? "not started"
        } else if let waiting = signal?.reasons.first(where: {
            if case .waitingOnYou = $0 { true } else { false }
        }) {
            doing = "waiting for your answer · \(waiting.text.replacingOccurrences(of: "waiting on you for ", with: ""))"
        } else if let last {
            doing = last.text + (since.map { " · \($0)m ago" } ?? "")
        } else {
            doing = "starting"
        }
    }
}

private struct AgentList: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let goals = model.goals
        let tasks = goals.agentTasks
        let numbers = SwarmPlan.numbers(model.runTasks(board))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Agents · \(tasks.count)")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ListScroll {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        AgentRow(
                            task: task, number: numbers[task.id] ?? "", facts: AgentFacts(
                                task,
                                board: board,
                                model: model
                            ),
                            owner: board.swarm.lastWorker(on: task.id)?.owner.label ?? task.owner?.label ?? "",
                            isCursor: index == goals.agentCursor, focused: goals.focus == .agents,
                            host: model.workerHost(task.id, board: board)
                        )
                        .hint(goals.focus == .agents ? model.hintLabel(for: .row(.goals, index)) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickAgent(index) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.clickAgent(index)
                            model.perform(CommandInvocation(name: "swarm.task.open"))
                        })
                        .rightClickMenu {
                            guard model.clicksReachLists else { return false }
                            model.clickAgent(index)
                            return true
                        } _: { model.agentMenu(task) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

private struct AgentRow: View {
    let task: SwarmTask
    let number: String
    let facts: AgentFacts
    let owner: String
    let isCursor: Bool
    let focused: Bool
    /// The host it runs on, with its colour; nil on this Mac.
    var host: (name: String, color: String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(task.title).font(Theme.ui(13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if let host { HostChip(location: .host(host.name), color: host.color).fixedSize() }
                Text(facts.word).font(Theme.mono(10)).foregroundStyle(facts.color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(facts.color.opacity(0.6)))
            }
            Text("\(number) · \(owner)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            Text(facts.doing).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
            EstimateBar(minutes: facts.minutes, estimate: facts.estimate, amber: facts.amber)
            Text("\(SwarmEstimate.text(max(facts.minutes, 1)))" +
                (facts.estimate.map { " of \(SwarmEstimate.text($0)) est" } ?? ""))
                .font(Theme.mono(10)).foregroundStyle(facts.amber ? Theme.block : Theme.fg3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? (focused ? Theme.bg3 : Theme.bg2) : .clear)
        .overlay(alignment: .leading) { if isCursor, focused { Theme.block.frame(width: 2) } }
    }
}

/// Time on task against the estimate: blue to the estimate, amber past it (or stuck), a tick at the estimate.
struct EstimateBar: View {
    let minutes: Int
    let estimate: Int?
    let amber: Bool

    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(estimate ?? minutes, 1))
            let scale = max(Double(minutes), total) * 1.1
            let filled = geometry.size.width * min(Double(minutes) / scale, 1)
            let mark = geometry.size.width * (total / scale)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg3)
                Capsule().fill(amber ? Theme.block : Theme.busy).frame(width: max(filled, 2))
                if estimate != nil { Theme.fg3.frame(width: 1, height: 7).offset(x: mark) }
            }
        }
        .frame(height: 4)
    }
}

// MARK: One agent

private struct AgentDetail: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let task: SwarmTask

    var body: some View {
        let numbers = SwarmPlan.numbers(model.runTasks(board))
        let facts = AgentFacts(task, board: board, model: model)
        let worker = board.swarm.lastWorker(on: task.id)
        let blocks = model.runTasks(board).filter { $0.after.contains(task.id) }.compactMap { numbers[$0.id] }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(["task \(numbers[task.id] ?? "")", worker?.owner.label, worker?.branch].compactMap(\.self)
                            .joined(separator: " · "))
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                        if let host = model.workerHost(task.id, board: board) {
                            HostChip(location: .host(host.name), color: host.color).fixedSize()
                                .help("Its agent and worktree are on @\(host.name): \(worker?.worktree ?? "")")
                        }
                    }
                    Text(task.title).font(Theme.ui(16, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if facts.live {
                    KeyHint("swarm.task.open", scope: "goalagents", label: "its tab", color: Theme.fg2)
                    KeyHint("swarm.task.pause", scope: "goalagents", label: "pause", color: Theme.fg2)
                    KeyHint("swarm.task.swap", scope: "goalagents", label: "swap", color: Theme.fg2)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                FactBox(
                    title: "Now",
                    value: facts.doing,
                    detail: blocks.isEmpty ? nil
                        : "blocks " + blocks.joined(separator: " and "),
                    color: facts.color
                )
                FactBox(
                    title: "Time on task",
                    value: SwarmEstimate.text(max(facts.minutes, 1))
                        + (facts.estimate.map { " of \(SwarmEstimate.text($0))" } ?? ""),
                    detail: facts.estimate
                        .map { "\(Int((Double(facts.minutes) / Double(max($0, 1)) * 100).rounded()))% of estimate" },
                    color: facts.amber ? Theme.block : Theme.fg
                )
                FactBox(
                    title: "Stuck signal", value: facts.signal.map { $0.main.word } ?? "None",
                    detail: facts.signal?.main.text ?? "stuck after \(board.swarm.settings.stuck.noProgress) min quiet",
                    note: facts.screen,
                    color: facts.signal?.strong == true ? Theme.block : facts.signal == nil ? Theme.fg : Theme.fg2
                )
            }
            ListScroll {
                VStack(alignment: .leading, spacing: 14) {
                    ProgressNotes(board: board, task: task)
                    AgentActivity(board: board, task: task)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

private struct FactBox: View {
    let title: String
    let value: String
    let detail: String?
    var note: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.fg3)
            Text(value).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(color).lineLimit(2)
            if let detail { Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(2) }
            if let note { Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.fg2).lineLimit(2) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
    }
}

/// What the agent says it is doing (`heed swarm note`), and heed's stuck episodes, newest first.
private struct ProgressNotes: View {
    let board: SwarmBoard
    let task: SwarmTask

    var body: some View {
        let address = SwarmAddress.task(task.id).raw
        let rows = board.steering.filter { row in
            (row.kind == .note && row.from == address) || (row.kind == .stuck && row.ref == "task:\(task.id)")
        }.reversed()
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Progress notes · what the agent says it is doing")
            if rows.isEmpty {
                Quiet("None yet: workers write one every few minutes with heed swarm note.")
            }
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.clock(row.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 40, alignment: .leading)
                    Text(row.kind == .stuck ? "!" : "·").font(Theme.mono(11))
                        .foregroundStyle(row.kind == .stuck ? Theme.block : Theme.fg3)
                    Text(row.kind == .stuck ? "heed: \(row.text)" + (row.reason.map { " (\($0))" } ?? "") : row.text)
                        .font(Theme.ui(12.5)).foregroundStyle(row.kind == .stuck ? Theme.block : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func clock(_ date: Date) -> String { Ages.short(date) }
}

/// The agent's activity, newest first: its tool calls (failures in red), the files it changed, and what was said to it
/// and by it.
private struct AgentActivity: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let task: SwarmTask

    private struct Line: Identifiable {
        let id: String
        let at: Date
        let mark: String
        let text: String
        let color: Color
    }

    var body: some View {
        let numbers = SwarmPlan.numbers(model.runTasks(board))
        var lines: [Line] = (model.workerActivity[task.id] ?? []).map { line in
            switch line.kind {
            case let .tool(call):
                Line(
                    id: "a\(line.id)", at: line.at, mark: call.error ? "×" : "•",
                    text: line.text + (line.skipped > 0 ? "  (+\(line.skipped))" : ""),
                    color: call.error ? Theme.err : Theme.fg
                )
            case .files:
                Line(id: "a\(line.id)", at: line.at, mark: "±", text: line.text, color: Theme.done)
            }
        }
        for row in SwarmMessages.log(of: task.id, board.steering) where row.kind != .note {
            let who = row.from.flatMap(SwarmAddress.init(raw:))?.label(numbers) ?? row.actor.rawValue
            lines.append(Line(
                id: "s\(row.id ?? 0)", at: row.at, mark: row.kind == .question ? "?" : "←",
                text: row.kind == .question ? row.text : "\(who): \(row.text)",
                color: row.kind == .question ? Theme.ask : Theme.fg2
            ))
        }
        let shown = lines.sorted { $0.at > $1.at }.prefix(16)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Activity")
            if shown.isEmpty { Quiet("Its tool calls and the files it changes show here as they happen.") }
            ForEach(Array(shown)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ProgressNotes.clock(line.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 40, alignment: .leading)
                    Text(line.mark).font(Theme.mono(11))
                        .foregroundStyle(line.color == Theme.fg ? Theme.busy : line.color)
                        .frame(width: 10)
                    Text(line.text).font(Theme.mono(11.5)).foregroundStyle(line.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: The right column

/// "Since you last looked": what changed on the swarm since you last opened it, in a few sentences, with the decisions
/// and plan versions since.
struct SinceYouLooked: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        if let shown = model.digestShown(board) {
            Panel(title: "Since you last looked", note: Clock.relative(shown.digest.since)) {
                Text(shown.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if !shown.digest.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: "Decisions")
                        ForEach(shown.digest.decisions, id: \.self) { line in
                            Text("· " + line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !shown.digest.versions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: "Plan versions")
                        ForEach(shown.digest.versions, id: \.self) { line in
                            Text(line).font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

/// What waits for you in this swarm: its questions at your step, the selected worker's first, with their options and
/// what each would change. 1…9 pick, i types an answer, c asks the controller.
struct NeedsYouQueue: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let scope: String
    var limit = 4

    var body: some View {
        let waiting = model.waitingOnYou(board)
        Panel(title: "Needs you · \(waiting.count)", note: "") {
            if waiting.isEmpty {
                Quiet("Nothing waits for you: what the controller, the lead or a peer may answer, they do.")
            }
            ForEach(Array(waiting.prefix(limit).enumerated()), id: \.element.id) { index, question in
                SwarmQuestionView(board: board, question: question, keyed: index == 0)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == 0 ? Theme.bg3 : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(index == 0 ? Theme.ask.opacity(0.5)
                            : Theme.line))
            }
            if let first = waiting.first {
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    if !first.row.options.isEmpty {
                        KeyHint(
                            "swarm.answer.option", ["1"],
                            key: first.row.options.count == 1 ? "1" : "1…\(min(first.row.options.count, 9))",
                            scope: scope, label: "answer"
                        )
                    }
                    KeyHint("swarm.answer", scope: scope, label: "type")
                    KeyHint("swarm.controller", scope: scope, label: "ask the controller")
                }
            }
        }
    }
}
