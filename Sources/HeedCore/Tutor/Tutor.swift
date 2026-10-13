import Foundation

/// What the tutor can see of the app after each key: enough to tell whether a step was done, nothing more.
public struct TutorState: Equatable, Sendable {
    public var mode: Mode = .normal
    /// `sessions`, `inbox`, `issues`, `prs`, `repos`, `history`.
    public var view = "sessions"
    /// The row the cursor is on in the current view's list.
    public var cursor = 0
    public var rows = 0
    /// `pr`, `diff`, `reader`, `issue`, or nil.
    public var overlay: String?
    public var filtering = false
    public var filter = ""
    public var focusedPane = 0
    public var panes = 0
    public var tab = 0
    public var tabs = 0
    public var startWorkOpen = false
    public var confirmationOpen = false
    public var importOpen = false
    public var commandLine = false
    public var helpOpen = false
    public var sessions = 0

    public init() {}
}

/// One thing to do: what to press, and how to know it was done (given the state when the step began and now).
public struct TutorStep: Sendable {
    /// Text with `{command}` placeholders, drawn as that command's key in your keymap (`{view.inbox}` → `gm`).
    public let instruction: String
    public let done: @Sendable (_ start: TutorState, _ now: TutorState) -> Bool

    public init(_ instruction: String, done: @escaping @Sendable (_ start: TutorState, _ now: TutorState) -> Bool) {
        self.instruction = instruction
        self.done = done
    }
}

public struct TutorLesson: Sendable {
    public let title: String
    /// Why this matters, in a sentence or two; same placeholders as steps.
    public let intro: String
    public let steps: [TutorStep]
}

/// Heed's vimtutor: lessons done for real in a sandbox (the app on fixture data), each step ticking off when the
/// state shows it was done. A value: the app feeds it states, the view draws it.
public struct Tutor: Sendable {
    public let lessons: [TutorLesson]
    public private(set) var lesson = 0
    public private(set) var step = 0
    /// The state when the current step began, for steps that compare (moved down, changed view).
    private var start = TutorState()

    public init(lessons: [TutorLesson] = Tutor.lessons, lesson: Int = 0, state: TutorState = TutorState()) {
        self.lessons = lessons
        self.lesson = min(max(lesson, 0), max(lessons.count - 1, 0))
        start = state
    }

    public var current: TutorLesson { lessons[lesson] }
    /// Every step of the current lesson is done.
    public var lessonDone: Bool { step >= current.steps.count }
    public var finished: Bool { lesson == lessons.count - 1 && lessonDone }

    /// Feeds the state after a key; returns true when that finished a step.
    @discardableResult
    public mutating func observe(_ state: TutorState) -> Bool {
        guard !lessonDone else { return false }
        guard current.steps[step].done(start, state) else { return false }
        step += 1
        start = state
        return true
    }

    public mutating func next(from state: TutorState) {
        guard lesson < lessons.count - 1 else { return }
        lesson += 1
        step = 0
        start = state
    }

    public mutating func previous(from state: TutorState) {
        lesson = max(lesson - 1, 0)
        step = 0
        start = state
    }
}

