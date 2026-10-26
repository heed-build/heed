import Foundation
import HeedCore

/// Goals: what each command does, through `GoalOps` (the one way goals change), and the new goal dialog and the GOAL.md
/// editor, which take the keyboard while they are open. Fixtures run the same operations on an in-memory store.
extension AppModel {
    /// At launch, before resume is offered: `goals.sqlite` and `goals/` beside the domain file.
    func startGoals(beside file: URL) async {
        let folder = file.deletingLastPathComponent()
        let ops = await GoalOps.open(
            at: folder.appendingPathComponent("goals.sqlite"),
            files: GoalFiles(root: folder.appendingPathComponent("goals"))
        )
        // Read before returning: the goal pointers are in place before any session resumes.
        await goals.attach(ops)
    }

    // MARK: Moving

    /// `goal.doc`: the GOAL.md pane, or back to the overview.
    func toggleGoalDoc() {
        if view != .goals {
            view = .goals
            goals.show(.doc)
        } else {
            goals.togglePane()
        }
        endGoalEditing()
    }

    /// `'g`: from a session to its goal, the session under the cursor there; in Goals, from a session back to the goal.
    func jumpToGoal() {
        if view == .goals {
            if let link = goals.selectedLink { goals.point(to: link.goal) }
            return
        }
        guard let session = currentSession else { return say("no session here") }
        guard let goal = goals.bySession[session.id] else {
            return say("\(session.title) is on no goal: :goal.attach puts it on one")
        }
        view = .goals
        goals.point(to: GoalLink(goal: goal.id, kind: GoalLink.kind(of: session), target: session.id, at: .now).key)
    }

    /// `↩` in Goals: from a goal to what is on it; on a session or chat, there.
    func openGoalRow() {
        guard view == .goals else { return }
        guard goals.focus == .links, let link = goals.selectedLink else {
            guard goals.selected != nil else { return say("no goal yet: n makes one") }
            if goals.links.isEmpty { return say("nothing is on this goal yet: 'g… :goal.attach from a session") }
            return goals.setFocus(.links)
        }
        if sessions.contains(where: { $0.id == link.target }) {
            view = .sessions
            select(sessionID: link.target)
        } else {
            say("that one is closed: History (gh) reopens it")
        }
    }

