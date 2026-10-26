import Foundation

/// What the tutor can see of the app after each key: enough to tell whether a step was done, nothing more.
public struct TutorState: Equatable, Sendable {
    public var mode: Mode = .normal
    /// `sessions`, `inbox`, `issues`, `prs`, `repos`, `history`.
    public var view = "sessions"
    /// The row the cursor is on in the current view's list.
    public var cursor = 0
    public var rows = 0
    /// `pr`, `diff`, `reader`, `issue`, `help`, or nil.
    public var overlay: String?
    public var filtering = false
    public var filter = ""
    public var focusedPane = 0
    public var panes = 0
    public var tab = 0
    public var tabs = 0
    public var startWorkOpen = false
    /// What Start work's prompt says, and the repo it would start in.
    public var startWorkPrompt = ""
    public var startWorkRepo: String?
    public var confirmationOpen = false
    /// The setup wizard (`repo.setup`) is open, and on which step (0 sample … 3 write).
    public var repoSetupOpen = false
    public var repoSetupStep = 0
    public var importOpen = false
    /// The hosts dialog (`gH`) is open.
    public var hostsOpen = false
    /// Sessions that run on a host.
    public var hostSessions = 0
    public var commandLine = false
    public var helpOpen = false
    public var sessions = 0
    /// Sessions that are chats.
    public var chats = 0
    /// The pin number of the session under the cursor (`'1` jumps to 1), if it is pinned.
    public var pinned: Int?
    public var pins = 0
    public var parked = 0
    /// The session under the cursor sits in the parked group (parked, done, idle or exited).
    public var onParked = false
    /// The session under the cursor is blocked or asking.
    public var needsYou = false
    /// Items picked (space) in the current view.
    public var picked = 0
    public var unread = 0
    /// Attention's filter (`needs`, `muted`, ...).
    public var attentionFilter = ""
    /// The open PR's feedback items by stage, and deliveries waiting for an idle agent.
    public var queued = 0
    public var sent = 0
    public var waiting = 0
    /// Where the diff overlay is: its file and row.
    public var diffFile = 0
    public var diffRow = 0
    /// The diff overlay's comment box is open (`diff.ask`).
    public var diffNoteOpen = false
    public var historyOutcome = ""
    /// The Watch view: tracked PRs paused, with merging on, and whether a merge queue is in the middle.
    public var paused = 0
    public var merging = 0
    public var mergeQueue = false
    /// The pilot's explainer (`pilot.why`) is open; tracked PRs heed watches.
    public var explainOpen = false
    public var watching = 0
    /// The call log's filters: the kind shown (`""` for all), and whether only failed calls show.
    public var logKind = ""
    public var logFailed = false
    /// Goals: how many there are, which pane shows (`overview`, `doc`), and where j k move (`goals`, `links`).
    public var goals = 0
    public var goalPane = "overview"
    public var goalFocus = "goals"
    /// The goal under the cursor: its items, its GOAL.md changes waiting, and cards moved by hand so far.
    public var goalItems = 0
    public var goalProposals = 0
    public var goalMoves = 0
    public var goalSelected = ""
    /// heed's open goal asks (Unassigned, Attention).
    public var goalAsks = 0

    public init() {}
}

/// The fake worlds lessons run in. Each is fixture data: nothing in it is real, nothing done there is kept.
public enum TutorWorld: String, CaseIterable, Sendable {
    case mondayMorning, prStorm, freshRepos

    public var title: String {
        switch self {
        case .mondayMorning: "Monday morning"
        case .prStorm: "PR storm"
        case .freshRepos: "Fresh repos"
        }
    }

    public var summary: String {
        switch self {
        case .mondayMorning: "5 agents, 2 PRs, one blocked on a permission"
        case .prStorm: "review comments and a failing check land while the agent is busy"
        case .freshRepos: "your repos, no sessions yet"
        }
    }

    public var domain: Domain {
        switch self {
        case .mondayMorning: Fixtures.main
        case .prStorm: Fixtures.prStorm
        case .freshRepos: Fixtures.freshRepos
        }
    }

