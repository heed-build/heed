import HeedCore
import SwiftUI

/// A goal's swarm (`goal.swarm`, `S`): on the left the plan's outline by phase (task, owner, estimate, what it waits
/// for, when it is done); on the right what the lead asks, a change waiting for you, the plan's versions with what
/// each changed, and the steering log. Every act here is a new version or a steering row.
struct GoalPlanPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        if let board = goals.board, board.swarm.goal == goal.id {
            HStack(alignment: .top, spacing: 16) {
                PlanOutline(board: board).shotRegion(.swarmOutline)
                ListScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        if let draft = goals.planDraft { PlanEditor(draft: draft).shotRegion(.swarmEditor) }
                        if board.swarm.held != nil { LimitAsk(swarm: board.swarm).shotRegion(.swarmLimit) }
                        if board.swarm.approved != nil, board.swarm.status != .planning {
                            MergeOrder(board: board).shotRegion(.swarmOrder)
                        }
                        LeadQuestions(board: board).shotRegion(.swarmQuestions)
                        if let pending = board.pending { PendingChange(board: board, pending: pending) }
                        PlanVersions(board: board).shotRegion(.swarmVersions)
                        SteeringLog(board: board).shotRegion(.swarmSteering)
                    }
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(20)
            .shotRegion(.swarmPlan)
        } else {
            EmptyState(
                title: "No swarm on this goal",
                detail: "A swarm is a burst of parallel work on the goal: a lead agent drafts a plan, you read and "
                    + "change it, and nothing runs before you approve it.",
                actions: [EmptyState.Action("Swarm this goal", "swarm.start")]
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: The outline

private struct PlanOutline: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let goals = model.goals
        let swarm = board.swarm
        let tasks = goals.planTasks
        let numbers = SwarmPlan.numbers(tasks)
        let estimate = SwarmPlan.estimate(tasks)
        let schedule = model.swarmSchedule(board)
        let shown = goals.shownTasks
        // Once it runs, each task's place in the merge order.
        let landing = swarm.approved != nil && swarm.status != .planning
            ? Dictionary(model.landingRows(board).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(swarm.plan == 0 ? "Plan" : "Plan · \(swarm.isApproved ? "" : "draft ")v\(swarm.plan)")
                        .font(Theme.ui(16, weight: .semibold))
                    if swarm.plan > 0 { PlanBadge(swarm: swarm, board: board) }
                    Spacer(minLength: 12)
                    Text(planNumbers(tasks.count, estimate, swarm))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Text(
                    "Swarm \(swarm.number) · lead \(swarm.settings.lead.label) · \(swarm.settings.limits.line) · "
                        + swarm.settings.autonomy.title.lowercased()
                )
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(1)
                if let schedule, swarm.approved != nil {
                    RunLine(swarm: swarm, tasks: model.runTasks(board), schedule: schedule)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if tasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(swarm.status.active ? "The lead is drafting the plan" : "This swarm ended without a plan")
                        .font(Theme.ui(14, weight: .medium))
                    Quiet(
                        swarm.lead == nil
                            ? "Its tasks show here as the lead proposes them, with who does each, how long it should "
                            + "take, what it waits for and how we will know it is done."
                            : "Its tasks show here as the lead proposes them. The lead's session is on the goal: "
                            + "↩ on it under the overview goes there."
                    )
                }
                .padding(18)
            } else {
                ListScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        if goals.byMergeOrder {
                            HStack(spacing: 6) {
                                SectionHeader(title: "Merge order · what a task waits for merges first")
                                Spacer(minLength: 6)
                                KeyHint("swarm.order", scope: "goalplan", label: "by phase", color: Theme.fg3)
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            ForEach(Array(shown.enumerated()), id: \.element.id) { row, task in
                                taskRow(
                                    task, row: row, numbers: numbers, schedule: schedule, swarm: swarm,
                                    landing: landing[task.id]
                                )
                            }
                        } else {
                            ForEach(Array(SwarmPlan.phases(tasks).enumerated()), id: \.offset) { index, phase in
                                HStack(spacing: 6) {
                                    SectionHeader(title: "\(index + 1) · \(phase.name)")
                                    Spacer(minLength: 6)
                                    let minutes = SwarmPlan.estimate(phase.tasks)
                                    if minutes > 0 {
                                        Text(SwarmEstimate.text(minutes)).font(Theme.mono(10.5))
                                            .foregroundStyle(Theme.fg3)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                ForEach(phase.tasks) { task in
                                    taskRow(
                                        task, row: tasks.firstIndex { $0.id == task.id } ?? 0, numbers: numbers,
                                        schedule: schedule, swarm: swarm, landing: landing[task.id]
                                    )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            Spacer(minLength: 0)
            if swarm.status.active {
                Theme.line.frame(height: 1)
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    if swarm.approved != nil, swarm.status != .planning {
                        // Running: what acts on the work; the plan's other edits are in the menus and on keys.
                        KeyHint(
                            "swarm.order", scope: "goalplan", label: goals.byMergeOrder ? "by phase" : "merge order"
                        )
                        KeyHint("swarm.task.pause", scope: "goalplan", label: "pause task")
                        KeyHint("swarm.task.swap", scope: "goalplan", label: "swap agent")
                        KeyHint("swarm.task.open", scope: "goalplan", label: "its worker")
                        KeyHint("swarm.task.edit", scope: "goalplan", label: "edit task")
                        KeyHint("swarm.replan", scope: "goalplan", label: "re-plan")
                        KeyHint(
                            "swarm.pause", scope: "goalplan",
                            label: swarm.status == .paused ? "resume swarm" : "pause swarm"
                        )
                        if board.pending != nil {
                            KeyHint("swarm.accept", scope: "goalplan", label: "take the change", color: Theme.fg)
                        }
                    } else {
                        KeyHint("swarm.task.edit", scope: "goalplan", label: "edit task")
                        KeyHint("swarm.task.add", scope: "goalplan", label: "add")
                        KeyHint("swarm.task.move", ["1"], key: "J K", scope: "goalplan", label: "move")
                        KeyHint("swarm.task.drop", scope: "goalplan", label: "drop")
                        KeyHint("swarm.replan", scope: "goalplan", label: "re-plan with feedback")
                        if board.pending != nil {
                            KeyHint("swarm.accept", scope: "goalplan", label: "take the change", color: Theme.fg)
                        } else {
                            KeyHint(
                                "swarm.approve", scope: "goalplan", label: swarm.isApproved ? "approved" : "approve",
                                color: swarm.isApproved ? Theme.fg3 : Theme.fg
                            )
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// A task's row, at `row` of the tasks shown: click, double-click, right-click and hints as everywhere.
    private func taskRow(
        _ task: SwarmTask, row: Int, numbers: [String: String], schedule: SwarmScheduler.Schedule?, swarm: GoalSwarm,
        landing: SwarmLanding.Row?
    ) -> some View {
        let goals = model.goals
        return TaskRow(
            task: task, number: numbers[task.id] ?? "", numbers: numbers,
            isCursor: row == goals.taskCursor, focused: goals.focus == .tasks,
            status: schedule?.states[task.id], worker: swarm.lastWorker(on: task.id), landing: landing
        )
        .shotRegion(task.slug == "validator-speed" ? .swarmTask : task.slug == "sample-site" ? .swarmHeld : nil)
        .hint(goals.focus == .tasks ? model.hintLabel(for: .row(.goals, row)) : nil)
        .contentShape(Rectangle())
        .onTapGesture { model.clickPlanTask(row) }
        .simultaneousGesture(TapGesture(count: 2)
            .onEnded { model.clickPlanTask(row, edit: true) })
        .rightClickMenu {
            guard model.clicksReachLists else { return false }
            model.clickPlanTask(row)
            return true
        } _: { model.planTaskMenu(row) }
    }

    private func planNumbers(_ count: Int, _ minutes: Int, _ swarm: GoalSwarm) -> String {
        let agents = swarm.settings.workers.reduce(0) { $0 + $1.count }
        return [
            "\(count) task\(count == 1 ? "" : "s")",
            minutes > 0 ? "est \(SwarmEstimate.text(minutes))" : nil,
            agents > 0 ? "\(agents) agent\(agents == 1 ? "" : "s")" : nil,
        ]
        .compactMap(\.self).joined(separator: " · ")
    }
}

/// `from lead`, `approved`, `stopped`.
private struct PlanBadge: View {
    let swarm: GoalSwarm
    let board: SwarmBoard

    var body: some View {
        let author = board.version(swarm.plan)?.author
        let (text, color): (String, Color) = if !swarm.status.active {
            (swarm.status.rawValue, swarm.status == .done ? Theme.done : Theme.fg3)
        } else if swarm.isApproved, swarm.status != .planning {
            (
                swarm.status.rawValue,
                swarm.status == .paused ? Theme.block : swarm.status == .landing ? Theme.done
                    : Theme.busy
            )
        } else if swarm.isApproved {
            ("approved", Theme.done)
        } else {
            (author == .lead ? "from lead" : author == .restore ? "restored" : "edited by you", Theme.block)
        }
        Text(text).font(Theme.mono(10.5)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6)))
    }
}

private struct TaskRow: View {
    let task: SwarmTask
    let number: String
    let numbers: [String: String]
    let isCursor: Bool
    let focused: Bool
    /// Where it stands in a running swarm, and its newest worker.
    var status: SwarmTaskStatus?
    var worker: SwarmWorker?
    /// Its place in the merge order, once the swarm runs.
    var landing: SwarmLanding.Row?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                if let status {
                    TaskState(status: status, task: task, worker: worker, numbers: numbers)
                }
                if let landing { LandingLine(row: landing) }
                if landing == nil, !task.after.isEmpty {
                    Text("after " + task.after.map { numbers[$0] ?? SwarmPlan.short($0) }.joined(separator: " "))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
                ForEach(task.doneWhen, id: \.self) { check in
                    Text("done when: \(check)").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let owner = task.owner {
                Text(owner.label).font(Theme.mono(10.5)).foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
            }
            Text(task.estimate.map(SwarmEstimate.text) ?? "–").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? (focused ? Theme.bg3 : Theme.bg2) : .clear)
        .overlay(alignment: .leading) { if isCursor, focused { Theme.block.frame(width: 2) } }
    }
}

/// A task's state in a running swarm: a chip, why, and for a working one its agent and time against its estimate.
private struct TaskState: View {
    let status: SwarmTaskStatus
    let task: SwarmTask
    let worker: SwarmWorker?
    let numbers: [String: String]

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.word(status.state)).font(Theme.mono(10.5)).foregroundStyle(Self.color(status.state))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.color(status.state).opacity(0.6)))
            if let reason = status.reason {
                Text(reason).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            if status.state == .working, let worker {
                let minutes = Int(Clock.now.timeIntervalSince(worker.startedAt) / 60)
                let over = task.estimate.map { minutes > $0 } ?? false
                Text(SwarmEstimate
                    .text(max(minutes, 1)) + (task.estimate.map { " of \(SwarmEstimate.text($0))" } ?? ""))
                    .font(Theme.mono(10.5)).foregroundStyle(over ? Theme.block : Theme.fg3)
            }
            if let stacked = (status.state == .working || status.state == .ready) ? status.stackedOn : nil {
                Text("stacked on \(numbers[stacked] ?? SwarmPlan.short(stacked))")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ask)
                    .help("Its branch starts from \(status.base ?? "its blocker's branch"); its PR goes against it")
            }
        }
    }

    static func word(_ state: SwarmTaskStatus.State) -> String {
        switch state {
        case .pr: "PR"
        default: state.rawValue
        }
    }

    static func color(_ state: SwarmTaskStatus.State) -> Color {
        switch state {
        case .waiting: Theme.fg3
        case .ready: Theme.fg2
        case .working: Theme.busy
        case .paused: Theme.block
        case .stalled: Theme.err
        case .pr: Theme.ask
        case .green, .merged, .done: Theme.done
        }
    }
}

/// A running swarm's numbers under the plan's header: tasks done, agents at work, time and money against its limits.
private struct RunLine: View {
    @Environment(AppModel.self) private var model
    let swarm: GoalSwarm
    let tasks: [SwarmTask]
    let schedule: SwarmScheduler.Schedule

    var body: some View {
        let progress = SwarmProgress(swarm: swarm, tasks: tasks, states: schedule.states)
        let usage = model.swarmUsage(swarm)
        let limits = swarm.settings.limits
        let merged = tasks.count { [.merged, .done].contains(schedule.states[$0.id]?.state) }
        let landed: String? = swarm.status == .done ? "landed: every task merged in merge order"
            : swarm.status == .landing ? "landing: \(merged) of \(tasks.count) merged" : nil
        Text(
            [
                landed,
                progress.tasksLine,
                "agents \(progress.agentsLine)",
                "\(SwarmEstimate.text(Int(usage.elapsed / 60))) of \(String(format: "%g", limits.hours)) h",
                "\(AgentUsage.dollars(usage.dollars)) of $\(String(format: "%g", limits.dollars))",
            ].compactMap(\.self).joined(separator: " · ")
        )
        .font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
    }
}

/// The swarm stopped at a limit: what it reached, and the say you have (here, and in Needs you).
private struct LimitAsk: View {
    let swarm: GoalSwarm

    var body: some View {
        if let limit = swarm.held {
            let more = swarm.settings.limits.raised(limit)
            Panel(title: "Paused at \(limit.text(swarm.settings.limits))", note: "waits for you") {
                Text(
                    "Nothing more starts; workers at work finish their turn. More time or money is yours to give: "
                        + "Needs you asks too."
                )
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                KeyHint(
                    "swarm.pause", scope: "goalplan",
                    label: "raise it to " + (limit == .hours ? "\(String(format: "%g", more.hours)) h"
                        : "$\(String(format: "%g", more.dollars))") + " and go on",
                    color: Theme.fg
                )
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.5)))
        }
    }
}

// MARK: The right column

/// What the lead asks, and your answers: c answers the first open one; a click on a choice answers with it.
private struct LeadQuestions: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let open = board.openQuestions.count
        let questions = board.questions
        Panel(
            title: open == 0 ? "The lead's questions" : "The lead asks \(open) thing\(open == 1 ? "" : "s")",
            note: questions.isEmpty ? "" : "\(questions.count - open) answered"
        ) {
            if questions.isEmpty {
                Quiet("None yet. What the lead cannot decide from the goal and the code, it asks here.")
            }
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1). \(question.row.text)").font(Theme.ui(12.5))
                        .foregroundStyle(question.answer == nil ? Theme.fg : Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let answer = question.answer {
                        Text("→ \(answer.text)").font(Theme.ui(12)).foregroundStyle(Theme.done)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if board.swarm.status.active {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            // The first open question's options carry the digit that picks them.
                            let first = question.id == board.openQuestions.first?.id
                            ForEach(Array(question.row.options.enumerated()), id: \.element) { number, option in
                                Text(first && number < 9 ? "\(number + 1) \(option)" : option).font(Theme.ui(11.5))
                                    .foregroundStyle(Theme.fg2)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                                    .clickable()
                                    .onTapGesture { model.answerLead([option], question: question.id) }
                                    .help("Answer: \(option)")
                            }
                            Text("or type").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                .clickable()
                                .onTapGesture {
                                    model.answerLead([], question: question.id)
                                }
                        }
                    }
                }
            }
            if open > 0 {
                HStack(spacing: 14) {
                    if let first = board.openQuestions.first, !first.row.options.isEmpty {
                        KeyHint(
                            "swarm.answer.option", ["1"], key: first.row.options.count == 1 ? "1"
                                : "1…\(min(first.row.options.count, 9))",
                            scope: "goalplan", label: "pick an option"
                        )
                    }
                    KeyHint("swarm.answer", scope: "goalplan", label: "type an answer")
                }
            }
        }
    }
}