    func clickGoal(_ index: Int, open: Bool = false) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.goals)
        goals.setCursor(index)
        if open { goals.setFocus(.links) }
    }

    func clickGoalLink(_ index: Int, open: Bool = false) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.links)
        goals.setCursor(index)
        if open { openGoalRow() }
    }

    func goalMenu(_ index: Int) -> [MenuEntry] {
        guard goals.rows.indices.contains(index) else { return [] }
        let goal = goals.rows[index]
        return ContextMenus.goal(
            id: goal.id, title: goal.title, archived: goal.status == .archived, docShown: goals.pane == .doc,
            reviewersShown: goals.pane == .reviewers, done: goal.status == .done
        )
    }

    func goalLinkMenu(_ index: Int) -> [MenuEntry] {
        let links = goals.links
        guard links.indices.contains(index), let goal = goals.selected else { return [] }
        let link = links[index]
        let title = (sessions + history.map(\.session)).first { $0.id == link.target }?.title ?? link.target
        return ContextMenus.goalLink(key: link.key, title: title, goal: goal.title)
    }

    // MARK: Operations

    /// The session or chat a goal command acts on: what is under the cursor in Goals, else the current session.
    private var goalSubject: (kind: GoalLink.Kind, id: String, title: String)? {
        if view == .goals {
            guard let link = goals.selectedLink else { return nil }
            let title = (sessions + history.map(\.session)).first { $0.id == link.target }?.title ?? link.target
            return (link.kind, link.target, title)
        }
        return currentSession.map { (GoalLink.kind(of: $0), $0.id, $0.title) }
    }

    /// `goal.new`: in Goals, the dialog empty; on a session, filled from its prompt, and the session goes on the goal.
    /// With words, the goal is made at once with them as its title.
    func newGoal(_ words: [String], from target: CommandTarget?) {
        var session: Session?
        if case let .session(id) = target {
            session = sessions.first { $0.id == id }
        } else if view == .sessions {
            session = currentSession
        }
        let title = words.joined(separator: " ")
        guard title.isEmpty else {
            return createGoal(GoalsBrowser.Form(title: title, statement: session?.prompt ?? "", session: session?.id))
        }
        goals.form = GoalsBrowser.Form(
            title: session?.title ?? "", statement: session.map { GoalsBrowser.firstParagraph($0.prompt) } ?? "",
            session: session?.id
        )
        textInputActive = true
    }

    /// The dialog's ⌘↩ or Create.
    func submitGoalForm() {
        guard let form = goals.form else { return }
        guard !form.title.trimmingCharacters(in: .whitespaces).isEmpty else { return say("a goal needs a title") }
        goals.form = nil
        textInputActive = false
        createGoal(form)
    }

    func cancelGoalForm() {
        goals.form = nil
        textInputActive = false
    }

    private func createGoal(_ form: GoalsBrowser.Form) {
        let session = form.session.flatMap { id in sessions.first { $0.id == id } }
        let now = Clock.now
        goals.run { ops in
            let goal = try await ops.create(title: form.title, statement: form.statement, now: now)
            if let session {
                try await ops.attach(GoalLink(
                    goal: goal.id, kind: GoalLink.kind(of: session), target: session.id, at: now
                ))
            }
            return goal
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(goal):
                view = .goals
                goals.point(to: goal.id)
                say("goal \(goal.title) made" + (session.map { ", \($0.title) on it" } ?? ""))
                planGoal(goal: goal.id)
            case let .failure(error): say("no goal made: \(error)")
            }
        }
    }

    /// `goal.attach <goal>`: the session or chat onto it (from another goal it moves). No goal: the command line.
    func attachGoal(_ words: [String]) {
        guard let subject = goalSubject else { return say("no session here to put on a goal") }
        guard !words.isEmpty else { return openCommandLine("goal.attach ") }
        let query = words.joined(separator: " ")
        guard let goal = goals.snapshot.find(query) else {
            return say("no goal \(query): :goal.attach ⇥ lists them, n in Goals makes one")
        }
        let link = GoalLink(goal: goal.id, kind: subject.kind, target: subject.id, at: Clock.now)
        let titles = Dictionary(goals.snapshot.goals.map { ($0.id, $0.title) }) { first, _ in first }
        goals.run { ops in
            try await ops.attach(link)
        } done: { [weak self] result in
            switch result {
            case let .success(moved):
                let from = moved.map { ", no longer on \(titles[$0] ?? $0)" } ?? ""
                self?.say("\(subject.title) is on \(goal.title)\(from)")
            case let .failure(error): self?.say("not attached: \(error)")
            }
        }
    }

    /// `goal.detach`: the session or chat off its goal.
    func detachGoal() {
        guard let subject = goalSubject else { return say("no session here") }
        guard let goal = goals.bySession[subject.id] else { return say("\(subject.title) is on no goal") }
        goals.run { ops in
            try await ops.detach(kind: subject.kind, target: subject.id)
        } done: { [weak self] result in
            if case let .failure(error) = result { return self?.say("not taken off: \(error)") ?? () }
            self?.say("\(subject.title) is off \(goal.title)")
        }
    }

    /// `goal.archive`: the goal under the cursor archived, or an archived one back.
    func archiveGoal() {
        guard view == .goals, let goal = goals.selected else { return say("no goal here") }
        let now = Clock.now
        goals.run { ops in
            try await ops.archive(goal: goal.id, now: now)
        } done: { [weak self] result in
            switch result {
            case let .success(status): self?.say("\(goal.title) \(status == .archived ? "archived" : "brought back")")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    // MARK: GOAL.md

    /// `goal.edit`: GOAL.md in an editor in place; ⎋ or ⌘S saves it as a new version.
    func editGoal() {
        guard let goal = goals.selected else { return say("no goal here") }
        view = .goals
        goals.show(.doc)
        let current = goals.versions.first { $0.number == goal.version }?.text
            ?? goals.snapshot.docs[goal.id]?.render() ?? ""
        goals.draft = current
        textInputActive = true
    }

    func saveGoalDraft() {
        guard let draft = goals.draft, let goal = goals.selected else { return endGoalEditing() }
        endGoalEditing()
        let now = Clock.now
        let before = goals.snapshot.docs[goal.id]
        goals.run { ops in
            try await ops.save(goal: goal.id, text: draft, now: now)
        } done: { [weak self] result in
            switch result {
            case let .success(version):
                self?.say(version.map { "GOAL.md saved as v\($0.number)" } ?? "no change")
                self?.replanIfScopeChanged(goal.id, before: before)
            case let .failure(error): self?.say("not saved: \(error)")
            }
        }
    }

    func endGoalEditing() {
        guard goals.draft != nil else { return }
        goals.draft = nil
        textInputActive = false
    }

    /// `goal.restore <n>`: version n current again, saved as the newest. No number: the command line.
    func restoreGoal(_ words: [String]) {
        guard let goal = goals.selected else { return say("no goal here") }
        guard let number = words.first.flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) })
        else { return openCommandLine("goal.restore ") }
        let now = Clock.now
        goals.run { ops in
            try await ops.restore(goal: goal.id, version: number, now: now)
        } done: { [weak self] in
            switch $0 {
            case let .success(version):
                self?.say(version.map { "v\(number) restored as v\($0.number)" } ?? "v\(number) is what it says now")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    // MARK: Keys while typing

    /// Keys while the new goal dialog or the GOAL.md editor has the keyboard: the text field takes the rest.
    func answerGoalText(_ stroke: KeyStroke) -> Bool {
        if goals.form != nil {
            switch stroke {
            case .escape: cancelGoalForm()
            case KeyStroke("CR", .command), KeyStroke("s", .command): submitGoalForm()
            default: return false
            }
            return true
        }
        if goals.draft != nil {
            switch stroke {
            case .escape, KeyStroke("s", .command): saveGoalDraft()
            default: return false
            }
            return true
        }
        return false
    }

    /// The overview's numbers and lists for the goal under the cursor.
    func goalOverview(_ goal: HeedGoal) -> GoalOverview {
        GoalOverview.build(
            doc: goals.snapshot.docs[goal.id], links: goals.snapshot.links(of: goal.id), sessions: sessions,
            history: history, github: github, ledger: ledger.entries
        )
    }
}

extension GoalsBrowser {
    /// A prompt's first paragraph, for a goal's statement.
    static func firstParagraph(_ text: String) -> String {
        text.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
