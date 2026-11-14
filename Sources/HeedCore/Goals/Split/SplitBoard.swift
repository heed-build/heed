import Foundation

/// Where everything on the Split board goes: the hour axis and its ticks, a row per agent under the lead's spine, each
/// part a block as wide as its estimate, the elbows from what a part waits for to it, and the lead's moves on its
/// spine. Pure: the same schedule in the same width lays out the same, which the shots rely on.
public struct SplitBoardLayout: Hashable, Sendable {
    public struct Metrics: Hashable, Sendable {
        /// The agents' column: logo, name, model, spark and ring.
        public var header: Double = 262
        /// The axis' labels over the board.
        public var top: Double = 34
        public var leadHeight: Double = 44
        public var rowHeight: Double = 66
        public var blockHeight: Double = 44
        /// Room on the right of the timeline.
        public var trailing: Double = 16
        /// The gap a block leaves after itself, so neighbours read apart.
        public var blockGap: Double = 5
        /// The narrowest block: its number and a pip still fit.
        public var minBlock: Double = 30

        public init() {}
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

        public var maxX: Double { x + width }
        public var midY: Double { y + height / 2 }
        public func contains(_ px: Double, _ py: Double) -> Bool {
            px >= x && px <= maxX && py >= y && py <= y + height
        }
    }

    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// An elbow from what a part waits for to the part: across, down or up, across.
    public struct Connector: Hashable, Sendable {
        public var from: String
        public var to: String
        public var points: [Point]
        /// Both ends are on the longest chain: drawn heavier, in the chain's colour.
        public var onChain: Bool
    }

    /// What fits on a block of a width: the title from 52 points, the pips from 40, the repo's name from 110.
    public struct Label: Hashable, Sendable {
        public var title: Bool
        public var pips: Bool
        public var repoName: Bool

        public init(width: Double) {
            title = width > 52
            pips = width > 40
            repoName = width > 110
        }
    }

    public var metrics: Metrics
    public var width: Double
    public var height: Double
    /// The hours the axis spans.
    public var span: Double
    public var tick: Double
    public var ticks: [Double]
    /// Agent ids, top to bottom, under the lead.
    public var rows: [String]
    public var blocks: [String: Rect]
    public var connectors: [Connector]
    /// The lead's moves, at their x.
    public var moves: [PlacedMove]

    public struct PlacedMove: Hashable, Sendable {
        public var move: SplitSchedule.LeadMove
        public var x: Double
    }

    public var pointsPerHour: Double { (width - metrics.header - metrics.trailing) / max(span, 0.001) }

    /// The x of an hour on the axis.
    public func x(_ hours: Double) -> Double { metrics.header + hours * pointsPerHour }

    /// The hour at an x, for a drop.
    public func hours(at x: Double) -> Double { (x - metrics.header) / pointsPerHour }

    /// The spine's y.
    public var leadY: Double { metrics.top + metrics.leadHeight / 2 }

    /// The top of an agent's row.
    public func rowY(_ index: Int) -> Double { metrics.top + metrics.leadHeight + Double(index) * metrics.rowHeight }

    /// The row an y falls in (a drop), clamped to the rows.
    public func row(at y: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        let index = Int(floor((y - metrics.top - metrics.leadHeight) / metrics.rowHeight))
        return min(max(index, 0), rows.count - 1)
    }

    /// The tick every so many hours: the smallest of ¼, ½, 1, 2, 4, 8, 12 or 24 that gives at most ten.
    public static func tick(for hours: Double) -> Double {
        let steps = [0.25, 0.5, 1, 2, 4, 8, 12, 24]
        return steps.first { hours / $0 <= 10 } ?? 24
    }

