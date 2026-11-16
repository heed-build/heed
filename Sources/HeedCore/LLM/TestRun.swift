import Foundation

/// How one of Settings' Test buttons went: running, or its answer, or why it failed. There is no running test with
/// an answer, and no finished one without either.
public enum TestRun<Answer: Equatable & Sendable>: Equatable, Sendable {
    case running
    case passed(Answer)
    case failed(String)

    public var isRunning: Bool {
        self == .running
    }

    public var answer: Answer? {
        if case let .passed(answer) = self { answer } else { nil }
    }

    public var error: String? {
        if case let .failed(error) = self { error } else { nil }
    }

    /// Whether a test may start over `current`: not while one runs.
    public static func canStart(over current: TestRun?) -> Bool {
        current?.isRunning != true
    }
}

/// What an agent said to Settings' test call.
public struct AgentTestAnswer: Equatable, Sendable {
    public var text: String
    public var model: String?
    public var seconds: Double?
    public var cost: Double?

    public init(text: String, model: String? = nil, seconds: Double? = nil, cost: Double? = nil) {
        self.text = text
        self.model = model
        self.seconds = seconds
        self.cost = cost
    }

    /// `“Hello!” · claude-haiku · 2.9s · $0.0003`: a test costs a fraction of a cent, so four places, not <$0.01.
    public var summary: String {
        var parts = ["“\(text)”"]
        if let model { parts.append(model) }
        if let seconds { parts.append(String(format: "%.1fs", seconds)) }
        if let cost { parts.append(cost < 0.01 ? String(format: "$%.4f", cost) : AgentUsage.dollars(cost)) }
        return parts.joined(separator: " · ")
    }
}

/// What the decision test picked, and how long it took.
public struct DecisionTestAnswer: Equatable, Sendable {
    public var text: String
    public var seconds: Double?

    public init(text: String, seconds: Double? = nil) {
        self.text = text
        self.seconds = seconds
    }

    public var summary: String {
        ([text] + (seconds.map { [String(format: "%.1fs", $0)] } ?? [])).joined(separator: " · ")
    }
}
