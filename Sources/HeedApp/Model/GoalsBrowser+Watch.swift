import Foundation
import HeedCore

/// The agents and map panes' state on `GoalsBrowser`: which worker the agents pane is on, which card the map is on.
extension GoalsBrowser {
    /// The tasks the agents pane lists: those a worker ran on, in plan order (the approved plan's).
    var agentTasks: [SwarmTask] {
        guard let board else { return [] }
        let worked = Set(board.swarm.workers.map(\.task))
        return planTasks.filter { worked.contains($0.id) }
    }

    var selectedAgentTask: SwarmTask? {
        let tasks = agentTasks
        return tasks.indices.contains(agentCursor) ? tasks[agentCursor] : tasks.first
    }

    func setAgentCursor(_ index: Int) {
        let count = agentTasks.count
        guard count > 0 else { return }
        agentCursor = min(max(index, 0), count - 1)
    }

    /// `goal.agents`: the swarm's agents, or back to the overview.
    func toggleAgents() {
        show(pane == .agents ? .overview : .agents)
        draft = nil
        if pane == .agents, !agentTasks.isEmpty { focus = .agents }
    }

    /// `goal.map`: the swarm as a graph, or back to the overview. The cursor starts on the goal.
    func toggleMap() {
        show(pane == .map ? .overview : .map)
        draft = nil
        if pane == .map, mapCursor == nil || !planTasks.contains(where: { $0.id == mapCursor }) { mapCursor = "lead" }
    }
}