    /// `0`, `0.5 h`, `20 h`.
    public static func tickText(_ hours: Double) -> String {
        if hours == 0 { return "0" }
        let rounded = (hours * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        return text + " h"
    }

    public static func make(
        schedule: SplitSchedule, rows: [String], width: Double, metrics: Metrics = Metrics()
    ) -> SplitBoardLayout {
        let raw = max(schedule.makespan + 0.2, 0.5)
        let tick = tick(for: raw)
        let span = (raw / tick).rounded(.up) * tick
        var layout = SplitBoardLayout(
            metrics: metrics, width: width, height: 0, span: span, tick: tick,
            ticks: (0 ... Int((span / tick).rounded())).map { Double($0) * tick }, rows: rows, blocks: [:],
            connectors: [], moves: []
        )
        layout.height = metrics.top + metrics.leadHeight + metrics.rowHeight * Double(rows.count) + 6
        for slot in schedule.slots.values {
            guard let agent = slot.agent, let row = rows.firstIndex(of: agent) else { continue }
            let x = layout.x(slot.start)
            let width = max(layout.x(slot.end) - x - metrics.blockGap, metrics.minBlock)
            let y = layout.rowY(row) + (metrics.rowHeight - metrics.blockHeight) / 2
            layout.blocks[slot.id] = Rect(x: x, y: y, width: width, height: metrics.blockHeight)
        }
        layout.moves = schedule.moves.map { PlacedMove(move: $0, x: layout.x($0.at)) }
        return layout
    }

    /// The elbows for `parts`, given their blocks: each from the end of what it waits for to its start.
    public mutating func connect(_ parts: [SplitPart], chain: [String]) {
        let onChain = Set(chain)
        var connectors: [Connector] = []
        for part in parts {
            guard let to = blocks[part.id] else { continue }
            for dep in part.task.after {
                guard let from = blocks[dep] else { continue }
                connectors.append(Connector(
                    from: dep, to: part.id, points: Self.elbow(from: from, to: to),
                    onChain: onChain.contains(dep) && onChain.contains(part.id)
                ))
            }
        }
        self.connectors = connectors
    }

    /// Across from the end of `from`, then down or up a little after it (never past the start of `to`), then across
    /// into `to`.
    public static func elbow(from: Rect, to: Rect) -> [Point] {
        let x1 = from.maxX
        let y1 = from.midY
        let x2 = to.x
        let y2 = to.midY
        if abs(y2 - y1) < 1 { return [Point(x1, y1), Point(x2, y2)] }
        let bend = min(x1 + 9, x2 - 7)
        return [Point(x1, y1), Point(bend, y1), Point(bend, y2), Point(x2, y2)]
    }

    /// The part at a point (a click, a hover), the topmost when blocks overlap.
    public func part(at x: Double, _ y: Double) -> String? {
        blocks.filter { $0.value.contains(x, y) }.min { $0.value.x > $1.value.x }?.key
    }
}

/// Moving the board's cursor: h l to the part before or after in time on the same agent (else the nearest in time
/// anywhere), j k to the agent's row below or above, onto the part nearest in time there.
public enum SplitCursor {
    public static func move(
        from id: String?, _ direction: String, schedule: SplitSchedule, rows: [String]
    ) -> String? {
        let slots = schedule.slots.values.filter { $0.agent.map(rows.contains) ?? false }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        guard !slots.isEmpty else { return nil }
        guard let id, let here = schedule.slots[id], let agent = here.agent, let row = rows.firstIndex(of: agent)
        else { return slots.first?.id }
        switch direction {
        case "l", "h":
            let forward = direction == "l"
            let same = slots.filter { $0.agent == agent }
            let index = same.firstIndex { $0.id == id } ?? 0
            let next = index + (forward ? 1 : -1)
            if same.indices.contains(next) { return same[next].id }
            let others = slots.filter { forward ? $0.start > here.start : $0.start < here.start }
            return (forward ? others.first : others.last)?.id ?? id
        case "j", "k":
            var target = row + (direction == "j" ? 1 : -1)
            while rows.indices.contains(target) {
                let there = slots.filter { $0.agent == rows[target] }
                if let nearest = there.min(by: { abs($0.start - here.start) < abs($1.start - here.start) }) {
                    return nearest.id
                }
                target += direction == "j" ? 1 : -1
            }
            return id
        default:
            return id
        }
    }
}

// MARK: The goal's page

/// A part's state on the goal's page, from its task's state in the swarm.
public enum PartState: Hashable, Sendable {
    /// Not started; nothing it waits for is late.
    case planned
    /// Waiting for what it waits for (hatched).
    case waiting
    /// Its agent works on it: how far, by its estimate.
    case running(progress: Double)
    /// It (or the lead for it) asks you something.
    case asking
    /// Its PR is open, being reviewed.
    case review
    case blocked
    case done

