import Foundation

/// The six steps a new goal walks through before work starts, in order. Steps 1–3 are built here; Split, How careful
/// and Go are later parts: until each is `built`, reaching it hands over to the goal's page as it is today
/// (`fallback`), and the wizard keeps its place there so a later version picks it up.
public enum WizardStep: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case plan, panel, done, split, careful, go

    public var title: String {
        switch self {
        case .plan: "Plan"
        case .panel: "Panel"
        case .done: "Done looks like"
        case .split: "Split"
        case .careful: "How careful"
        case .go: "Go"
        }
    }

    /// 1…6, as the rail numbers them.
    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

    /// The step has its own screen in the wizard. The seam for the parts that come next: a step whose screen exists
    /// says so here, and the wizard stops handing it to the goal's page.
    public var built: Bool {
        switch self {
        case .plan, .panel, .done: true
        case .split, .careful, .go: false
        }
    }

    /// Where a step that is not built yet goes on the goal's page today: the swarm's plan (Split), Reviewers' bars
    /// (How careful), the goal's overview (Go).
    public var fallback: WizardFallback {
        switch self {
        case .plan, .panel, .done: .none
        case .split: .swarm
        case .careful: .reviewers
        case .go: .overview
        }
    }

    public var next: WizardStep? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index + 1 < all.count ? all[index + 1] : nil
    }

    public var previous: WizardStep? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index > 0 ? all[index - 1] : nil
    }

    public init?(word: String) {
        let key = word.lowercased().filter(\.isLetter)
        if let step = Self(rawValue: key) {
            self = step
        } else if let number = Int(word), (1 ... 6).contains(number) {
            self = Self.allCases[number - 1]
        } else {
            switch key {
            case "donelookslike", "criteria": self = .done
            case "howcareful", "care": self = .careful
            default: return nil
            }
        }
    }

    public static func < (lhs: WizardStep, rhs: WizardStep) -> Bool { lhs.number < rhs.number }
}

/// The goal page's screen a step not built yet hands over to.
public enum WizardFallback: String, Hashable, Sendable, Codable {
    case none, swarm, reviewers, overview
}

/// How the rail draws a step.
public enum WizardStepState: String, Hashable, Sendable {
    case done, now, next
}

/// A model call the wizard made, for its honest cost line: who, on which model, and what it cost (nil: the agent did
/// not say and no price was known).
public struct WizardCost: Hashable, Sendable, Codable {
    public var step: WizardStep
    public var agent: String
    public var model: String?
    public var dollars: Double?
    public var estimated: Bool

    public init(step: WizardStep, agent: String, model: String?, dollars: Double?, estimated: Bool = false) {
        self.step = step
        self.agent = agent
        self.model = model
        self.dollars = dollars
        self.estimated = estimated
    }
}

/// A goal's walk through the wizard: where it is, what each step settled, and what the model calls cost. Kept per goal
/// in `goals.sqlite` (`goal_wizards`), so leaving the wizard and coming back resumes where it was.
public struct GoalWizard: Hashable, Sendable, Codable {
    public var goal: String
    /// The step that shows.
    public var step: WizardStep
    /// Steps finished, whichever shows now, in order (an array, so it encodes the same every time).
    public var completed: [WizardStep]
    public var plan: PlanConversation
    public var panel: PanelState
    public var criteria: DoneDraft
    public var costs: [WizardCost]
    /// The TL;DR as last written, with what it was written from.
    public var tldr: WizardTLDR?
    /// What the TL;DR showed when you last opened it, for its entry's news.
    public var tldrSeen: TLDRSeen?
    /// "Don't do it": why, once the goal was archived from the panel.
    public var dropped: String?
    public var startedAt: Date
    public var updatedAt: Date

    public init(goal: String, at: Date) {
        self.goal = goal
        step = .plan
        completed = []
        plan = PlanConversation()
        panel = PanelState()
        criteria = DoneDraft()
        costs = []
        startedAt = at
        updatedAt = at
    }

    public func state(of step: WizardStep) -> WizardStepState {
        if step == self.step { return .now }
        return completed.contains(step) ? .done : .next
    }

    /// Every step finished, or the goal dropped: the wizard has nothing left to ask.
    public var finished: Bool { dropped != nil || WizardStep.allCases.allSatisfy(completed.contains) }

    /// The furthest step that may show: a finished one, the current one, or the one after the last finished.
    public var reach: WizardStep {
        let last = WizardStep.allCases.last { completed.contains($0) }
        return max(step, last?.next ?? .plan)
    }

    /// The current step finished; the next one shows. Nil at the end.
    @discardableResult
    public mutating func advance(at now: Date) -> WizardStep? {
        complete(step)
        updatedAt = now
        guard let next = step.next else { return nil }
        step = next
        return next
    }

    /// Shows another step: one already reached. False when it is past the reach.
    @discardableResult
    public mutating func show(_ target: WizardStep, at now: Date) -> Bool {
        guard target <= reach else { return false }
        step = target
        updatedAt = now
        return true
    }

    /// Marks a step finished.
    public mutating func complete(_ finished: WizardStep) {
        guard !completed.contains(finished) else { return }
        completed = (completed + [finished]).sorted()
    }

    public mutating func spent(_ cost: WizardCost) {
        costs.append(cost)
    }

    /// What a step's calls cost, known dollars summed; nil when none said.
    public func dollars(for step: WizardStep) -> Double? {
        let known = costs.filter { $0.step == step }.compactMap(\.dollars)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// The model the step's last call ran on.
    public func model(for step: WizardStep) -> String? {
        costs.last { $0.step == step }.flatMap { $0.model ?? $0.agent }
    }

    /// Some of the step's cost is an estimate or unknown: the cost line says so.
    public func costIsPartial(for step: WizardStep) -> Bool {
        costs.contains { $0.step == step && ($0.estimated || $0.dollars == nil) }
    }

    /// What the TL;DR depends on: everything but the TL;DR itself and the clock. It is written again only when this
    /// changes.
    public var fingerprint: String {
        var copy = self
        copy.tldr = nil
        copy.tldrSeen = nil
        copy.updatedAt = .distantPast
        copy.costs = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(copy)) ?? Data()
        return WizardHash.of(data)
    }
}

enum WizardHash {
    /// FNV-1a, hex: stable across launches, enough to tell that something changed.
    static func of(_ data: Data) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
