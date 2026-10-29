import Foundation

/// Hunch reading an agent's pane: one choice over its last lines (working, waiting for input, stuck, done), asked of
/// the checkpoint like any decision and learned from the screen snapshots heed labels with what the hooks reported.
/// Read only when Hunch is the decider and its model is downloaded; otherwise heed's own guess (`ScreenGuess`) stands.
public enum HunchScreen {
    /// What a pane shows, as Hunch answers it.
    public enum State: String, CaseIterable, Hashable, Sendable, Codable {
        case working, waiting, stuck, done

        /// The option Hunch picks between: short, so four fit the checkpoint's head budget.
        public var option: String {
            switch self {
            case .working: "working"
            case .waiting: "waiting for input"
            case .stuck: "stuck: looping or erroring"
            case .done: "done"
            }
        }

        public init?(option: String) {
            guard let state = State.allCases.first(where: { $0.option == option }) else { return nil }
            self = state
        }
    }

    /// The question's id in a decision.
    public static let questionID = "screen"

    /// The question Hunch is asked of a pane's last lines.
    public static let question = Question.choice(
        instructions: "What the coding agent in this terminal is doing now, judged from its last lines.",
        options: State.allCases.map(\.option)
    )

    /// Lines of a pane Hunch reads: the spike found the last 20 decide "is it waiting" best.
    public static let lines = HunchTrainingSet.screenLines

    /// What Hunch is shown: the pane cleaned as snapshots are (`ScreenText.clean`), its last `lines` lines. A
    /// snapshot's
    /// text is already clean: `tail` of it is the same thing, so what Hunch learns from and what it reads match.
    public static func state(ofScreen screen: String) -> String {
        tail(ScreenText.clean(screen, lines: ScreenSnapshot.lines))
    }

    /// The last `lines` lines of cleaned text.
    public static func tail(_ cleaned: String) -> String {
        HunchTrainingSet.trimmed(
            cleaned.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n"),
            keepEnd: true
        )
    }

    /// The label a snapshot gives the question: what the hooks reported. Asking or blocked waits for input, working
    /// works, done is done. Idle, limited and exited are none of the four, and no hook reports stuck: Hunch judges
    /// that from the checkpoint alone.
    public static func label(_ state: AgentState) -> State? {
        switch state {
        case .asking, .blocked: .waiting
        case .working: .working
        case .done: .done
        case .idle, .limited, .exited: nil
        }
    }

    /// Below this calibrated confidence a reading says nothing, and heed's guess stands.
    public static let minimumConfidence = 0.5

    /// Whether panes are read by Hunch now: Hunch is the decider and its model is downloaded.
    public static func reads(decider: DecisionSettings.Choice?, modelReady: Bool) -> Bool {
        decider == .hunch && modelReady
    }

    /// One reading of one pane.
    public struct Reading: Hashable, Sendable {
        public var state: State
        /// Hunch's calibrated confidence in it, 0…1.
        public var confidence: Double
        public var at: Date

        public init(state: State, confidence: Double, at: Date) {
            self.state = state
            self.confidence = confidence
            self.at = at
        }

        /// The answer to `question` as a reading; nil for an answer that is none of the options.
        public init?(_ answer: Answer, at: Date) {
            guard let choice = answer.choice, let state = State(option: choice) else { return nil }
            self.init(state: state, confidence: answer.confidence, at: at)
        }

        /// Whether it counts: sure enough. It stays the pane's reading until the next one replaces it: a pane is
        /// read again within a minute of its screen changing, and a read that fails drops the reading.
        public var counts: Bool { confidence >= minimumConfidence }

        /// `waiting for input · Hunch 87%`.
        public var line: String { "\(state.option) · Hunch \(Int((confidence * 100).rounded()))%" }
    }

    /// Once a pane per `every` at most, and only when its text changed since the last read: Hunch is cheap, but not
    /// free, and a still screen says what it said.
    public struct Throttle: Sendable {
        public static let every: TimeInterval = 60

        private var last: [String: (at: Date, text: String)] = [:]

        public init() {}

        /// Whether `pane`, showing `text`, is due a read now; when it is, the read is recorded as made.
        public mutating func due(pane: String, text: String, now: Date, every: TimeInterval = Throttle.every) -> Bool {
            if let previous = last[pane], previous.text == text || now.timeIntervalSince(previous.at) < every {
                return false
            }
            last[pane] = (now, text)
            return true
        }

        public mutating func forget(pane: String) {
            last[pane] = nil
        }
    }

    /// What a reading makes of a session's state, for agents that cannot report it (`ScreenGuess.reported`): waiting
    /// is a question for you (asking, else blocked when the agent reports asking itself), done is done. Working and
    /// stuck are no state of their own: nil, and the screen guess's own rules apply.
    public static func sessionState(_ reading: Reading, reported: Set<AgentState>) -> AgentState? {
        switch reading.state {
        case .waiting:
            if !reported.contains(.asking) { return .asking }
            return reported.contains(.blocked) ? nil : .blocked
        case .done: return reported.contains(.done) ? nil : .done
        case .working, .stuck: return nil
        }
    }
}