    /// From the swarm map's state of the task, when its worker started, and the part's estimate.
    public static func of(
        _ state: SwarmMap.State?, startedAt: Date?, minutes: Int, now: Date
    ) -> PartState {
        switch state {
        case .done?: return .done
        case .asking?: return .asking
        case .blocked?, .stuck?: return .blocked
        case .working?:
            guard let startedAt else { return .running(progress: 0) }
            let progress = now.timeIntervalSince(startedAt) / Double(max(minutes, 1) * 60)
            return .running(progress: min(max(progress, 0), 0.95))
        case .waiting?, nil: return .planned
        }
    }

    public var isDone: Bool { self == .done }
}

/// The goal's way from plan to done, as the bar across its page: planned, panel, split, building (n of m), reviewed,
/// walked, done.
public struct GoalJourney: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable, CaseIterable {
        case planned, panel, split, building, reviewed, walked, done
    }

    public struct Step: Hashable, Sendable {
        public var stage: Stage
        public var state: WizardStepState
        /// `building · 5/15`.
        public var title: String
    }

    public var steps: [Step]

    /// `wizard`: the goal's walk through the wizard, nil for a goal that never had one (its first three count as done:
    /// it has a plan). `done`/`total`: its parts. `swarm`: the run building it.
    public static func of(
        wizard: GoalWizard?, done: Int, total: Int, swarm: GoalSwarm?, goalDone: Bool
    ) -> GoalJourney {
        func finished(_ stage: Stage) -> Bool {
            switch stage {
            case .planned: wizard.map { $0.completed.contains(.plan) } ?? true
            case .panel: wizard.map { $0.completed.contains(.panel) } ?? true
            case .split: wizard.map { $0.completed.contains(.split) } ?? true
            case .building: total > 0 && done >= total
            case .reviewed: swarm.map { $0.status == .landing || $0.status == .done } ?? false || goalDone
            case .walked: swarm?.summary != nil || goalDone
            case .done: goalDone
            }
        }
        var steps: [Step] = []
        var current = false
        for stage in Stage.allCases {
            let isDone = finished(stage) && !current
            let state: WizardStepState = isDone ? .done : (current ? .next : .now)
            if !isDone { current = true }
            let title = stage == .building && total > 0 ? "building · \(done)/\(total)" : stage.rawValue
            steps.append(Step(stage: stage, state: state, title: title))
        }
        return GoalJourney(steps: steps)
    }
}

/// The one thing the goal's page asks of you, on top: the oldest question waiting on you (the lead's, or a worker's
/// the lead passed up), with its options.
public struct GoalNextStep: Hashable, Sendable {
    public var title: String
    public var detail: String
    public var options: [String]
    /// The steering row it answers, for `swarm.answer`.
    public var question: Int64?

    public init(title: String, detail: String, options: [String] = [], question: Int64? = nil) {
        self.title = title
        self.detail = detail
        self.options = options
        self.question = question
    }

    /// From the swarm's steering: the oldest question on you with no answer. `numbers` names parts (`part 7`).
    public static func from(_ steering: [SwarmSteer], numbers: [String: Int]) -> GoalNextStep? {
        let open = SwarmSteering.questions(steering).filter { question in
            question.answer == nil && (question.row.to == "you" || question.row.step == "you"
                || question.row.to == nil && question.row.actor == .lead)
        }
        guard let first = open.first?.row else { return nil }
        func part(_ address: String?) -> String? {
            guard let address, address.hasPrefix("task:") else { return nil }
            let id = String(address.dropFirst(5))
            return numbers[id].map { "part \($0)" } ?? SwarmPlan.short(id)
        }
        let asker = part(first.from).map { "\($0) asked the lead; the lead asks you" } ?? "the lead asks you"
        let effects = (first.effects ?? []).filter { !$0.isEmpty }
        let detail = ([asker] + (effects.isEmpty ? [] : [effects.joined(separator: "; ")])).joined(separator: ". ")
        return GoalNextStep(
            title: "Your next step: " + first.text.prefix(1).lowercased() + first.text.dropFirst(),
            detail: detail.prefix(1).uppercased() + detail.dropFirst(), options: first.options, question: first.id
        )
    }
}
