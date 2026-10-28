import Foundation

/// `[hunch]`: which checkpoint Hunch runs, and whether it learns from your corrections.
public struct HunchSettings: Equatable, Sendable {
    public static let defaultCheckpoint = "english"

    /// `checkpoint`: Hunch's name for it; nil: `english`.
    public var checkpoint: String?
    /// `learn`; nil: on once a model is downloaded.
    public var learn: Bool?

    public init(checkpoint: String? = nil, learn: Bool? = nil) {
        self.checkpoint = checkpoint
        self.learn = learn
    }

    public var effectiveCheckpoint: String { checkpoint ?? Self.defaultCheckpoint }

    public func learns(modelReady: Bool) -> Bool { learn ?? modelReady }
}

/// How a head did on the held-out examples: Hunch's evaluation, kept.
public struct HunchScore: Codable, Equatable, Sendable {
    public var count: Int
    public var correct: Int
    /// Mean cross-entropy of the right answer.
    public var loss: Double

    public init(count: Int, correct: Int, loss: Double) {
        self.count = count
        self.correct = correct
        self.loss = loss
    }

    public var accuracy: Double { count == 0 ? 0 : Double(correct) / Double(count) }

    /// "86% (43 of 50)".
    public var text: String { "\(Int((accuracy * 100).rounded()))% (\(correct) of \(count))" }
}

/// What the last training run did, kept in the models folder (`learning/record.json`).
public struct HunchLearningRecord: Codable, Equatable, Sendable {
    public var trainedAt: Date?
    /// The checkpoint the run and its head belong to.
    public var checkpoint: String?
    /// Examples trained on, and held out to judge.
    public var trained: Int
    public var heldOut: Int
    /// The head in use before the run, and the run's own, on the held-out examples.
    public var before: HunchScore?
    public var after: HunchScore?
    public var adopted: Bool?
    /// Why the run's head was not adopted.
    public var kept: String?
    public var seconds: Double?
    /// The head file in use (in `learning/heads/`); nil: the checkpoint's own.
    public var head: String?
    /// The examples there were when it ran: new ones since count toward the next run.
    public var examplesAtRun: Int
    public var error: String?

    public init(
        trainedAt: Date? = nil, checkpoint: String? = nil, trained: Int = 0, heldOut: Int = 0,
        before: HunchScore? = nil, after: HunchScore? = nil, adopted: Bool? = nil, kept: String? = nil,
        seconds: Double? = nil, head: String? = nil, examplesAtRun: Int = 0, error: String? = nil
    ) {
        self.trainedAt = trainedAt
        self.checkpoint = checkpoint
        self.trained = trained
        self.heldOut = heldOut
        self.before = before
        self.after = after
        self.adopted = adopted
        self.kept = kept
        self.seconds = seconds
        self.head = head
        self.examplesAtRun = examplesAtRun
        self.error = error
    }
}

/// Whether a newly trained head replaces the one in use: only when it is not worse on the held-out examples it never
/// saw. Not worse means at least as many right, and when exactly as many, a loss no higher (as sure of the right
/// answers). A tie in both keeps the head in use: no change without a reason.
public enum HunchAdopt {
    public static let minimumHeldOut = 10

    public enum Verdict: Equatable, Sendable {
        case adopt
        case keep(String)
    }

    public static func verdict(before: HunchScore, after: HunchScore) -> Verdict {
        guard after.count >= minimumHeldOut, before.count == after.count else {
            return .keep("only \(after.count) held-out examples, \(minimumHeldOut) needed to judge")
        }
        if after.correct < before.correct {
            return .keep("worse on held-out examples: \(after.text) against \(before.text)")
        }
        if after.correct == before.correct {
            if after.loss > before.loss {
                return .keep("no better on held-out examples (\(after.text)) and less sure of the right answers")
            }
            if after.loss == before.loss { return .keep("no different on held-out examples (\(after.text))") }
        }
        return .adopt
    }
}

/// What the Mac is doing, read by the app before and during a run.
public struct HunchConditions: Equatable, Sendable {
    /// Since the last keyboard or mouse input.
    public var idleSeconds: Double
    public var onPower: Bool
    /// `ProcessInfo.ThermalState`'s raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    public var lowPowerMode: Bool