public extension Tutor {
    /// The lessons, in order. The first is about getting around: the views and switching between them.
    static let lessons: [TutorLesson] = [
        TutorLesson(
            title: "Views, and getting around",
            intro: """
            Heed has six views, named along the top. Each has a key starting with g: press g and wait, and the panel \
            at the bottom lists every key that can follow. This window is a sandbox on made-up data: nothing you do \
            here touches your real sessions.
            """,
            steps: [
                TutorStep("Press {view.inbox} to open the Inbox: notifications from GitHub.") { _, now in
                    now.view == "inbox"
                },
                TutorStep("Press {view.issues} for Issues: the ones assigned to you or mentioning you.") { _, now in
                    now.view == "issues"
                },
                TutorStep("Press {view.prs} for your pull requests.") { _, now in now.view == "prs" },
                TutorStep("Press {view.repos} for Repos: every worktree of every repo Heed knows.") { _, now in
                    now.view == "repos"
                },
                TutorStep("Press {view.history} for History: sessions that ended.") { _, now in
                    now.view == "history"
                },
                TutorStep(
                    "Press g on its own and look at the panel at the bottom; then press {view.sessions}."
                ) { _, now in now.view == "sessions" },
            ]
        ),
        TutorLesson(
            title: "Moving in a list",
            intro: """
            Every list moves the same way, vim-style: j and k, gg and G, and a count in front repeats a move. The \
            numbers beside rows are relative, so the count to reach a row is the number you see.
            """,
            steps: [
                TutorStep("Press {row.next} to move down.") { start, now in now.cursor > start.cursor },
                TutorStep("Press {row.prev} to move up.") { start, now in now.cursor < start.cursor },
                TutorStep("Press {row.last} to jump to the last session.") { _, now in
                    now.rows > 0 && now.cursor == now.rows - 1
                },
                TutorStep("Press {row.first} to jump back to the first.") { _, now in now.cursor == 0 },
                TutorStep("Press 3 then {row.next}: three rows down in one go.") { start, now in
                    now.cursor - start.cursor >= 3 || (now.rows <= 3 && now.cursor == now.rows - 1)
                },
            ]
        ),
        TutorLesson(
            title: "Typing into an agent",
            intro: """
            Keys are Heed's until you enter INSERT: then they go to the focused pane, outlined white. Clicking a pane \
            enters INSERT on it too.
            """,
            steps: [
                TutorStep("Press {mode.insert} to enter INSERT.") { _, now in now.mode == .insert },
                TutorStep("Press ⇧⎋ to leave it (⌃\\ works too).") { _, now in now.mode == .normal },
            ]
        ),
        TutorLesson(
            title: "Panes and tabs",
            intro: "A session's terminals are panes in tabs. ⌃w starts the pane keys, as in vim.",
            steps: [
                TutorStep("Press {pane.split.right} to split the pane.") { start, now in now.panes > start.panes },
                TutorStep("Press {pane.left} and {pane.right} to move between panes.") { start, now in
                    now.focusedPane != start.focusedPane
                },
                TutorStep("Press {tab.next} for the next tab.") { start, now in
                    now.tab != start.tab || now.tabs <= 1
                },
            ]
        ),
        TutorLesson(
            title: "Jumping with hints",
            intro: "f labels everything you can jump to in the view; type a label to go there. F also opens it.",
            steps: [
                TutorStep("Press {mode.hint} and look at the labels.") { _, now in now.mode == .hint },
                TutorStep("Type one of the labels to jump there.") { _, now in now.mode != .hint },
            ]
        ),
        TutorLesson(
            title: "Filtering",
            intro: """
            / filters the view you are in. You type in the status bar; the view shows the filter as a pill. Every \
            word must match somewhere.
            """,
            steps: [
                TutorStep("Press {session.filter} and type docs.") { _, now in
                    now.filtering && now.filter.lowercased().contains("docs")
                },
                TutorStep("Press ↩ to keep it.") { _, now in !now.filtering && !now.filter.isEmpty },
                TutorStep("Press {session.filter} then ⎋ to clear it.") { _, now in
                    !now.filtering && now.filter.isEmpty
                },
            ]
        ),
        TutorLesson(
            title: "Starting work",
            intro: """
            {work.start} opens Start work: describe the task, and Heed picks the repo, names the branch and starts \
            the agent in a new worktree. In the sandbox nothing starts.
            """,
            steps: [
                TutorStep("Press {work.start}.") { _, now in now.startWorkOpen },
                TutorStep("Type a task, then ⎋ to stop typing and ⎋ again to close it.") { _, now in
                    !now.startWorkOpen
                },
            ]
        ),
        TutorLesson(
            title: "The command line",
            intro: "Every command has a name; : runs one by name, and ⇥ completes it.",
            steps: [
                TutorStep("Press {mode.command}, type view and press ⇥ to see it complete.") { _, now in
                    now.commandLine
                },
                TutorStep("Press ⎋ to close the command line.") { _, now in !now.commandLine },
            ]
        ),
        TutorLesson(
            title: "Destructive things ask first",
            intro: "Closing or deleting a session, removing worktrees and quitting with agents running all ask: y goes ahead, n cancels.",
            steps: [
                TutorStep("Press {session.close}.") { _, now in now.confirmationOpen },
                TutorStep("Press n to keep the session.") { _, now in !now.confirmationOpen },
            ]
        ),
        TutorLesson(
            title: "Bringing work in",
            intro: "Worktrees made outside Heed become sessions with an import; the agent session kept there resumes.",
            steps: [
                TutorStep("Press {session.import} to list worktrees Heed does not manage yet.") { _, now in
                    now.importOpen
                },
                TutorStep("Press ⎋ to close it. {session.import.path} imports any path the same way.") { _, now in
                    !now.importOpen
                },
            ]
        ),
        TutorLesson(
            title: "Outside the window",
            intro: """
            Heed works from anywhere: ⌃⌥Space opens Start work over any app, ⌃⌥H brings Heed forward, and the owl in \
            the menu bar shows what needs you. Those are global, so try them after the tutor.
            """,
            steps: [
                TutorStep("Press {overlay.help} to see every key; ⎋ closes it.") { start, now in
                    start.helpOpen != now.helpOpen && !now.helpOpen
                },
            ]
        ),
    ]
}
