import Foundation

/// The swarm as a graph (deck p09): the goal and its lead on the left, the plan's phases as columns, each task a card
/// coloured by its state, and an edge for every "after". Pure and deterministic: the same plan lays out the same,
/// which the shots rely on.
public enum SwarmMap {
    /// A card's colour.
    public enum State: String, Hashable, Sendable, CaseIterable {
        case done, working, asking, blocked, stuck, waiting

        public var word: String { rawValue }
    }

    public struct Rect: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midY: Double { y + height / 2 }
        public var maxX: Double { x + width }
    }

    public struct Node: Hashable, Sendable, Identifiable {
        /// `lead`, or the task's item id.
        public var id: String
        /// 0: the goal; 1…: the phases, in plan order.
        public var column: Int
        public var row: Int
        public var frame: Rect
        public var title: String
        /// `2.1`, empty for the goal.
        public var number: String
        /// `claude · wt/anchors`, `working`.
        public var detail: String
        public var state: State
    }

    public struct Edge: Hashable, Sendable {
        public var from: String
        public var to: String
        /// The start and end, at the cards' right and left edges.
        public var start: (x: Double, y: Double) { (startX, startY) }
        public var end: (x: Double, y: Double) { (endX, endY) }
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        /// Its tail is a task that is done: drawn quieter.
        public var settled: Bool
    }

    public struct Layout: Hashable, Sendable {
        public var nodes: [Node]
        public var edges: [Edge]
        /// The phases' names over their columns, from column 1.
        public var columns: [String]
        public var width: Double
        public var height: Double

        public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
        public func nodes(in column: Int) -> [Node] { nodes.filter { $0.column == column }.sorted { $0.row < $1.row } }
        public var columnCount: Int { columns.count + 1 }
    }

    public struct Metrics: Hashable, Sendable {
        public var cardWidth: Double = 196
        public var cardHeight: Double = 58
        public var columnGap: Double = 44
        public var rowGap: Double = 18
        public var header: Double = 28

        public init() {}
    }

    /// The layout for `tasks` (in outline order) with each task's state. `goal`: the goal's title; `lead`: its lead's
    /// label.
    public static func layout(
        goal: String, lead: String, tasks: [SwarmTask], states: [String: State], details: [String: String] = [:],
        metrics: Metrics = Metrics()
    ) -> Layout {
        let phases = SwarmPlan.phases(tasks)
        let numbers = SwarmPlan.numbers(tasks)
        let tallest = max(phases.map(\.tasks.count).max() ?? 1, 1)
        let height = metrics.header + Double(tallest) * metrics.cardHeight + Double(tallest - 1) * metrics.rowGap
        func x(_ column: Int) -> Double { Double(column) * (metrics.cardWidth + metrics.columnGap) }
        var nodes: [Node] = []
        // The goal, centred on the left.
        nodes.append(Node(
            id: "lead", column: 0, row: 0,
            frame: Rect(
                x: 0, y: metrics.header + (height - metrics.header - metrics.cardHeight) / 2,
                width: metrics.cardWidth, height: metrics.cardHeight
            ),
            title: goal, number: "", detail: "goal · lead \(lead)", state: .working
        ))
        for (index, phase) in phases.enumerated() {
            let column = index + 1
            let count = phase.tasks.count
            let block = Double(count) * metrics.cardHeight + Double(max(count - 1, 0)) * metrics.rowGap
            let top = metrics.header + (height - metrics.header - block) / 2
            for (row, task) in phase.tasks.enumerated() {
                nodes.append(Node(
                    id: task.id, column: column, row: row,
                    frame: Rect(
                        x: x(column), y: top + Double(row) * (metrics.cardHeight + metrics.rowGap),
                        width: metrics.cardWidth, height: metrics.cardHeight
                    ),
                    title: task.title, number: numbers[task.id] ?? "",
                    detail: details[task.id] ?? task.owner?.label ?? "", state: states[task.id] ?? .waiting
                ))
            }
        }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var edges: [Edge] = []
        for task in tasks {
            guard let to = byID[task.id] else { continue }
            let blockers = task.after.compactMap { byID[$0] }
            // A task that waits for nothing in the plan hangs off the goal.
            for from in blockers.isEmpty ? [byID["lead"]].compactMap(\.self) : blockers {
                edges.append(Edge(
                    from: from.id, to: to.id, startX: from.frame.maxX, startY: from.frame.midY, endX: to.frame.x,
                    endY: to.frame.midY, settled: from.state == .done
                ))
            }
        }
        return Layout(
            nodes: nodes, edges: edges, columns: phases.map(\.name),
            width: x(phases.count) + metrics.cardWidth, height: height
        )
    }

    /// A card's state from where its task stands and what its worker is doing.
    public static func state(_ status: SwarmTaskStatus?, worker: AgentState?, stuck: Bool) -> State {
        guard let status else { return .waiting }
        switch status.state {
        case .done, .merged, .green: return .done
        case .pr: return .working
        case .working:
            if stuck { return .stuck }
            switch worker {
            case .asking?: return .asking
            case .blocked?, .limited?: return .blocked
            default: return .working
            }
        case .paused, .stalled: return .blocked
        case .waiting, .ready: return .waiting
        }
    }

    /// Where the cursor goes on `h` `l` (columns) and `j` `k` (cards in a column): its row kept as near as the column
    /// allows. Returns the node it lands on.
    public static func move(from id: String?, columns dx: Int, rows dy: Int, in layout: Layout) -> String? {
        guard let current = id.flatMap(layout.node) ?? layout.nodes.first else { return nil }
        let column = min(max(current.column + dx, 0), layout.columnCount - 1)
        let cards = layout.nodes(in: column)
        guard !cards.isEmpty else { return current.id }
        let row = current.row + dy
        return cards[min(max(row, 0), cards.count - 1)].id
    }
}
