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
                        if goals.focus == .steering {
                            // The log has the keyboard: the whole history, by who decided.
                            SteeringLog(board: board, full: true).shotRegion(.swarmSteering)
                        } else {
                            if board.swarm.held != nil { LimitAsk(swarm: board.swarm).shotRegion(.swarmLimit) }
                            // The task under the cursor's agent-to-agent log, first: it is about where you are.
                            if goals.focus == .tasks, let task = goals.selectedTask,
                               !SwarmMessages.log(of: task.id, board.steering).isEmpty
                            {
                                AgentLog(board: board, task: task).shotRegion(.swarmAgentLog)
                            }
                            if board.swarm.approved != nil, board.swarm.status != .planning {
                                MergeOrder(board: board).shotRegion(.swarmOrder)
                            }
                            SwarmQuestions(board: board).shotRegion(.swarmQuestions)
                            if let pending = board.pending { PendingChange(board: board, pending: pending) }
                            RepeatRules(board: board).shotRegion(.swarmRules)
                            PlanVersions(board: board).shotRegion(.swarmVersions)
                            SteeringLog(board: board, full: false).shotRegion(.swarmSteering)
                        }
                    }
                }
                .frame(width: goals.focus == .steering ? 460 : 360)
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
                Text(
                    "Get it merged: " + swarm.settings.merge.line(repo: model.swarmRepoMerge(swarm))
                        .replacingOccurrences(of: "merge ", with: "", options: .anchored)
                        + " · in merge order, a stacked PR after its parent"
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
        // Where it runs: its live worker's place, else where its next one would start. Marked when that is a host,
        // and as local when the swarm runs on one.
        let place = model.liveWorker(on: task.id)?.location ?? SwarmPlace.location(of: task, swarm: swarm.settings)
        let marked = !place.isLocal || swarm.settings.host != nil
        return TaskRow(
            task: task, number: numbers[task.id] ?? "", numbers: numbers,
            isCursor: row == goals.taskCursor, focused: goals.focus == .tasks,
            status: schedule?.states[task.id], worker: swarm.lastWorker(on: task.id), landing: landing,
            place: marked ? place : nil, placeColor: place.hostName.flatMap { model.config.hosts[$0]?.color }
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
    /// Where it runs, when that is worth a chip (a host; this Mac in a swarm on a host).
    var place: Location?
    var placeColor: String?

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
            if let place { HostChip(location: place, color: placeColor).fixedSize() }
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
        let tokens = model.swarmRollup(swarm).tokens
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
                tokens > 0 ? SwarmUsageRollup.tokens(tokens) : nil,
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
private struct SwarmQuestions: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let open = board.openQuestions.count
        let questions = board.questions
        let first = board.openQuestions.first?.id
        Panel(
            title: open == 0 ? "Questions" : "\(open) question\(open == 1 ? "" : "s") open",
            note: questions.isEmpty ? "" : "\(questions.count - open) answered"
        ) {
            if questions.isEmpty {
                Quiet(
                    "None yet. What the lead or a worker cannot decide from the goal and the code, it asks: who may "
                        + "answer is by what it is about, and what is yours waits in Needs you."
                )
            }
            ForEach(Array(questions.enumerated()), id: \.element.id) { _, question in
                SwarmQuestionView(board: board, question: question, keyed: question.id == first)
            }
            if open > 0, board.swarm.status.active {
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    if let first = board.openQuestions.first, !first.row.options.isEmpty {
                        KeyHint(
                            "swarm.answer.option", ["1"], key: first.row.options.count == 1 ? "1"
                                : "1…\(min(first.row.options.count, 9))",
                            scope: "goalplan", label: "pick"
                        )
                    }
                    KeyHint("swarm.answer", scope: "goalplan", label: "type an answer")
                    KeyHint("swarm.controller", scope: "goalplan", label: "ask the controller")
                }
            }
        }
    }
}