/// A structural change of the lead's after approval: what it changes, y takes it, n says no (as in GOAL.md).
private struct PendingChange: View {
    let board: SwarmBoard
    let pending: SwarmSteer

    var body: some View {
        Panel(title: "The lead proposes a change", note: "waits for you") {
            Text(pending.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            PlanDiffLines(lines: SwarmPlan.lines(old: board.tasks, new: pending.tasks ?? []), limit: 8)
            HStack(spacing: 14) {
                KeyHint("swarm.accept", scope: "goalplan", label: "yes", color: Theme.fg)
                KeyHint("swarm.reject", scope: "goalplan", label: "say no")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.5)))
    }
}

/// Every version, newest first, who made it and why; the one under the cursor shows what it changed.
private struct PlanVersions: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let goals = model.goals
        let versions = board.versions
        Panel(title: "Versions", note: "\(versions.count)") {
            if versions.isEmpty { Quiet("The lead's first proposal is v1. Every change after is a new version.") }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    let isCursor = index == goals.versionCursor
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("v\(version.number)").font(Theme.mono(11.5))
                                .foregroundStyle(version.number == board.swarm.plan ? Theme.block : Theme.fg3)
                            Text(version.author.rawValue).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                            Text(version.note).font(Theme.ui(12)).foregroundStyle(Theme.fg).lineLimit(1)
                            Spacer(minLength: 6)
                            if board.swarm.approved == version.number {
                                Text("approved").font(Theme.mono(10.5)).foregroundStyle(Theme.done)
                            }
                            Text(Clock.relative(version.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        }
                        if isCursor {
                            let previous = versions.indices.contains(index + 1) ? versions[index + 1] : nil
                            VStack(alignment: .leading, spacing: 6) {
                                Text(previous.map { "v\($0.number) → v\(version.number)" } ?? "the first version")
                                    .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                                PlanDiffLines(
                                    lines: SwarmPlan.lines(old: previous?.tasks ?? [], new: version.tasks),
                                    limit: goals.fullDiff ? nil : 6
                                )
                                .shotRegion(.swarmDiff)
                                HStack(spacing: 14) {
                                    KeyHint("swarm.diff", scope: "goalplan", label: goals.fullDiff ? "short" : "diff")
                                    if version.number != board.swarm.plan, board.swarm.status.active {
                                        KeyHint(
                                            "swarm.restore", ["\(version.number)"], scope: "goalplan",
                                            label: "restore v\(version.number)"
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(isCursor && goals.focus == .versions ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) {
                        if isCursor, goals.focus == .versions { Theme.block.frame(width: 2) }
                    }
                    .hint(goals.focus == .versions ? model.hintLabel(for: .row(.goals, index)) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickPlanVersion(index) }
                    .rightClickMenu {
                        guard model.clicksReachLists else { return false }
                        model.clickPlanVersion(index)
                        return true
                    } _: { model.planVersionMenu(index) }
                }
            }
        }
    }
}

/// A plan diff's lines: red out, green in, the task they are about in plain.
struct PlanDiffLines: View {
    let lines: [SwarmPlan.DiffLine]
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(lines.prefix($0)) } ?? lines
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty { Text("no change").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text("\(line.mark.glyph) \(line.text)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(color(line.mark))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(background(line.mark))
            }
            if shown.count < lines.count {
                Text("+\(lines.count - shown.count) more").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
    }

    private func color(_ mark: SwarmPlan.DiffLine.Mark) -> Color {
        switch mark {
        case .added: Theme.done
        case .removed: Theme.err
        case .moved: Theme.busy
        case .context: Theme.fg2
        }
    }

    private func background(_ mark: SwarmPlan.DiffLine.Mark) -> Color {
        switch mark {
        case .added: Theme.done.opacity(0.08)
        case .removed: Theme.err.opacity(0.08)
        default: .clear
        }
    }
}

/// Who decided what, newest first.
private struct SteeringLog: View {
    let board: SwarmBoard

    var body: some View {
        let rows = Array(board.steering.reversed())
        Panel(title: "Steering log", note: "\(rows.count)") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.actor.rawValue).font(Theme.mono(10)).foregroundStyle(actorColor(row.actor))
                            .frame(width: 34, alignment: .leading)
                        Text(SwarmSteering.line(row)).font(Theme.ui(12)).foregroundStyle(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(Clock.relative(row.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    }
                }
                if rows.count > 10 {
                    Text("\(rows.count - 10) older").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
    }

    private func actorColor(_ actor: SwarmSteer.Actor) -> Color {
        switch actor {
        case .you: Theme.fg
        case .lead: Theme.block
        case .controller: Theme.ask
        case .agent: Theme.busy
        case .heed: Theme.fg3
        }
    }
}

/// The editor for a task's fields, feedback for the lead, an answer, or why not: ⌘↩ saves, ⎋ leaves.
private struct PlanEditor: View {
    @Environment(AppModel.self) private var model
    let draft: PlanDraft

    var body: some View {
        Panel(title: title, note: "") {
            if draft.isTask {
                field("Title", \.fields.title)
                HStack(spacing: 8) {
                    field("Phase", \.fields.phase)
                    field("Owner (agent:model)", \.fields.owner)
                    field("Estimate", \.fields.estimate).frame(width: 80)
                }
                field("After (1.2, 2.1)", \.fields.after)
                field("Done when (one per line)", \.fields.doneWhen, lines: 3)
            } else {
                if case let .answer(id) = draft.kind,
                   let question = model.goals.board?.questions.first(where: { $0.id == id })
                {
                    Text(question.row.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field(placeholder, \.text, lines: 3)
            }
            HStack(spacing: 18) {
                Spacer()
                KeyHint(keys: "<Esc>", label: "cancel")
                KeyHint(keys: "<D-CR>", label: "save", color: Theme.fg)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.6)))
    }

    private var title: String {
        switch draft.kind {
        case .edit: "Edit the task"
        case .add: "Add a task"
        case .replan: "Re-plan: what should change"
        case .answer: "Answer the lead"
        case .reject: "Why not (optional)"
        }
    }

    private var placeholder: String {
        switch draft.kind {
        case .replan: "Tell the lead what to change"
        case .answer: "Your answer"
        default: "Why not"
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ path: WritableKeyPath<PlanDraft, String>, lines: Int = 1) -> some View {
        let binding = Binding(
            get: { model.goals.planDraft?[keyPath: path] ?? "" },
            set: { model.goals.planDraft?[keyPath: path] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
            Group {
                if ShotMode.active {
                    Text(binding.wrappedValue).frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(minHeight: CGFloat(lines) * 16, alignment: .topLeading)
                } else if lines > 1 {
                    TextField(label, text: binding, axis: .vertical).lineLimit(lines ... 8).textFieldStyle(.plain)
                } else {
                    TextField(label, text: binding).textFieldStyle(.plain)
                }
            }
            .font(Theme.ui(12.5))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        }
    }
}

// MARK: On the goal's page

/// The goal's swarm on its overview: the active run (state, plan, questions waiting) and the past ones.
struct GoalSwarmPanel: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let runs = model.goals.snapshot.swarms(of: goal.id)
        let active = runs.first { $0.status.active }
        let board = model.goals.board.flatMap { $0.swarm.goal == goal.id ? $0 : nil }
        Panel(title: "Swarm", note: active.map { "swarm \($0.number)" } ?? (runs.isEmpty ? "" : "\(runs.count) past")) {
            if let active {
                HStack(spacing: 8) {
                    Text(active.stateLine).font(Theme.ui(13, weight: .medium))
                    Spacer(minLength: 6)
                    KeyHint("goal.swarm", scope: "goals", label: "plan", color: Theme.fg2)
                }
                if let board, board.swarm.id == active.id, let schedule = model.swarmSchedule(board),
                   active.status != .planning
                {
                    let progress = SwarmProgress(
                        swarm: board.swarm,
                        tasks: model.runTasks(board),
                        states: schedule.states
                    )
                    HStack(spacing: 14) {
                        Text("progress \(progress.done) of \(progress.total)").font(Theme.ui(12))
                            .foregroundStyle(Theme.fg2)
                        Text("agents \(progress.agentsLine)").font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    }
                    if active.status == .landing {
                        let rows = model.landingRows(board)
                        let held = rows.filter { $0.state == .held }
                        Text(
                            "landing: \(rows.count { $0.state == .merged }) of \(rows.count) merged in merge order"
                                + (held.isEmpty ? "" : " · " + held.compactMap { $0.pr.map { "#\($0)" } }
                                    .joined(separator: " ") + " held")
                        )
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        .clickRuns(CommandInvocation(name: "swarm.order"))
                    }
                    if let limit = active.held {
                        Text("paused at \(limit.text(active.settings.limits)): Needs you asks")
                            .font(Theme.ui(12)).foregroundStyle(Theme.block)
                            .clickRuns(CommandInvocation(name: "goal.swarm"))
                    }
                } else if let board, board.swarm.id == active.id {
                    let tasks = board.tasks
                    let minutes = SwarmPlan.estimate(tasks)
                    Text(
                        tasks.isEmpty ? "the lead is drafting the plan"
                            : "\(tasks.count) tasks in \(SwarmPlan.phases(tasks).count) phases"
                            + (minutes > 0 ? " · est \(SwarmEstimate.text(minutes))" : "")
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    let open = board.openQuestions.count
                    if open > 0 || board.pending != nil {
                        Text(
                            [
                                open > 0 ? "the lead asks \(open) thing\(open == 1 ? "" : "s")" : nil,
                                board.pending != nil ? "a plan change waits" : nil,
                            ].compactMap(\.self)
                                .joined(separator: " · ")
                        )
                        .font(Theme.ui(12)).foregroundStyle(Theme.block)
                        .clickRuns(CommandInvocation(name: "goal.swarm"))
                    }
                }
                Text("lead \(active.settings.lead.label) · \(active.settings.limits.line)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            } else {
                if let last = runs.first, last.status == .done {
                    Text("Swarm \(last.number) landed: every task merged, in merge order. The goal stays open until "
                        + "its own done rule holds.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.done).fixedSize(horizontal: false, vertical: true)
                } else {
                    Quiet("No swarm going. A swarm plans the goal's work with a lead agent and runs it in parallel.")
                }
                KeyHint("swarm.start", label: runs.isEmpty ? "swarm this goal" : "a follow-up swarm", color: Theme.fg2)
            }
            ForEach(runs.filter { !$0.status.active }) { run in
                HStack(spacing: 8) {
                    Text("swarm \(run.number)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    Text(run.status == .done ? "done · landed in merge order" : run.stateLine).font(Theme.ui(12))
                        .foregroundStyle(run.status == .done ? Theme.done : Theme.fg2).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Clock.relative(run.endedAt ?? run.startedAt)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
    }
}

// MARK: New swarm

/// The new swarm form: the goal, where it works, the lead and team, how much say you want, the limits. ⌘↩ starts the
/// lead on a plan; ⎋ leaves.
struct SwarmFormView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let form = model.goals.swarmForm ?? SwarmForm()
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(form.goal == nil ? "New swarm" : "Swarm this goal").font(Theme.ui(16, weight: .semibold))
                    Text("Describe it. The lead plans it. You read the plan: nothing runs before you approve it.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                SectionHeader(title: "Goal")
                if form.goal == nil {
                    textField("What the goal is called", \.title, font: Theme.ui(14))
                    textField("What done looks like", \.statement, lines: 3)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(form.title).font(Theme.ui(14, weight: .medium))
                        if !form.statement.isEmpty {
                            Text(form.statement).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(3)
                        }
                    }
                }
                SectionHeader(title: "Where")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(model.swarmRepoChoices.prefix(10), id: \.self) { slug in
                        let picked = form.repos.contains(slug)
                        Text((picked ? "" : "+ ") + slug).font(Theme.mono(11))
                            .foregroundStyle(picked ? Theme.fg : Theme.fg3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.chip : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                            .clickable()
                            .onTapGesture { toggleRepo(slug) }
                    }
                    if model.swarmRepoChoices.isEmpty {
                        Text("no repos on this Mac yet: Repos (gr) adds them").font(Theme.ui(12))
                            .foregroundStyle(Theme.fg3)
                    }
                }
                SectionHeader(title: "Team")
                HStack(spacing: 8) {
                    Text("lead").font(Theme.ui(12)).foregroundStyle(Theme.fg3).frame(width: 52, alignment: .leading)
                    agentChip(form.lead.agent) { next in model.goals.swarmForm?.lead.agent = next }
                    modelField(
                        get: { model.goals.swarmForm?.lead.model ?? "" },
                        set: { model.goals.swarmForm?.lead.model = $0.isEmpty ? nil : $0 }
                    )
                }
                ForEach(Array(form.workers.enumerated()), id: \.offset) { index, worker in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "workers" : "").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                            .frame(width: 52, alignment: .leading)
                        agentChip(worker.agent) { next in model.goals.swarmForm?.workers[index].agent = next }
                        modelField(
                            get: { model.goals.swarmForm?.workers[index].model ?? "" },
                            set: { model.goals.swarmForm?.workers[index].model = $0.isEmpty ? nil : $0 }
                        )
                        Stepper(text: "×\(worker.count)") { delta in
                            guard let count = model.goals.swarmForm?.workers[index].count else { return }
                            model.goals.swarmForm?.workers[index].count = min(max(count + delta, 1), 9)
                        }
                        Text("remove").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).clickable()
                            .onTapGesture { model.goals.swarmForm?.workers.remove(at: index) }
                    }
                }
                Text("+ add workers").font(Theme.ui(12)).foregroundStyle(Theme.fg2).clickable()
                    .onTapGesture {
                        model.goals.swarmForm?.workers
                            .append(SwarmSettings.Worker(agent: model.swarmAgents.first ?? "claude"))
                    }
                SectionHeader(title: "How much say you want")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SwarmSettings.Autonomy.allCases, id: \.self) { autonomy in
                        HStack(spacing: 8) {
                            Circle().fill(form.autonomy == autonomy ? Theme.block : Theme.line).frame(
                                width: 8,
                                height: 8
                            )
                            Text(autonomy.title).font(Theme.ui(12.5))
                                .foregroundStyle(form.autonomy == autonomy ? Theme.fg : Theme.fg2)
                        }
                        .clickable()
                        .onTapGesture { model.goals.swarmForm?.autonomy = autonomy }
                    }
                }
                SectionHeader(title: "Limits")
                HStack(spacing: 16) {
                    Stepper(text: "max \(form.limits.agents) agents") { delta in
                        guard let value = model.goals.swarmForm?.limits.agents else { return }
                        model.goals.swarmForm?.limits.agents = min(max(value + delta, 1), 20)
                    }
                    Stepper(text: "\(String(format: "%g", form.limits.hours)) h") { delta in
                        guard let value = model.goals.swarmForm?.limits.hours else { return }
                        model.goals.swarmForm?.limits.hours = min(max(value + Double(delta), 1), 48)
                    }
                    Stepper(text: "$\(String(format: "%g", form.limits.dollars))") { delta in
                        guard let value = model.goals.swarmForm?.limits.dollars else { return }
                        model.goals.swarmForm?.limits.dollars = min(max(value + Double(delta) * 10, 10), 1000)
                    }
                }
                Text("Reaching a limit pauses new work and asks you. The lead never changes the goal or the limits.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Spacer()
                    KeyHint(keys: "<Esc>", label: "cancel")
                    KeyHint(keys: "<D-CR>", label: "ask the lead for a plan", color: Theme.fg)
                }
            }
            .padding(22)
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shotRegion(.swarmForm)
        }
    }

    private func toggleRepo(_ slug: String) {
        guard var form = model.goals.swarmForm else { return }
        if let index = form.repos.firstIndex(of: slug) { form.repos.remove(at: index) } else { form.repos.append(slug) }
        model.goals.swarmForm = form
    }

    /// An agent; a click picks the next one.
    private func agentChip(_ agent: String, set: @escaping (String) -> Void) -> some View {
        Text(agent + " ▾").font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
            .clickable()
            .onTapGesture {
                let agents = model.swarmAgents
                guard !agents.isEmpty else { return }
                let index = agents.firstIndex(of: agent) ?? -1
                set(agents[(index + 1) % agents.count])
            }
            .help("Click for the next agent")
    }

    private func modelField(get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        Group {
            if ShotMode.active {
                Text(get().isEmpty ? "default model" : get()).foregroundStyle(get().isEmpty ? Theme.fg3 : Theme.fg)
                    .frame(width: 130, alignment: .leading)
            } else {
                TextField("default model", text: Binding(get: get, set: set)).textFieldStyle(.plain).frame(width: 130)
            }
        }
        .font(Theme.mono(11.5))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }

    private func textField(
        _ placeholder: String, _ path: WritableKeyPath<SwarmForm, String>, lines: Int = 1, font: Font = Theme.ui(13)
    ) -> some View {
        let binding = Binding(
            get: { model.goals.swarmForm?[keyPath: path] ?? "" },
            set: { model.goals.swarmForm?[keyPath: path] = $0 }
        )
        return Group {
            if ShotMode.active {
                Text(binding.wrappedValue.isEmpty ? placeholder : binding.wrappedValue)
                    .foregroundStyle(binding.wrappedValue.isEmpty ? Theme.fg3 : Theme.fg)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(lines) * 17, alignment: .topLeading)
            } else if lines > 1 {
                TextField(placeholder, text: binding, axis: .vertical).lineLimit(lines ... 6).textFieldStyle(.plain)
            } else {
                TextField(placeholder, text: binding).textFieldStyle(.plain)
            }
        }
        .font(font)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

/// `− value +`: clicks step the value.
private struct Stepper: View {
    let text: String
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("−").font(Theme.mono(12)).foregroundStyle(Theme.fg2).clickable().onTapGesture { step(-1) }
            Text(text).font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
            Text("+").font(Theme.mono(12)).foregroundStyle(Theme.fg2).clickable().onTapGesture { step(1) }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
    }
}

// MARK: Landing

/// A task's place in the merge order under its title: `2/4 · after #412`, why it is held, the base its PR goes against
/// when it stacks.
private struct LandingLine: View {
    let row: SwarmLanding.Row

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label).font(Theme.mono(10.5)).foregroundStyle(row.slot.isolated ? Theme.fg3 : Theme.fg2)
                .help(row.slot.isolated ? "Nothing waits for it and it waits for nothing: it merges in any order"
                    : "Its place in the merge order: what it waits for merges first")
            if row.state == .held {
                Text("held").font(Theme.mono(10.5)).foregroundStyle(Theme.block)
                    .padding(.horizontal, 5).padding(.vertical, 0.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.block.opacity(0.6)))
                    .help(row.hold ?? "")
            }
            if row.state != .merged, let base = row.base, row.stackedOn != nil {
                Text("→ \(base)").font(Theme.mono(10.5)).foregroundStyle(Theme.ask).lineLimit(1)
                    .truncationMode(.middle)
                    .help("Its PR goes against \(base): it moves to where that PR merges once it merged")
            }
        }
    }
}

