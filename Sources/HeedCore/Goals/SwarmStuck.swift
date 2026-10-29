import Foundation

/// When a swarm's worker looks stuck, and what heed does about it (deck p13). Pure: the app gathers what it knows of a
/// worker (its activity, its errors, its screen, the questions it waits on) into an `Observation`, asks `signal`, and
/// on a tick asks `next` what the ladder does: nudge the worker to try another way, then ask on its behalf (a peer,
/// the controller, you, as `SwarmLadder` climbs any question), or call the episode over.
public enum SwarmStuck {
    /// When a worker counts as stuck, per swarm (`SwarmSettings.stuck`). Defaults from the deck.
    public struct Settings: Hashable, Sendable, Codable {
        /// Time on the task over its estimate, as a ratio (1.5: half again). A weak signal only: it shows, it never
        /// starts the ladder.
        public var overEstimate: Double
        /// The same error this many times in a row.
        public var sameError: Int
        /// Minutes with no tool call and no file change.
        public var noProgress: Int
        /// Minutes a question may wait on a peer before it goes up the ladder.
        public var waitingOnPeer: Int
        /// Minutes a question may wait on you before heed reminds you.
        public var waitingOnYou: Int

        public init(
            overEstimate: Double = 1.5, sameError: Int = 3, noProgress: Int = 10, waitingOnPeer: Int = 8,
            waitingOnYou: Int = 15
        ) {
            self.overEstimate = overEstimate
            self.sameError = sameError
            self.noProgress = noProgress
            self.waitingOnPeer = waitingOnPeer
            self.waitingOnYou = waitingOnYou
        }

        public static let defaults = Settings()

        /// The words `:swarm.stuck` takes, each with how it sets the field: `estimate 2`, `errors 4`, `quiet 15`,
        /// `peer 10`, `you 20`. Nil for a word or value it does not take (a negative one, or a ratio under 1).
        public func setting(_ word: String, to value: String) -> Settings? {
            guard let number = Double(value), number >= 0 else { return nil }
            var next = self
            switch word.lowercased() {
            case "estimate", "over":
                guard number == 0 || number >= 1 else { return nil }
                next.overEstimate = number
            case "errors", "error", "same": next.sameError = Int(number)
            case "quiet", "progress", "noprogress": next.noProgress = Int(number)
            case "peer": next.waitingOnPeer = Int(number)
            case "you": next.waitingOnYou = Int(number)
            default: return nil
            }
            return next
        }

        /// `1.5× estimate · 3× same error · 10 min no progress · 8 min on a peer · 15 min on you`.
        public var line: String {
            "\(String(format: "%g", overEstimate))× estimate · \(sameError)× same error · \(noProgress) min no progress"
                + " · \(waitingOnPeer) min on a peer · \(waitingOnYou) min on you"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Settings()
            overEstimate = try values.decodeIfPresent(Double.self, forKey: .overEstimate) ?? fallback.overEstimate
            sameError = try values.decodeIfPresent(Int.self, forKey: .sameError) ?? fallback.sameError
            noProgress = try values.decodeIfPresent(Int.self, forKey: .noProgress) ?? fallback.noProgress
            waitingOnPeer = try values.decodeIfPresent(Int.self, forKey: .waitingOnPeer) ?? fallback.waitingOnPeer
            waitingOnYou = try values.decodeIfPresent(Int.self, forKey: .waitingOnYou) ?? fallback.waitingOnYou
        }

        private enum CodingKeys: String, CodingKey {
            case overEstimate, sameError, noProgress, waitingOnPeer, waitingOnYou
        }
    }

    /// What heed's screen reading says of the worker's pane, where it says anything (Hunch's label, else the screen
    /// guess).
    public enum Screen: String, Hashable, Sendable {
        case waiting, stuck
    }

    /// The screen's label where heed has one: a label read from the pane (Hunch's, when one says waiting or stuck)
    /// first, else the screen guess: a pane whose hooks say working but whose screen waits on a prompt is waiting.
    public static func screen(label: String? = nil, guessed: AgentState?, reported: AgentState?) -> Screen? {
        if let label = label.flatMap(Screen.init(rawValue:)) { return label }
        guard reported == .working, let guessed, guessed == .asking || guessed == .blocked else { return nil }
        return .waiting
    }

