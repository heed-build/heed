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
        /// Room for a title on two lines and the owner and state under it.
        public var cardHeight: Double = 68
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

// MARK: Messages in flight

public extension SwarmMap {
    struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// A cubic curve: the shape `GraphCanvas` draws an edge with (controls `bend` along x from each end), so a message
    /// between two cards an edge joins travels on that edge.
    struct Curve: Hashable, Sendable {
        public var start: Point
        public var control1: Point
        public var control2: Point
        public var end: Point

        /// From `start` (a card's right edge) to `end` (another's left edge), bending as an edge does.
        public static func edge(from start: Point, to end: Point) -> Curve {
            let bend = max((end.x - start.x) / 2, 12)
            return Curve(
                start: start, control1: Point(x: start.x + bend, y: start.y),
                control2: Point(x: end.x - bend, y: end.y), end: end
            )
        }

        public func point(at t: Double) -> Point {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return Point(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }

        /// Where along the curve x is `x`: the curves here only move rightwards, so a bisection finds it.
        func t(atX x: Double) -> Double {
            var low = 0.0, high = 1.0
            for _ in 0 ..< 40 {
                let mid = (low + high) / 2
                if point(at: mid).x < x { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }
    }

    /// Something on its way from one agent to another (or to you), as the steering log has it.
    struct Message: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case message, question, answer
        }

        public var from: SwarmAddress
        public var to: SwarmAddress
        public var kind: Kind

        public init(from: SwarmAddress, to: SwarmAddress, kind: Kind) {
            self.from = from
            self.to = to
            self.kind = kind
        }
    }

    /// A dot on the map: what is in flight between two cards, drawn on the path between them, at the gap next to
    /// the card it goes to (so it never hides under a card, and its side says which way it goes).
    struct Flight: Hashable, Sendable {
        /// Node ids (`lead` or a task's id).
        public var from: String
        public var to: String
        /// A question if any of them is one, else an answer, else a message.
        public var kind: Message.Kind
        /// How many are on their way along this path, this way.
        public var count: Int
        public var curve: Curve
        public var dot: Point
    }

    /// What is on its way now: everything heed still has to hand to an agent (`SwarmDelivery.pending`, whatever the
    /// time: an answer in its grace period is on its way too), and the questions that wait for you, toward the goal
    /// and its lead. No clock: the same rows give the same dots.
    static func inFlight(_ rows: [SwarmSteer]) -> [Message] {
        var messages: [Message] = []
        for item in SwarmDelivery.pending(rows, now: .distantFuture) {
            guard let from = item.row.from.flatMap(SwarmAddress.init(raw:)) ?? actorAddress(item.row.actor) else {
                continue
            }
            let kind: Message.Kind = switch item.row.kind {
            case .question: .question
            case .answer, .overrule: .answer
            default: .message
            }
            messages.append(Message(from: from, to: item.to, kind: kind))
        }
        for question in SwarmSteering.questions(rows) where question.answer == nil
            && SwarmLadder.position(question.row, rows: rows).step == .you
        {
            guard let from = question.row.from.flatMap(SwarmAddress.init(raw:)) else { continue }
            messages.append(Message(from: from, to: .you, kind: .question))
        }
        return messages
    }

    private static func actorAddress(_ actor: SwarmSteer.Actor) -> SwarmAddress? {
        switch actor {
        case .you: .you
        case .lead: .lead
        case .controller: .controller
        case .heed: .heed
        case .agent: nil
        }
    }

    /// The card an address is drawn at: a task's own card; the lead, you, the controller and heed share the goal's.
    static func node(of address: SwarmAddress, in layout: Layout) -> Node? {
        switch address {
        case .lead, .you, .controller, .heed: layout.node("lead")
        case let .task(id): layout.node(id)
        case .all, .session: nil
        }
    }

    /// The dots for `messages`: one per pair of cards and direction, in a stable order.
    static func flights(_ messages: [Message], in layout: Layout, metrics: Metrics = Metrics()) -> [Flight] {
        var order: [String] = []
        var grouped: [String: (from: Node, to: Node, kinds: [Message.Kind])] = [:]
        for message in messages {
            guard let from = node(of: message.from, in: layout), let to = node(of: message.to, in: layout),
                  from.id != to.id
            else { continue }
            let key = "\(from.id)>\(to.id)"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (from, to, [])
            }
            grouped[key]?.kinds.append(message.kind)
        }
        func strongest(_ kinds: [Message.Kind]) -> Message.Kind {
            kinds.contains(.question) ? .question : kinds.contains(.answer) ? .answer : .message
        }
        var flights: [Flight] = []
        var kinds: [[Message.Kind]] = []
        for key in order {
            guard let group = grouped[key] else { continue }
            let (curve, dot) = path(from: group.from, to: group.to, metrics: metrics)
            // Dots that would sit on one another (two workers asking you) become one, counting both.
            if let near = flights.firstIndex(where: {
                $0.to == group.to.id && abs($0.dot.x - dot.x) < metrics.rowGap && abs($0.dot.y - dot.y) < metrics.rowGap
            }) {
                kinds[near] += group.kinds
                flights[near].count = kinds[near].count
                flights[near].kind = strongest(kinds[near])
                continue
            }
            kinds.append(group.kinds)
            flights.append(Flight(
                from: group.from.id, to: group.to.id, kind: strongest(group.kinds), count: group.kinds.count,
                curve: curve, dot: dot
            ))
        }
        return flights
    }

    /// The path between two cards and where its dot sits. Cards in different columns: the edge's curve from the left
    /// card's right edge to the right card's left edge, the dot in the column gap next to the card it goes to. Cards in
    /// one column: an arc through the gap to their left, the dot at its middle.
    static func path(from: Node, to: Node, metrics: Metrics) -> (Curve, Point) {
        if from.column == to.column {
            let x = from.frame.x
            let bulge = metrics.columnGap * 0.6
            let curve = Curve(
                start: Point(x: x, y: from.frame.midY), control1: Point(x: x - bulge, y: from.frame.midY),
                control2: Point(x: x - bulge, y: to.frame.midY), end: Point(x: x, y: to.frame.midY)
            )
            return (curve, curve.point(at: 0.5))
        }
        let (left, right) = from.column < to.column ? (from, to) : (to, from)
        let curve = Curve.edge(
            from: Point(x: left.frame.maxX, y: left.frame.midY), to: Point(x: right.frame.x, y: right.frame.midY)
        )
        // The gap beside the card it goes to: before it when it is on the right, after it when on the left.
        let gap = to.column > from.column ? to.frame.x - metrics.columnGap / 2 : to.frame.maxX + metrics.columnGap / 2
        return (curve, curve.point(at: curve.t(atX: gap)))
    }
}
