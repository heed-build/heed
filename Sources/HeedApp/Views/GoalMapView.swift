import HeedCore
import SwiftUI

/// The swarm as a map (`goal.map`, `T`; deck p09): the goal and its lead on the left, the plan's phases as columns,
/// each task a card coloured by its state, and an edge for every "after". On the right the swarm's numbers, what
/// changed since you last looked, what needs you and the keys. h l move between columns, j k between cards.
struct GoalMapPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let goals = model.goals
        if let board = goals.board, board.swarm.goal == goal.id, let layout = model.mapLayout() {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Swarm \(board.swarm.number) › \(goal.title)").font(Theme.ui(15, weight: .semibold))
                            .lineLimit(1)
                        Text(board.swarm.stateLine).font(Theme.mono(10.5)).foregroundStyle(Theme.block)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.block.opacity(0.6)))
                        Spacer(minLength: 12)
                        MapLegend()
                    }
                    // The whole plan in view: drawn to fit, at the top, up to half again its size for a small plan.
                    GeometryReader { geometry in
                        let width = layout.width + 48
                        let height = layout.height + 48
                        let scale = min(1.5, geometry.size.width / width, geometry.size.height / height)
                        SwarmGraph(layout: layout, cursor: goals.mapCursor)
                            .padding(24)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: width * scale, height: height * scale, alignment: .topLeading)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    .shotRegion(.swarmMap)
                }
                ListScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        MapFacts(board: board)
                        SinceYouLooked(board: board)
                        NeedsYouQueue(board: board, scope: "goalmap", limit: 1)
                        MapKeys()
                    }
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(20)
        } else {
            EmptyState(
                title: "No plan to map",
                detail: "The map draws a swarm's plan: the goal on the left, its phases as columns, its tasks as cards "
                    + "by state, what waits for what as edges.",
                actions: [EmptyState.Action("The plan", "goal.swarm")]
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The graph itself: phase names over their columns, the edges, the cards.
private struct SwarmGraph: View {
    @Environment(AppModel.self) private var model
    let layout: SwarmMap.Layout
    let cursor: String?

    var body: some View {
        let metrics = SwarmMap.Metrics()
        let edges = layout.edges.map { edge in
            GraphEdge(
                from: CGPoint(x: edge.start.x, y: edge.start.y), to: CGPoint(x: edge.end.x, y: edge.end.y),
                color: edge.settled ? Theme.done.opacity(0.45) : Theme.fg3.opacity(0.7), dashed: edge.from == "lead"
            )
        }
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.columns.enumerated()), id: \.offset) { index, name in
                Text("\(index + 1) · \(name)".uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.fg3)
                    .frame(width: metrics.cardWidth, alignment: .center)
                    .offset(x: Double(index + 1) * (metrics.cardWidth + metrics.columnGap), y: 0)
            }
            GraphCanvas(
                size: CGSize(width: layout.width, height: layout.height), edges: edges, nodes: layout.nodes,
                frame: { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) },
                card: { node in
                    MapCard(node: node, isCursor: node.id == cursor)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickMapCard(node.id) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.clickMapCard(node.id)
                            model.perform(CommandInvocation(name: node.id == "lead" ? "goal.swarm" : "swarm.task.open"))
                        })
                        .rightClickMenu {
                            guard model.clicksReachLists, node.id != "lead" else { return false }
                            model.clickMapCard(node.id)
                            return true
                        } _: {
                            model.goals.planTasks.first { $0.id == node.id }.map(model.agentMenu) ?? []
                        }
                }
            )
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    }
}

private struct MapCard: View {
    let node: SwarmMap.Node
    let isCursor: Bool

    var body: some View {
        let color = Self.color(node.state)
        let lead = node.id == "lead"
        HStack(spacing: 8) {
            (lead ? Theme.block : color).frame(width: 3).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                if lead {
                    Text("GOAL · LEAD").font(Theme.mono(9)).foregroundStyle(Theme.block)
                }
                Text((node.number.isEmpty ? "" : node.number + " ") + node.title)
                    .font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(lead ? 2 : 1)
                if !lead {
                    Text(node.detail).font(Theme.mono(9.5)).foregroundStyle(color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCursor ? Theme.bg3 : Theme.bg))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isCursor ? Theme.fg2 : (lead ? Theme.block : color).opacity(0.55),
                    lineWidth: isCursor ? 1.5 : 1
                )
        )
    }

    static func color(_ state: SwarmMap.State) -> Color {
        switch state {
        case .done: Theme.done
        case .working: Theme.busy
        case .asking: Theme.ask
        case .blocked, .stuck: Theme.block
        case .waiting: Theme.fg3
        }
    }
}

private struct MapLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(SwarmMap.State.allCases, id: \.self) { state in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(MapCard.color(state)).frame(width: 8, height: 8)
                    Text(state.word).font(Theme.ui(11)).foregroundStyle(Theme.fg3).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// The swarm's numbers beside the map: agents, progress, time, money.
private struct MapFacts: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard

    var body: some View {
        let swarm = board.swarm
        let tasks = model.runTasks(board)
        let schedule = model.swarmSchedule(board)
        let progress = schedule.map { SwarmProgress(swarm: swarm, tasks: tasks, states: $0.states) }
        let usage = model.swarmUsage(swarm)
        let rollup = model.swarmRollup(swarm)
        Panel(title: "Swarm", note: "swarm \(swarm.number)") {
            VStack(alignment: .leading, spacing: 6) {
                fact("Agents", progress?.agentsLine ?? "–")
                fact("Progress", progress.map { "\($0.done) / \($0.total) tasks" } ?? "–")
                fact("Elapsed", SwarmEstimate.text(max(Int(usage.elapsed / 60), 0)))
                fact("Spent", AgentUsage.dollars(rollup.dollars) + (rollup.tokens > 0
                        ? " · " + SwarmUsageRollup.tokens(rollup.tokens) : ""))
                fact("Lead", swarm.settings.lead.label)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            Spacer()
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.fg).lineLimit(1)
        }
    }
}

private struct MapKeys: View {
    var body: some View {
        Panel(title: "Drill", note: "") {
            VStack(alignment: .leading, spacing: 6) {
                KeyHint("swarm.map.move", ["l"], key: "h l", scope: "goalmap", label: "between columns")
                KeyHint("swarm.map.move", ["j"], key: "j k", scope: "goalmap", label: "between cards")
                KeyHint("swarm.task.open", scope: "goalmap", label: "its worker's tab")
                KeyHint("swarm.task.pause", scope: "goalmap", label: "pause the task")
                KeyHint("swarm.task.edit", scope: "goalmap", label: "edit it in the plan")
                KeyHint("goal.agents", scope: "goalmap", label: "the agents")
            }
        }
    }
}
