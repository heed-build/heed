import Foundation

/// The tutor's lessons: a global tour (the default first run) and one per view. Every key in them is a real binding,
/// written as `{command}` so the card shows the key you have it on.
public extension Tutor {
    /// Nine steps, about six minutes: the modes, moving, and the five things you do all day.
    static let tour = TutorLesson(id: "tour", title: "Global tour", minutes: 6, world: .mondayMorning, steps: [
        TutorStep(
            "Two modes",
            say: "Keys belong to heed until you press {mode.insert}: then they go to the agent's pane, outlined white. ⇧⎋ brings them back.",
            keys: ["{mode.insert}", "⇧⎋"], target: "panes",
            doneLine: "In and out of INSERT: the only mode switch you need all day."
        ) { _, now, seen in seen.contains { $0.mode == .insert } && now.mode == .normal },
        TutorStep(
            "Move around",
            say: "Lists move like vim. {row.next} and {row.prev} step, and a count repeats: 2{row.next} moves two.",
            keys: ["{row.next}", "{row.prev}", "2{row.next}"], target: "sidebar",
            doneLine: "The numbers beside the rows are counts: the number you see is how far a row is."
        ) { start, now, _ in now.cursor - start.cursor >= 2 },
        TutorStep(
            "Pins",
            say: "Pinned sessions stay on top with a number, and '1 to '9 jump straight to one from anywhere. Press '2.",
            keys: ["{pin.jump 2}"], target: "sidebar",
            doneLine: "On your second pin. {session.pin} pins or unpins the session under the cursor."
        ) { _, now, _ in now.pinned == 2 },
        TutorStep(
            "Needs you",
            say: "Codex has been waiting on a question. It sits under NEEDS YOU. From anywhere:",
            keys: ["{session.attention}"], target: "needsYou",
            doneLine: "On the session that needs you. {session.attention} again goes to the next one."
        ) { _, now, _ in now.needsYou },
        TutorStep(
            "Start work",
            say: "{work.start} opens Start work: describe the task, heed picks the repo and names the branch. Type anything, then ⌘↩.",
            keys: ["{work.start}", "⌘↩"], target: "dialog",
            doneLine: "A new session in a new worktree. Here nothing real starts; normally you would be typing to it."
        ) { start, now, _ in now.sessions > start.sessions },
        TutorStep(
            "Panes",
            say: "A session's terminals are panes in tabs. {pane.split.right} splits the pane, {tab.next} goes to the next tab.",
            keys: ["{pane.split.right}", "{tab.next}"], target: "panes",
            doneLine: "Split. {pane.left} and {pane.right} move between panes; {pane.close} closes one."
        ) { start, now, _ in now.panes > start.panes },
        TutorStep(
            "Views",
            say: "Each view is g and a letter: {view.inbox} Inbox, {view.issues} Issues, {view.prs} PRs, {view.repos} Repos. Visit two, then {view.sessions} comes home.",
            keys: ["{view.inbox}", "{view.prs}", "{view.sessions}"], target: "viewTabs",
            doneLine: "Views stay where you left them: switching back finds the same row."
        ) { _, now, seen in Set(seen.map(\.view)).count >= 3 && now.view == "sessions" },
        TutorStep(
            "Command line",
            say: "{session.filter} filters the view you are in; {mode.command} runs any command by name, ⇥ completes it. Open each once, ⎋ closes.",
            keys: ["{session.filter}", "{mode.command}"], target: "statusBar",
            doneLine: "Both live in the status bar, so the view stays in sight while you type."
        ) { _, now, seen in
            seen.contains(where: \.filtering) && seen.contains(where: \.commandLine) && !now.filtering
                && !now.commandLine
        },
        TutorStep(
            "Keys and tutor",
            say: "{overlay.help} shows every key in the mode you are in. On it, t starts the lesson for the view you are on.",
            keys: ["{overlay.help}", ":tutor"],
            doneLine: "That is the tour. Every view has a lesson of its own: :tutor picks one."
        ) { _, _, seen in seen.contains(where: \.helpOpen) },
    ])