    /// What heed knows of one worker now.
    public struct Observation: Hashable, Sendable {
        public var now: Date
        public var startedAt: Date
        /// The task's estimate, in minutes.
        public var estimate: Int?
        /// Its newest tool call or file change; nil when it has none yet (its start counts).
        public var lastActivity: Date?
        /// The error digests of its tool calls, oldest first, nil for a call that went fine.
        public var recentErrors: [String?]
        public var screen: Screen?
        /// Since when a question of its own waits on a peer, the lead or the controller; or on you.
        public var waitingOnOthers: Date?
        public var waitingOnYou: Date?

        public init(
            now: Date, startedAt: Date, estimate: Int? = nil, lastActivity: Date? = nil, recentErrors: [String?] = [],
            screen: Screen? = nil, waitingOnOthers: Date? = nil, waitingOnYou: Date? = nil
        ) {
            self.now = now
            self.startedAt = startedAt
            self.estimate = estimate
            self.lastActivity = lastActivity
            self.recentErrors = recentErrors
            self.screen = screen
            self.waitingOnOthers = waitingOnOthers
            self.waitingOnYou = waitingOnYou
        }
    }

    /// Why a worker looks stuck.
    public enum Reason: Hashable, Sendable {
        /// No tool call or file change for this many minutes.
        case noProgress(minutes: Int)
        /// The same error, this many times in a row.
        case sameError(String, count: Int)
        /// heed's screen reading says so.
        case screen(Screen)
        /// Over its estimate: time on the task as a ratio of it.
        case overEstimate(ratio: Double)
        /// Its question waits on a peer, the lead or the controller, this long.
        case waitingOnOthers(minutes: Int)
        /// Its question waits on you, this long.
        case waitingOnYou(minutes: Int)

        /// Strong reasons start the ladder; weak ones only show (amber).
        public var strong: Bool {
            switch self {
            case .noProgress, .sameError, .screen: true
            case .overEstimate, .waitingOnOthers, .waitingOnYou: false
            }
        }

        /// `no tool call or file change for 12 min`, `the same error 3×: …`.
        public var text: String {
            switch self {
            case let .noProgress(minutes): "no tool call or file change for \(minutes) min"
            case let .sameError(digest, count): "the same error \(count)×: \(digest)"
            case let .screen(label): "its screen reads \(label.rawValue)"
            case let .overEstimate(ratio): "\(Int((ratio * 100).rounded()))% of its estimate"
            case let .waitingOnOthers(minutes): "waiting on an answer for \(minutes) min"
            case let .waitingOnYou(minutes): "waiting on you for \(minutes) min"
            }
        }

        /// `stuck`, `waiting`, `over estimate`: the agents pane's word.
        public var word: String {
            switch self {
            case .noProgress, .sameError: "stuck"
            case let .screen(label): label.rawValue
            case .overEstimate: "over estimate"
            case .waitingOnOthers: "waiting"
            case .waitingOnYou: "waiting on you"
            }
        }
    }

    /// A worker's stuck signal: every reason that holds, strongest first.
    public struct Signal: Hashable, Sendable {
        public var reasons: [Reason]

        /// The reason shown first.
        public var main: Reason { reasons[0] }
        /// Whether it starts the ladder.
        public var strong: Bool { reasons.contains(where: \.strong) }
        public var text: String { reasons.map(\.text).joined(separator: "; ") }
    }