/// One question: who asked, what it is about, its options with what each would change, and its answer with who gave
/// it (an overruled answer struck through), or whom it waits for and the controller's suggestion.
struct SwarmQuestionView: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let question: SwarmSteering.Question
    /// Its options carry the digit that picks them.
    var keyed = false
    var large = false

    var body: some View {
        let numbers = SwarmPlan.numbers(board.tasks)
        let row = question.row
        let view = SwarmAnswerView(question, rows: board.steering, numbers: numbers)
        let asker = row.from.flatMap(SwarmAddress.init(raw:))?
            .label(numbers) ?? (row.actor == .lead ? "the lead" : "an agent")
        let category = row.category.flatMap(SwarmAuthority.Category.init(rawValue:))
        let overruled = SwarmSteering.overruled(board.steering)
        let previous = board.steering.filter { answer in
            answer.about == question.id && (answer.kind == .answer || answer.kind == .overrule)
                && answer.id != question.answer?.id && answer.id.map { overruled.contains($0) } == true
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(asker).font(Theme.mono(10.5)).foregroundStyle(Theme.ask)
                if let category { Text(category.title).font(Theme.ui(11)).foregroundStyle(Theme.fg3).lineLimit(1) }
                Spacer(minLength: 4)
                Text(Clock.relative(row.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
            Text(row.text).font(Theme.ui(large ? 14 : 12.5))
                .foregroundStyle(question.answer == nil ? Theme.fg : Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if let answer = question.answer {
                ForEach(previous, id: \.id) { old in
                    Text("\(old.text) · \(by(old, numbers))").font(Theme.ui(12)).strikethrough()
                        .foregroundStyle(Theme.fg3)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("→ \(answer.text)").font(Theme.ui(12)).foregroundStyle(Theme.done)
                    Text(answer.kind == .overrule ? "you, overruling" : view.by ?? "")
                        .font(Theme.mono(10.5)).foregroundStyle(answer.actor == .controller ? Theme.ask : Theme.fg3)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if !row.options.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(row.options.enumerated()), id: \.offset) { number, option in
                            let effect = row.effects.flatMap { $0.indices.contains(number) ? $0[number] : nil } ?? ""
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(keyed && number < 9 ? "\(number + 1)" : "·").font(Theme.mono(11))
                                    .foregroundStyle(Theme.fg2).frame(minWidth: 12)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                                    if !effect.isEmpty {
                                        Text(effect).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .clickable()
                            .onTapGesture { model.answerSwarm([option], question: question.id) }
                            .help("Answer: \(option)")
                        }
                    }
                }
                if let suggestion = SwarmSteering.suggestion(question, rows: board.steering) {
                    Text("The controller suggests \(suggestion.text)" + (suggestion.reason.map { " (\($0))" } ?? ""))
                        .font(Theme.ui(12)).foregroundStyle(Theme.ask)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("waits for \(view.waitsFor ?? "an answer")").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
    }

    private func by(_ row: SwarmSteer, _ numbers: [String: String]) -> String {
        switch row.actor {
        case .controller: "the controller, overruled"
        case .you: "you, overruled"
        default: (row.from.flatMap(SwarmAddress.init(raw:))?.label(numbers) ?? row.actor.rawValue) + ", overruled"
        }
    }
}

/// One task's agent-to-agent log (deck p10): what was said to it and by it, its questions and their answers, its
/// progress notes.
private struct AgentLog: View {
    let board: SwarmBoard
    let task: SwarmTask

    var body: some View {
        let numbers = SwarmPlan.numbers(board.tasks)
        let rows = SwarmMessages.log(of: task.id, board.steering)
        Panel(title: "Agent to agent · \(numbers[task.id] ?? "") \(task.title)", note: "\(rows.count)") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.suffix(12).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Ages.short(row.at)).font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                            .frame(width: 30, alignment: .leading)
                        Text(route(row, numbers)).font(Theme.mono(10.5)).foregroundStyle(color(row))
                            .frame(width: 112, alignment: .leading).lineLimit(2)
                        Text(text(row)).font(Theme.ui(12)).foregroundStyle(row.kind == .question ? Theme.ask : Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            KeyHint("swarm.send", [SwarmPlan.short(task.id)], scope: "goalplan", label: "message it")
        }
    }

    private func name(_ raw: String?, _ numbers: [String: String]) -> String {
        guard let address = raw.flatMap(SwarmAddress.init(raw:)) else { return "?" }
        if case let .task(id) = address { return numbers[id] ?? SwarmPlan.short(id) }
        return address == .all ? "@all" : address.label(numbers).replacingOccurrences(of: "the ", with: "")
    }

    private func route(_ row: SwarmSteer, _ numbers: [String: String]) -> String {
        let from = name(
            row.from ?? (row.actor == .controller ? "controller" : row.actor == .you ? "you" : nil),
            numbers
        )
        switch row.kind {
        case .note: return "\(from) · note"
        case .escalate: return "heed"
        case .question: return row.to.map { "\(from) → \(name($0, numbers))" } ?? "\(from) asks"
        case .answer, .overrule, .suggest:
            let asker = board.steering.first { $0.id == row.about }?.from
            return "\(from) → \(name(asker, numbers))"
        default: return row.to.map { "\(from) → \(name($0, numbers))" } ?? from
        }
    }

    private func text(_ row: SwarmSteer) -> String {
        switch row.kind {
        case .question: "? \(row.text)"
        case .overrule: "\(row.text)" + (row.reason.map { " (\($0))" } ?? "")
        case .suggest: "suggests \(row.text)"
        case .escalate: "a question went \(row.text)" + (row.reason.map { ": \($0)" } ?? "")
        default: row.text
        }
    }

    private func color(_ row: SwarmSteer) -> Color {
        switch row.actor {
        case .you: Theme.fg
        case .lead: Theme.block
        case .controller: Theme.ask
        case .agent: Theme.busy
        case .heed: Theme.fg3
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
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    /// The whole history, the keyboard on it; else its newest rows under the rest.
    let full: Bool

    var body: some View {
        let goals = model.goals
        let rows = goals.shownSteering
        let overruled = SwarmSteering.overruled(board.steering)
        let shown = full ? rows : Array(rows.prefix(8))
        let who = goals.logActor.map { AppModel.actorTitle($0) } ?? "everyone"
        Panel(title: "Steering log", note: "\(who) · \(rows.count)") {
            if full {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach([nil] + SwarmSteer.Actor.allCases, id: \.self) { actor in
                        let on = goals.logActor == actor
                        Text(actor.map { AppModel.actorTitle($0) } ?? "everyone").font(Theme.ui(11.5))
                            .foregroundStyle(on ? Theme.fg : Theme.fg3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.selected : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                            .clickRuns(CommandInvocation(name: "swarm.log.who", arguments: [actor?.rawValue ?? "all"]))
                    }
                }
            }
            if rows.isEmpty { Quiet("Nothing yet from \(who).") }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                    let isCursor = full && index == goals.steeringCursor && goals.focus == .steering
                    let state = SwarmSteering.state(row, overruled: overruled)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(actorLabel(row)).font(Theme.mono(10)).foregroundStyle(actorColor(row.actor))
                            .frame(width: 62, alignment: .leading)
                        Text(SwarmSteering.line(row)).font(Theme.ui(12))
                            .strikethrough(state == .overruled && row.kind != .overrule)
                            .foregroundStyle(state == .overruled && row.kind != .overrule ? Theme.fg3 : Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if state == .overruled {
                            Text(row.kind == .overrule ? "overrules" : "overruled").font(Theme.mono(10))
                                .foregroundStyle(Theme.block)
                        } else if row.actor == .controller, row.kind == .answer {
                            Text("by controller").font(Theme.mono(10)).foregroundStyle(Theme.ask)
                        }
                        Text(Clock.relative(row.at)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .background(isCursor ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
                    .hint(full && goals.focus == .steering ? model.hintLabel(for: .row(.goals, index)) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clickSteer(index) }
                    .rightClickMenu {
                        guard model.clicksReachLists else { return false }
                        model.clickSteer(index)
                        return true
                    } _: { model.steeringMenu(index) }
                }
                if !full, rows.count > shown.count {
                    Text("\(rows.count - shown.count) older").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                }
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint("swarm.log.who", scope: "goalplan", label: "who")
                if full {
                    KeyHint("swarm.log.jump", scope: "goalplan", label: "question ⇄ answer")
                    if let row = goals.selectedSteer, let question = question(of: row), question.answer != nil,
                       question.answer?.actor != .you, board.swarm.status.active
                    {
                        KeyHint(
                            "swarm.answer.option", ["1"],
                            key: question.row.options.isEmpty ? nil : "1…\(min(question.row.options.count, 9))",
                            scope: "goalplan", label: "overrule", color: Theme.fg
                        )
                    }
                } else {
                    KeyHint("goal.focus", scope: "goalplan", label: "the whole log")
                }
            }
        }
    }

    /// The actor, and for an agent which: `agent 2.1`, `agent` for a session on the goal.
    private func actorLabel(_ row: SwarmSteer) -> String {
        guard row.actor == .agent, case let .task(id)? = row.from.flatMap(SwarmAddress.init(raw:)) else {
            return row.actor.rawValue
        }
        return "agent " + (SwarmPlan.numbers(board.tasks)[id] ?? SwarmPlan.short(id))
    }

    private func question(of row: SwarmSteer) -> SwarmSteering.Question? {
        let id = row.kind == .question ? row.id : row.about
        return id.flatMap { id in board.questions.first { $0.id == id } }
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
        let notes = model.planDraftNotes(draft)
        Panel(title: title, note: "") {
            if draft.isTask {
                field("Title", \.fields.title, note: "title", notes)
                HStack(alignment: .top, spacing: 8) {
                    field("Phase", \.fields.phase)
                    field("Host (empty: the swarm's)", \.fields.host, note: "host", notes)
                    field("Estimate", \.fields.estimate, note: "estimate", notes).frame(width: 80)
                }
                owner
                FieldNoteView(note: notes.note(for: "owner", tried: draft.tried))
                field("After (1.2, 2.1)", \.fields.after, note: "after", notes)
                field("Done when (one per line)", \.fields.doneWhen, lines: 3)
            } else {
                if case let .answer(id) = draft.kind,
                   let question = model.goals.board?.questions.first(where: { $0.id == id })
                {
                    Text(question.row.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field(placeholder, \.text, lines: 3, note: "text", notes)
            }
            HStack(spacing: 18) {
                Spacer()
                KeyHint(keys: "<Esc>", label: "cancel")
                ConfirmHint(keys: "<D-CR>", label: "save", blocking: notes.blocking)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.6)))
    }

    /// The owner: an agent from a menu (or none), then its model and effort, picked like the swarm form's.
    private var owner: some View {
        let fields = draft.fields
        let agentText = fields.agent.isEmpty ? "no owner" : fields.agent
        let label = Text(agentText + " ▾").font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Owner").font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
            HStack(spacing: 6) {
                if ShotMode.active {
                    label
                } else {
                    Menu {
                        Button("no owner") { setOwner(agent: "") }
                        ForEach(model.settings.agents.map(\.name), id: \.self) { name in
                            Button(name) { setOwner(agent: name) }
                        }
                    } label: { label }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if !fields.agent.isEmpty {
                    let catalog = model.modelCatalog(fields.agent)
                    ModelChips(
                        catalog: catalog, model: fields.model.isEmpty ? nil : fields.model,
                        effort: fields.effort.isEmpty ? nil : fields.effort,
                        setModel: { next in
                            let effort = model.goals.planDraft?.fields.effort ?? ""
                            model.goals.planDraft?.fields.model = next ?? ""
                            model.goals.planDraft?.fields.effort = ModelPicker.effort(
                                effort.isEmpty ? nil : effort, after: next, in: catalog
                            ) ?? ""
                        },
                        setEffort: { model.goals.planDraft?.fields.effort = $0 ?? "" }
                    )
                }
            }
        }
    }

    /// Another agent: its own default model and effort.
    private func setOwner(agent: String) {
        guard model.goals.planDraft?.fields.agent != agent else { return }
        model.goals.planDraft?.fields.agent = agent
        model.goals.planDraft?.fields.model = ""
        model.goals.planDraft?.fields.effort = ""
    }

    private var title: String {
        switch draft.kind {
        case .edit: "Edit the task"
        case .add: "Add a task"
        case .replan: "Re-plan: what should change"
        case .answer: "Answer the question"
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

    /// A field, with its note under it (`note`: the field's name in `notes`).
    @ViewBuilder
    private func field(
        _ label: String, _ path: WritableKeyPath<PlanDraft, String>, lines: Int = 1, note: String? = nil,
        _ notes: [FieldNote] = []
    ) -> some View {
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
            if let note { FieldNoteView(note: notes.note(for: note, tried: draft.tried)) }
        }
    }
}

/// The goal's repeat rules ("same answer for similar questions"): the controller answers questions like these with
/// your answer. A right click or `:swarm.rule.delete <n>` deletes one.
private struct RepeatRules: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let rules = model.repeatRules(board)
        if !rules.isEmpty {
            Panel(title: "Repeat rules", note: "\(rules.count)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                            Text(rule.text).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(2)
                            Spacer(minLength: 6)
                            Text("→ \(rule.answer ?? "")").font(Theme.ui(12)).foregroundStyle(Theme.done).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .rightClickMenu { model.clicksReachLists } _: {
                            model.repeatRuleMenu(rule.id ?? 0, question: rule.text)
                        }
                    }
                    KeyHint("swarm.rule.delete", scope: "goalplan", label: "delete one")
                }
            }
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
                    if let summary = last.summary {
                        Text(summary.outcome).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !summary.followUps.isEmpty {
                            Text("follow-ups: " + summary.followUps.joined(separator: " · ")).font(Theme.ui(12))
                                .foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    KeyHint("goal.agents", scope: "goals", label: "its summary", color: Theme.fg2)
                } else {
                    Quiet("No swarm going. A swarm plans the goal's work with a lead agent and runs it in parallel.")
                }
                KeyHint(
                    runs.isEmpty ? "swarm.start" : "swarm.followup",
                    label: runs.isEmpty ? "swarm this goal" : "a follow-up swarm", color: Theme.fg2
                )
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
        let notes = model.swarmFormNotes(form)
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
                    FieldNoteView(note: notes.note(for: "title", tried: form.tried))
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
                let whereNote = notes.note(for: "where")
                if model.swarmPlaces.count > 1 {
                    let line = model.swarmPlaceLine(form.location)
                    HStack(spacing: 6) {
                        ForEach(model.swarmPlaces, id: \.self) { place in
                            placeChip(place, picked: place == form.location)
                        }
                    }
                    if whereNote == nil {
                        Text(line.text).font(Theme.ui(11.5)).foregroundStyle(line.problem ? Theme.block : Theme.fg3)
                    }
                }
                FieldNoteView(note: whereNote)
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
                        Text(form.host.map { "no repos found on @\($0) yet: type one below, or gH checks where "
                                + "they are"
                        } ?? "no repos on this Mac yet: type one below").font(Theme.ui(12))
                            .foregroundStyle(Theme.fg3)
                    }
                }
                repoEntryField(form)
                FieldNoteView(note: notes.note(for: RepoEntry.field, tried: form.tried))
                SectionHeader(title: "Team")
                HStack(spacing: 8) {
                    Text("lead").font(Theme.ui(12)).foregroundStyle(Theme.fg3).frame(width: 52, alignment: .leading)
                    agentChip(form.lead.agent) { next in model.goals.swarmForm?.lead = GoalItem.Owner(agent: next) }
                    let leadCatalog = model.modelCatalog(form.lead.agent)
                    ModelChips(
                        catalog: leadCatalog, model: form.lead.model, effort: form.lead.effort,
                        setModel: { next in
                            guard let lead = model.goals.swarmForm?.lead else { return }
                            model.goals.swarmForm?.lead = GoalItem.Owner(
                                agent: lead.agent, model: next,
                                effort: ModelPicker.effort(lead.effort, after: next, in: leadCatalog)
                            )
                        },
                        setEffort: { model.goals.swarmForm?.lead.effort = $0 }
                    )
                }
                ForEach(Array(form.workers.enumerated()), id: \.offset) { index, worker in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "workers" : "").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                            .frame(width: 52, alignment: .leading)
                        agentChip(worker.agent) { next in
                            guard let count = model.goals.swarmForm?.workers[index].count else { return }
                            model.goals.swarmForm?.workers[index] = SwarmSettings.Worker(agent: next, count: count)
                        }
                        let catalog = model.modelCatalog(worker.agent)
                        ModelChips(
                            catalog: catalog, model: worker.model, effort: worker.effort,
                            setModel: { next in
                                guard let worker = model.goals.swarmForm?.workers[index] else { return }
                                model.goals.swarmForm?.workers[index] = SwarmSettings.Worker(
                                    agent: worker.agent, model: next,
                                    effort: ModelPicker.effort(worker.effort, after: next, in: catalog),
                                    count: worker.count
                                )
                            },
                            setEffort: { model.goals.swarmForm?.workers[index].effort = $0 }
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
                SectionHeader(title: "Get it merged")
                HStack(spacing: 6) {
                    ForEach(SwarmSettings.Merge.allCases, id: \.self) { merge in
                        let picked = form.merge == merge
                        Text(merge == .repo ? "as the repo says" : merge.rawValue).font(Theme.mono(11))
                            .foregroundStyle(picked ? Theme.fg : Theme.fg3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.chip : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                            .clickable()
                            .onTapGesture { model.goals.swarmForm?.merge = merge }
                    }
                }
                Text("Its PRs merge in merge order either way; nothing reaches the default branch unless this or the "
                    + "repo turns get it merged on.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Spacer()
                    KeyHint(keys: "<Esc>", label: "cancel")
                    ConfirmHint(keys: "<D-CR>", label: "ask the lead for a plan", blocking: notes.blocking)
                }
            }
            .padding(22)
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shotRegion(.swarmForm)
        }
    }

    /// This Mac, or a host in its colour: a click runs the swarm there (`swarm.host`).
    private func placeChip(_ place: Location, picked: Bool) -> some View {
        let palette = place.hostName.map { HostPalette.color(for: $0, configured: model.config.hosts[$0]?.color) }
        return Text(place.hostName.map { "@\($0)" } ?? "this Mac").font(Theme.mono(11))
            .foregroundStyle(picked ? (palette?.foreground ?? Theme.fg) : Theme.fg3)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(picked ? (palette?.background ?? Theme.chip) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(picked ? (palette?.swatch.opacity(0.6) ?? Theme.line) : Theme.line))
            .clickable()
            .onTapGesture {
                model.perform(CommandInvocation(name: "swarm.host", arguments: [place.hostName ?? SwarmPlace.local]))
            }
            .help(place.hostName
                .map { "Run the lead and its workers on @\($0)" } ?? "Run the lead and its workers here")
    }

    private func toggleRepo(_ slug: String) {
        guard var form = model.goals.swarmForm else { return }
        if let index = form.repos.firstIndex(of: slug) { form.repos.remove(at: index) } else { form.repos.append(slug) }
        form.cloneNote = nil
        model.goals.swarmForm = form
    }

    /// Any repo, typed: `owner/name`, a GitHub URL or a path on this Mac, checked as you type; ↩ adds it.
    private func repoEntryField(_ form: SwarmForm) -> some View {
        Group {
            if ShotMode.active {
                Text(form.repoEntry.isEmpty ? Self.repoPlaceholder : form.repoEntry)
                    .foregroundStyle(form.repoEntry.isEmpty ? Theme.fg3 : Theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.repoPlaceholder, text: Binding(
                    get: { model.goals.swarmForm?.repoEntry ?? "" },
                    set: { model.setSwarmRepoEntry($0) }
                ))
                .textFieldStyle(.plain)
                .onSubmit { model.addSwarmRepoEntry() }
            }
        }
        .font(Theme.mono(12))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .help("Any repo: owner/name or a GitHub URL (checked on GitHub, cloned where the swarm runs), or a path to a "
            + "checkout on this Mac. ↩ adds it.")
    }

    private static let repoPlaceholder = "+ any repo: owner/name, a GitHub URL or a path · ↩ adds it"

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
                    + "Each PR merges by the get it merged in the header: heed never merges to main on its own."
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