    /// One per view, two to four minutes. `:tutor` inside a view starts its lesson.
    static let viewLessons: [TutorLesson] = [
        TutorLesson(id: "sessions", title: "Sessions", minutes: 3, world: .mondayMorning, steps: [
            TutorStep(
                "Read the sidebar groups",
                say: "Sessions group by what they need: pinned, needs you, working, parked. {group.next} jumps a group at a time; get to a parked one.",
                keys: ["{group.next}", "{row.next}"], target: "sidebar",
                doneLine: "Parked sessions wait at the bottom and never ask for attention."
            ) { _, now, _ in now.onParked },
            TutorStep(
                "Pin and jump",
                say: "{session.pin} pins the session under the cursor; '1 then jumps to your first pin from anywhere.",
                keys: ["{session.pin}", "{pin.jump 1}"], target: "sidebar",
                doneLine: "Pins are numbered in order, and pinned worktrees are never cleaned up."
            ) { start, now, seen in seen.contains { $0.pins != start.pins } && now.pinned == 1 },
            TutorStep(
                "Split a pane",
                say: "{pane.split.right} puts a shell beside the agent, in the same worktree.",
                keys: ["{pane.split.right}"], target: "panes",
                doneLine: "Split. {pane.zoom} zooms one pane, {pane.close} closes it."
            ) { start, now, _ in now.panes > start.panes },
            TutorStep(
                "Filter",
                say: "{session.filter} and type mer: only sessions matching every word stay. ↩ keeps the filter.",
                keys: ["{session.filter}", "↩"], target: "statusBar",
                doneLine: "The pill shows the filter; {session.filter} then ⎋ clears it."
            ) { _, now, _ in !now.filtering && !now.filter.isEmpty },
        ]),
        TutorLesson(id: "start-work", title: "Start work", minutes: 3, world: .freshRepos, steps: [
            TutorStep(
                "Describe the task",
                say: "{work.start}, then say what you want done, as you would to a colleague.",
                keys: ["{work.start}"], target: "dialog",
                doneLine: "heed guessed the repo and named the branch from your words."
            ) { _, now, _ in now.startWorkOpen && now.startWorkPrompt.count >= 8 },
            TutorStep(
                "Change the guess",
                say: "Each guess shows why. ⌃n tries the next one; ⎋ then j reaches the repo field to pick by hand.",
                keys: ["⌃n"], target: "dialog",
                doneLine: "Another repo. Space on the repo field adds a second one for a cross-repo session."
            ) { start, now, _ in now.startWorkOpen && now.startWorkRepo != start.startWorkRepo },
            TutorStep(
                "Start",
                say: "The line at the bottom is the exact command heed runs. ⌘↩ starts it.",
                keys: ["⌘↩"], target: "dialog",
                doneLine: "A worktree, a branch and the agent with your prompt, in one key."
            ) { start, now, _ in now.sessions > start.sessions },
        ]),
        TutorLesson(id: "inbox", title: "Inbox", minutes: 2, world: .prStorm, steps: [
            TutorStep(
                "Open one",
                say: "{open.reader} reads the item under the cursor without leaving heed; ⎋ closes it.",
                keys: ["{open.reader}", "⎋"], target: "list",
                doneLine: "Read in place. {open.browser} opens it on GitHub instead."
            ) { _, now, seen in seen.contains { $0.overlay != nil } && now.overlay == nil },
            TutorStep(
                "Select several",
                say: "Space picks the item under the cursor. Pick two.",
                keys: ["␣", "{row.next}", "␣"], target: "list",
                doneLine: "Picked items act together: {items.start} makes them one session's prompt."
            ) { _, now, _ in now.picked >= 2 },
            TutorStep(
                "Dismiss together",
                say: "{items.read} marks everything picked as read.",
                keys: ["{items.read}"], target: "list",
                doneLine: "Read, here and on GitHub."
            ) { start, now, _ in now.unread < start.unread },
        ]),
        TutorLesson(id: "issues", title: "Issues", minutes: 2, world: .mondayMorning, steps: [
            TutorStep(
                "Find one",
                say: "{session.filter} filters issues like everything else: type a word from a title, ↩ keeps it.",
                keys: ["{session.filter}", "↩"], target: "statusBar",
                doneLine: "Every word you type must match somewhere in the row."
            ) { _, now, _ in !now.filtering && !now.filter.isEmpty },
            TutorStep(
                "Start work from it",
                say: "{items.start} turns the issue under the cursor into Start work, the issue as the prompt.",
                keys: ["{items.start}"], target: "dialog",
                doneLine: "The prompt links the issue, so the PR closes it."
            ) { _, now, _ in now.startWorkOpen && !now.startWorkPrompt.isEmpty },
            TutorStep(
                "Read it first",
                say: "⎋ twice closes Start work. {open.reader} reads the issue in heed.",
                keys: ["⎋", "{open.reader}"], target: "reader",
                doneLine: "From the reader, {items.start} starts work too."
            ) { _, now, _ in now.overlay == "issue" },
        ]),
        TutorLesson(id: "prs", title: "PRs", minutes: 4, world: .prStorm, steps: [
            TutorStep(
                "Open the overlay",
                say: "{open.reader} opens the PR under the cursor: its checks, and the feedback heed collected from it.",
                keys: ["{open.reader}"], target: "reader",
                doneLine: "Review comments and failing checks are items: New, Queued, Sent, Addressed, Resolved."
            ) { _, now, _ in now.overlay == "reader" || now.overlay == "pr" },
            TutorStep(
                "Queue feedback",
                say: "Space queues the item under the cursor for the agent; {row.next} moves.",
                keys: ["␣"], target: "reader",
                doneLine: "Queued items go to the agent as one prompt."
            ) { start, now, _ in now.queued > start.queued },
            TutorStep(
                "Send when idle",
                say: "{feedback.send} sends what is queued. The agent is busy, so it waits until it is idle.",
                keys: ["{feedback.send}"], target: "reader",
                doneLine: "It goes the moment the agent stops. Auto when idle ({feedback.mode}) does this by itself."
            ) { start, now, _ in now.sent > start.sent || now.waiting > start.waiting },
            TutorStep(
                "Watch CI come back",
                say: "After the agent pushes, a failed check resolves on its own when it passes, and heed says so. ⎋ closes.",
                keys: ["⎋"],
                doneLine: "It stops after three rounds without progress. Nobody gets nagged forever."
            ) { _, now, _ in now.overlay == nil },
        ]),
        TutorLesson(id: "repos", title: "Repos", minutes: 3, world: .mondayMorning, steps: [
            TutorStep(
                "Read the table",
                say: "Every worktree of every repo, with its session, PR and status. {row.next} walks it.",
                keys: ["{row.next}"], target: "worktreeTable",
                doneLine: "Repos with more worktrees come first."
            ) { start, now, _ in now.cursor - start.cursor >= 2 },
            TutorStep(
                "Create one",
                say: "{worktree.new} starts work in the repo under the cursor. ⎋ twice closes it.",
                keys: ["{worktree.new}", "⎋"], target: "dialog",
                doneLine: "Start work, with the repo already picked."
            ) { _, now, seen in seen.contains(where: \.startWorkOpen) && !now.startWorkOpen },
            TutorStep(
                "Removing asks first",
                say: "dd removes the worktree under the cursor, and asks first: n keeps it.",
                keys: ["dd", "n"], target: "confirm",
                doneLine: "Nothing is removed until you say y, and the dialog names what goes."
            ) { _, now, seen in seen.contains(where: \.confirmationOpen) && !now.confirmationOpen },
        ]),
        TutorLesson(id: "history", title: "History", minutes: 2, world: .mondayMorning, steps: [
            TutorStep(
                "Pick one",
                say: "Sessions that ended, newest first. {row.next} moves to an older one.",
                keys: ["{row.next}"], target: "historyList",
                doneLine: "Each keeps its prompt, branch, PRs and how it ended."
            ) { start, now, _ in now.cursor > start.cursor },
            TutorStep(
                "Filter by outcome",
                say: "{history.outcome} shows one outcome at a time: merged, closed, abandoned, cleaned up.",
                keys: ["{history.outcome}"], target: "historyList",
                doneLine: "{history.outcome} again cycles on."
            ) { start, now, _ in now.historyOutcome != start.historyOutcome },
            TutorStep(
                "Reopen it",
                say: "{history.reopen} brings the session back: its worktree, and its agent resuming where it was.",
                keys: ["{history.reopen}"], target: "historyList",
                doneLine: "Back in Sessions. {history.again} starts the same prompt fresh instead."
            ) { start, now, _ in now.sessions > start.sessions },
        ]),
        TutorLesson(id: "agents", title: "Agents", minutes: 3, world: .mondayMorning, steps: [
            TutorStep(
                "Read the states",
                say: "Each glyph is an agent's state: working, idle, blocked, asking, done. {session.attention} goes to one that needs you.",
                keys: ["{session.attention}"], target: "sidebar",
                doneLine: "Agents report through hooks; a dotted ring means heed read the screen instead."
            ) { _, now, _ in now.needsYou },
            TutorStep(
                "Answer it",
                say: "{mode.insert} types into its agent, as in any terminal. ⇧⎋ comes back.",
                keys: ["{mode.insert}", "⇧⎋"], target: "panes",
                doneLine: "Clicking a pane enters INSERT on it too."
            ) { _, now, seen in seen.contains { $0.mode == .insert } && now.mode == .normal },
            TutorStep(
                "Park what can wait",
                say: "Move to the working session, the one with the spinner, and press {session.park}: parked, it waits at the bottom.",
                keys: ["{session.park}"], target: "sidebar",
                doneLine: "{session.park} again brings it back. A session that needs you stays in sight even parked."
            ) { start, now, _ in now.parked > start.parked },
        ]),
        TutorLesson(id: "diff", title: "Diff", minutes: 2, world: .mondayMorning, steps: [
            TutorStep(
                "Open the overlay",
                say: "{overlay.diff} shows what the session changed: committed, staged and unstaged.",
                keys: ["{overlay.diff}"], target: "diffBody",
                doneLine: "⇥ switches between committed, staged and unstaged."
            ) { _, now, _ in now.overlay == "diff" },
            TutorStep(
                "Hunk by hunk",
                say: "{diff.hunk.next} jumps to the next hunk, {diff.hunk.prev} back.",
                keys: ["{diff.hunk.next}", "{diff.hunk.prev}"], target: "diffBody",
                doneLine: "{diff.file.next} and {diff.file.prev} move between files."
            ) { start, now, _ in now.diffRow != start.diffRow || now.diffFile != start.diffFile },
            TutorStep(
                "Send a note back",
                say: "{diff.ask} starts a message to the agent about the hunk under the cursor.",
                keys: ["{diff.ask}"],
                doneLine: "You are typing to the agent, the file and line already said. ⇧⎋ comes back."
            ) { _, now, seen in seen.contains { $0.mode == .insert } || now.mode == .insert },
        ]),
    ]
}