    /// The worker's signal, nil when nothing holds. Waiting on a question is not being stuck: while one waits, its
    /// quiet does not count (the question has a ladder of its own).
    public static func signal(_ observation: Observation, settings: Settings = .defaults) -> Signal? {
        var reasons: [Reason] = []
        let now = observation.now
        func minutes(since date: Date) -> Int { max(0, Int(now.timeIntervalSince(date) / 60)) }
        let waiting = observation.waitingOnOthers != nil || observation.waitingOnYou != nil
        // The same error, the newest calls in a row.
        if settings.sameError > 0, let last = observation.recentErrors.last, let digest = last {
            let run = observation.recentErrors.reversed().prefix { $0 == digest }.count
            if run >= settings.sameError { reasons.append(.sameError(digest, count: run)) }
        }
        if !waiting {
            let quiet = minutes(since: observation.lastActivity ?? observation.startedAt)
            if settings.noProgress > 0, quiet >= settings.noProgress { reasons.append(.noProgress(minutes: quiet)) }
            if let screen = observation.screen { reasons.append(.screen(screen)) }
        }
        if let since = observation.waitingOnYou { reasons.append(.waitingOnYou(minutes: minutes(since: since))) }
        if let since = observation.waitingOnOthers {
            reasons.append(.waitingOnOthers(minutes: minutes(since: since)))
        }
        if let estimate = observation.estimate, estimate > 0, settings.overEstimate > 0 {
            let ratio = now.timeIntervalSince(observation.startedAt) / 60 / Double(estimate)
            if ratio >= settings.overEstimate { reasons.append(.overEstimate(ratio: ratio)) }
        }
        guard !reasons.isEmpty else { return nil }
        return Signal(reasons: reasons.sorted { $0.strong && !$1.strong })
    }

    // MARK: The ladder

    /// A stuck episode's steps, as `step` on its `stuck` rows.
    public enum Step: String, Hashable, Sendable {
        /// heed told the worker to try another way.
        case nudge
        /// Still stuck: heed asked on its behalf (a question that climbs the ladder: peer, controller, you).
        case ask
        /// Moving again: the episode is over.
        case clear
    }

    /// What the app does about a worker on a tick.
    public enum Action: Hashable, Sendable {
        case none
        /// It just got stuck: a `stuck` row, and a short nudge to the worker (delivered as any message is).
        case nudge(Signal)
        /// Still stuck `settings.noProgress` minutes after the nudge: a question on its behalf.
        case ask(Signal)
        /// It moves again: the episode ends.
        case clear
    }

    /// The task's open episode: its newest `stuck` row, unless that one ends it.
    public static func episode(of task: String, _ rows: [SwarmSteer]) -> SwarmSteer? {
        let ref = "task:\(task)"
        guard let last = rows.last(where: { $0.kind == .stuck && $0.ref == ref }), last.step != Step.clear.rawValue
        else { return nil }
        return last
    }

    /// The next step for a task's worker: `signal` is its signal now (nil, or weak, when it moves).
    public static func next(
        task: String, signal: Signal?, rows: [SwarmSteer], now: Date, settings: Settings = .defaults
    ) -> Action {
        let open = episode(of: task, rows)
        guard let signal, signal.strong else { return open == nil ? .none : .clear }
        guard let open else { return .nudge(signal) }
        if open.step == Step.nudge.rawValue, now.timeIntervalSince(open.at) >= Double(settings.noProgress) * 60 {
            return .ask(signal)
        }
        return .none
    }

    /// What heed types to a stuck worker: what it saw, and to try another way.
    public static func nudge(_ signal: Signal) -> String {
        "You look stuck (\(signal.main.text)). Write down in a line what you tried (heed swarm note), then try a "
            + "different approach; if you need a decision, ask it with heed goal ask."
    }

    /// The question heed asks on a still-stuck worker's behalf, and its choices with what each would change.
    public static func question(number: String, title: String, signal: Signal) -> (
        text: String, options: [String], effects: [String]
    ) {
        (
            "\(number) \(title) is still stuck (\(signal.main.text)): how should it go on?",
            ["try a different approach", "stop and wait for the owner"],
            [
                "the worker is told to drop what it tried and take another way",
                "the worker stops; the task waits for you",
            ]
        )
    }

    /// Questions from workers that wait on you longer than `settings.waitingOnYou` minutes and were not yet the
    /// subject of a reminder: what heed reminds you of.
    public static func reminders(
        _ rows: [SwarmSteer], now: Date, settings: Settings = .defaults
    ) -> [SwarmSteering.Question] {
        guard settings.waitingOnYou > 0 else { return [] }
        let reminded = Set(rows.filter { $0.kind == .remind }.compactMap(\.about))
        return SwarmSteering.questions(rows).filter { question in
            guard question.answer == nil, !reminded.contains(question.id) else { return false }
            let position = SwarmLadder.position(question.row, rows: rows)
            return position.step == .you
                && now.timeIntervalSince(position.since) >= Double(settings.waitingOnYou) * 60
        }
    }
}