    public var next: TutorWorld {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// One thing to do. `say` and `keys` take `{command}` placeholders, drawn as that command's key in your keymap
/// (`{view.inbox}` → `gm`); anything else in `keys` is shown as written.
public struct TutorStep: Sendable {
    public let title: String
    public let say: String
    public let keys: [String]
    /// The part of the window the spotlight keeps lit (a screenshot region name: `sidebar`, `panes`…), when on screen.
    public let target: String?
    /// What changed, in one line, shown when the step is done.
    public let doneLine: String
    /// Whether the step is done: the state when it began, now, and every state seen in between (now included).
    public let done: @Sendable (_ start: TutorState, _ now: TutorState, _ seen: [TutorState]) -> Bool

    public init(
        _ title: String, say: String, keys: [String], target: String? = nil, doneLine: String,
        done: @escaping @Sendable (_ start: TutorState, _ now: TutorState, _ seen: [TutorState]) -> Bool
    ) {
        self.title = title
        self.say = say
        self.keys = keys
        self.target = target
        self.doneLine = doneLine
        self.done = done
    }
}

public struct TutorLesson: Sendable, Identifiable {
    /// `tour`, or the view it teaches: `sessions`, `start-work`, `inbox`…
    public let id: String
    public let title: String
    public let minutes: Int
    public let world: TutorWorld
    public let steps: [TutorStep]
    /// config.toml laid over the defaults in the lesson's world, for what is off until you turn it on.
    public var config = ""

    public var isTour: Bool { id == "tour" }
}

/// Heed's vimtutor: the real app on a fake world, one step at a time. A step says one sentence, the spotlight lights
/// what it is about, you press the real keys, and it ticks off when the state shows it was done. A value: the app feeds
/// it states, the view draws it.
public struct Tutor: Sendable {
    public enum Event: Equatable, Sendable {
        case none
        /// The step is done; the next began (or the lesson finished).
        case advanced
        /// A key that did not do the step: a nudge, never a block.
        case nudged
    }

    public let lesson: TutorLesson
    public private(set) var step = 0
    /// The line of the step just done, until the next key: the card shows it green.
    public private(set) var justDone: String?
    /// A wrong key's nudge, until the next key.
    public private(set) var nudge: String?
    public private(set) var hintsUsed = 0
    public let startedAt: Date
    /// The state when the current step began, and every state since.
    private var start: TutorState
    private var seen: [TutorState] = []

    public init(lesson: TutorLesson, step: Int = 0, state: TutorState = TutorState(), now: Date = Date()) {
        self.lesson = lesson
        self.step = min(max(step, 0), lesson.steps.count)
        start = state
        startedAt = now
    }

    public var current: TutorStep? { lesson.steps.indices.contains(step) ? lesson.steps[step] : nil }
    public var finished: Bool { step >= lesson.steps.count }

    /// Feeds the state after a key. `key` is what was pressed (`j`), nil when nothing was; `pending` says the key
    /// began a longer one (`g` of `ga`), which is not a wrong key yet.
    @discardableResult
    public mutating func observe(_ state: TutorState, key: String? = nil, pending: Bool = false) -> Event {
        guard let current else { return .none }
        if key != nil {
            justDone = nil
            nudge = nil
        }
        let previous = seen.last ?? start
        seen.append(state)
        if current.done(start, state, seen) {
            justDone = current.doneLine
            advance(from: state)
            return .advanced
        }
        // Only a key that changed nothing earns a nudge: wandering (moving around, opening things) is allowed.
        guard let key, !pending, state == previous else { return .none }
        nudge = "That was \(key)."
        return .nudged
    }

    /// `:skip`: the step counts as done without doing it.
    public mutating func skip(from state: TutorState) {
        guard !finished else { return }
        justDone = nil
        nudge = nil
        advance(from: state)
    }

    /// `:back` on a step already as it began: the step again from `state` (the app puts the world back first).
    public mutating func restart(at state: TutorState) {
        justDone = nil
        nudge = nil
        start = state
        seen = []
    }

    /// The nudge, with what to press instead after it.
    public func withNudge(_ hint: String?) -> Tutor {
        var copy = self
        if let hint, let nudge { copy.nudge = "\(nudge) \(hint)" }
        return copy
    }

    /// `:back` on a step not yet touched: the previous step again (the app puts the world back as it was then).
    public mutating func back(to state: TutorState) {
        step = max(step - 1, 0)
        justDone = nil
        nudge = nil
        start = state
        seen = []
    }

    /// The card showed the keys a while without them being pressed.
    public mutating func noteHint() { hintsUsed += 1 }

    private mutating func advance(from state: TutorState) {
        step += 1
        start = state
        seen = []
    }

    /// Every key the lesson taught, for the finish card: placeholders still in.
    public var keysTaught: [String] {
        var keys: [String] = []
        for key in lesson.steps.flatMap(\.keys) where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }
}

/// Which lessons are done, and where one was left: kept between launches so quitting mid-lesson resumes on the same
/// step. Only this is kept; the fake world never is.
public struct TutorProgress: Codable, Equatable, Sendable {
    public var done: Set<String> = []
    public var lastLesson: String?
    public var lastStep = 0
    /// Lessons whose title bar reminder was hidden (`tutor.hide`); `all` hides every one.
    public var hidden: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case done, lastLesson, lastStep, hidden }

    /// Progress saved before reminders still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        done = try container.decodeIfPresent(Set<String>.self, forKey: .done) ?? []
        lastLesson = try container.decodeIfPresent(String.self, forKey: .lastLesson)
        lastStep = try container.decodeIfPresent(Int.self, forKey: .lastStep) ?? 0
        hidden = try container.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
    }