/// The run's merge order: every task in turn with its PR, what it waits for (only real constraints: `any order` when
/// nothing does), and why a PR is held. heed holds a PR while what it waits for is unmerged; merging itself follows
/// each PR's get it merged setting.
private struct MergeOrder: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let rows = model.landingRows(board)
        let merged = rows.count { $0.state == .merged }
        Panel(title: "Merge order", note: "\(merged) of \(rows.count) merged") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(row.slot.position)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                            .frame(width: 14, alignment: .trailing)
                        Text(row.pr.map { "#\($0)" } ?? row.number).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineLimit(1)
                            Text(detail(row)).font(Theme.ui(11.5))
                                .foregroundStyle(row.state == .held ? Theme.block : Theme.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Text(row.state.rawValue).font(Theme.mono(10.5)).foregroundStyle(color(row.state))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickPlanTaskID(row.id) }
                }
            }
            Text(
                "A PR merges after what its task waits for; one stacked on another moves to where that one merged. "
                    + "Each PR merges by its own get it merged setting: heed never merges to main on its own."
            )
            .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint(
                    "swarm.order",
                    scope: "goalplan",
                    label: model.goals.byMergeOrder ? "by phase" : "outline in this order"
                )
                if board.swarm.status.active {
                    KeyHint("swarm.land", scope: "goalplan", label: "move a stacked PR on")
                }
                KeyHint("merge.queue", key: "gM", label: "merge queue")
            }
        }
    }

    private func detail(_ row: SwarmLanding.Row) -> String {
        if let hold = row.hold, row.state == .held { return "held: \(hold)" }
        let constraint = row.slot.isolated ? "any order"
            : row.slot.after.isEmpty ? "waits for nothing · \(row.slot.before.count) wait\(row.slot.before.count == 1 ? "s" : "") for it"
            : String(row.label.split(separator: "·", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
        switch row.state {
        case .noPR: return constraint + " · no PR yet"
        case .merged: return constraint + " · merged"
        case .closed: return constraint + " · closed without merging"
        case .open, .held:
            return constraint + (row.stackedOn != nil ? " · stacked, against \(row.base ?? "its parent")" : "")
                + " · may merge"
        }
    }

    private func color(_ state: SwarmLanding.Row.State) -> Color {
        switch state {
        case .noPR: Theme.fg3
        case .open: Theme.ask
        case .held: Theme.block
        case .merged: Theme.done
        case .closed: Theme.err
        }
    }
}