    public init(idleSeconds: Double, onPower: Bool, thermal: Int, lowPowerMode: Bool) {
        self.idleSeconds = idleSeconds
        self.onPower = onPower
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }
}

/// When a training run starts, and when one stops: in the background, at low priority, never during heavy use.
public enum HunchSchedule {
    /// Examples before the first run, and held out of them.
    public static let minimumExamples = 30
    /// New examples since the last run before another.
    public static let minimumNew = 20
    /// Between runs that were not asked for.
    public static let minimumInterval: TimeInterval = 12 * 3600
    /// No input for this long counts as idle.
    public static let idleAfter: TimeInterval = 5 * 60
    /// Input this recent stops a run that was not asked for.
    public static let activeWithin: TimeInterval = 30

    public enum Due: Equatable, Sendable {
        case train
        case wait(String)
    }

    /// Whether to train now. `asked`: Retrain now, which skips the counts and the idle wait but not a hot Mac, a
    /// battery or Low Power Mode.
    public static func due(
        now: Date, record: HunchLearningRecord, examples: Int, heldOut: Int, conditions: HunchConditions,
        asked: Bool
    ) -> Due {
        if let reason = busy(conditions) { return .wait(reason) }
        guard heldOut >= HunchAdopt.minimumHeldOut, examples >= minimumExamples else {
            return .wait(
                "waiting for \(minimumExamples) examples with \(HunchAdopt.minimumHeldOut) held out "
                    + "(\(examples) so far, \(heldOut) held out)"
            )
        }
        if asked { return .train }
        if let last = record.trainedAt {
            let new = examples - record.examplesAtRun
            if new < minimumNew { return .wait("next run after \(minimumNew) new examples (\(max(0, new)) so far)") }
            if now.timeIntervalSince(last) < minimumInterval { return .wait("trained less than 12 hours ago") }
        }
        guard conditions.idleSeconds >= idleAfter else { return .wait("waiting until the Mac is idle") }
        return .train
    }

    /// Why a run cannot go on now, or nil. A run that was not asked for also stops as soon as you use the Mac.
    public static func shouldStop(_ conditions: HunchConditions, asked: Bool) -> String? {
        if let reason = busy(conditions) { return reason }
        if !asked, conditions.idleSeconds < activeWithin { return "stopped: you are using the Mac" }
        return nil
    }

    static func busy(_ conditions: HunchConditions) -> String? {
        if !conditions.onPower { return "on battery: training waits for power" }
        if conditions.lowPowerMode { return "Low Power Mode is on" }
        if conditions.thermal >= 2 { return "the Mac is hot: training waits" }
        return nil
    }
}

/// Where Hunch stands, for the top of the pane and the reminder.
public enum HunchStatus: Equatable, Sendable {
    /// Not on this Mac (an Intel Mac); why.
    case unavailable(String)
    case noModel
    case downloading(Double?)
    /// The download stopped part-way or failed; Download resumes it.
    case stopped(Double?, String?)
    case ready
    case learning(Double?)

    public static func of(supported: Bool, download: HunchDownloadState, training: Double??) -> HunchStatus {
        guard supported else { return .unavailable("Hunch needs a Mac with Apple silicon.") }
        switch download {
        case .absent: return .noModel
        case .downloading, .verifying: return .downloading(download.fraction)
        case .partial: return .stopped(download.fraction, nil)
        case let .failed(reason, _, _): return .stopped(download.fraction, reason)
        case .ready:
            if let training { return .learning(training) }
            return .ready
        }
    }

    public var label: String {
        switch self {
        case .unavailable: "unavailable"
        case .noModel: "no model"
        case .downloading: "downloading"
        case .stopped: "download stopped"
        case .ready: "ready"
        case .learning: "learning"
        }
    }

    public var modelReady: Bool {
        switch self {
        case .ready, .learning: true
        default: false
        }
    }

    static func percent(_ fraction: Double?) -> String {
        fraction.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
    }
}