    /// The title bar's gentle reminder, for the view you are on: finish a lesson left halfway, else take the tour,
    /// else this view's lesson. Nil once they are done or hidden.
    public func reminder(view: String) -> TutorReminder? {
        guard !hidden.contains("all") else { return nil }
        func open(_ id: String) -> Bool { !done.contains(id) && !hidden.contains(id) }
        if let last = lastLesson, lastStep > 0, open(last), let lesson = Tutor.lesson(last) {
            return TutorReminder(
                lesson: last,
                text: "Resume the \(lesson.isTour ? "tour" : lesson.title) · \(lastStep + 1)/\(lesson.steps.count)"
            )
        }
        if open(Tutor.tour.id) {
            return TutorReminder(lesson: Tutor.tour.id, text: "Take the tour")
        }
        let own = Tutor.lessonID(forView: view)
        if own != Tutor.tour.id, open(own), let lesson = Tutor.lesson(own) {
            return TutorReminder(lesson: own, text: "\(lesson.title) lesson")
        }
        return nil
    }

    /// The step to resume `lesson` on: where it was left, if it was left unfinished.
    public func resumeStep(_ lesson: String) -> Int { lesson == lastLesson ? lastStep : 0 }
}

/// What the title bar suggests: a lesson, and a few words.
public struct TutorReminder: Equatable, Sendable {
    public let lesson: String
    public let text: String
}

/// `:tutor`: the lessons to pick from. The first row is always the view you are on, then the tour, every other view,
/// and the last lesson again.
public struct TutorPicker: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        case lesson(String)
        case replay(String)
    }

    public let rows: [Row]
    /// The "views" heading goes before this row.
    public let viewsStart = 2
    public private(set) var cursor = 0
    /// A world picked with `w`; nil runs each lesson in its own.
    public private(set) var world: TutorWorld?

    public enum Outcome: Equatable, Sendable {
        case handled
        case cancel
        case start(lesson: String, world: TutorWorld?)
    }

    public init(view: String, progress: TutorProgress) {
        let own = Tutor.lessonID(forView: view)
        var rows: [Row] = [.lesson(own)]
        if own != Tutor.tour.id { rows.append(.lesson(Tutor.tour.id)) }
        rows += Tutor.viewLessons.map(\.id).filter { $0 != own }.map { .lesson($0) }
        if let last = progress.lastLesson { rows.append(.replay(last)) }
        self.rows = rows
    }

    /// j k (or ⌃n ⌃p, arrows) move, ↩ starts, w changes the world, ⎋ closes.
    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case KeyStroke("j"), KeyStroke("n", .control), KeyStroke("Down"):
            cursor = min(cursor + 1, rows.count - 1)
        case KeyStroke("k"), KeyStroke("p", .control), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("w"):
            world = selectedWorld.next
        case KeyStroke("CR"):
            switch rows[cursor] {
            case let .lesson(id), let .replay(id): return .start(lesson: id, world: world)
            }
        case .escape, KeyStroke("q"):
            return .cancel
        default:
            break
        }
        return .handled
    }

    public mutating func select(_ index: Int) {
        cursor = min(max(index, 0), rows.count - 1)
    }

    public var selectedLesson: TutorLesson? {
        switch rows[cursor] {
        case let .lesson(id), let .replay(id): Tutor.lesson(id)
        }
    }

    /// The world the selected lesson would run in.
    public var selectedWorld: TutorWorld { world ?? selectedLesson?.world ?? .mondayMorning }
}

public extension Tutor {
    static func lesson(_ id: String) -> TutorLesson? {
        id == tour.id ? tour : viewLessons.first { $0.id == id }
    }

    /// The lesson for a view (`sessions`, `prs`…); the tour for one without its own.
    static func lessonID(forView view: String) -> String {
        viewLessons.contains { $0.id == view } ? view : tour.id
    }

    /// `:tutor <name>`: a lesson id, a view's name, or `tour`.
    static func lessonID(named name: String) -> String? {
        let key = name.lowercased()
        let aliases = [
            "start": "start-work", "startwork": "start-work", "work": "start-work", "pr": "prs", "pulls": "prs",
            "worktrees": "repos", "global": "tour",
        ]
        let id = aliases[key] ?? key
        return lesson(id) == nil ? nil : id
    }
}
