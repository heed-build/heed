import Foundation

/// A goal made from Start work's prompt (Make it a goal on the sizing card): its title and statement, and the repos
/// the dialog had picked.
public struct StartGoal: Equatable, Sendable {
    public var title: String
    public var statement: String
    public var repos: [String]

    public init(title: String, statement: String, repos: [String] = []) {
        self.title = title
        self.statement = statement
        self.repos = repos
    }

    /// A title from the prompt when the model gave none: its first sentence, at most eight words.
    public static func title(from prompt: String) -> String {
        let first = prompt.split(whereSeparator: { ".\n:;!?".contains($0) }).first.map(String.init) ?? prompt
        let words = first.split(whereSeparator: \.isWhitespace)
        let title = words.prefix(8).joined(separator: " ")
        return GoalDoc.oneLine(title.prefix(1).uppercased() + title.dropFirst())
    }
}

/// Start work sizes a longer prompt (`[start_work] size_check`): bigger than one session shows a card in place of the
/// fields with three ways on: Make it a goal (⌘↩), Just a session (⌥↩), It's a question (⌃↩). Small tasks, chats and
/// promotions never see it, and the dialog keys work as before.
public extension StartWorkForm {
    /// The prompt to size now (`TaskSizer.key`), or nil: sizing is off, it is a chat or a promotion, or the prompt is
    /// short.
    var sizeQuestion: String? {
        guard sizeCheck, chat == nil, promotion == nil, TaskSizer.worthSizing(prompt) else { return nil }
        return TaskSizer.key(prompt)
    }

    /// The card shows: the last sizing said goal, the prompt is still a longer one, and it was not put away.
    var showsSizeCard: Bool {
        guard let sizing, sizing.kind == .goal, sizeQuestion != nil else { return false }
        return sizingSetAside != sizing.prompt
    }

    /// The goal Make it a goal makes: the model's title, else the prompt's first words.
    var startGoal: StartGoal {
        let title = sizing?.facts?.title ?? StartGoal.title(from: prompt)
        return StartGoal(
            title: title, statement: prompt.trimmingCharacters(in: .whitespacesAndNewlines), repos: selectedRepos
        )
    }

    /// The sizing of `key` arrived (nil: none could be had). Kept only for the prompt still current. When ⌘↩ was
    /// waiting for it, the work starts now unless the card shows.
    mutating func sized(_ sizing: TaskSizing?, for key: String) -> Outcome {
        guard key == sizeQuestion else { return .handled }
        sizedPrompt = key
        if let sizing { self.sizing = sizing }
        guard waitingForSize else { return .handled }
        waitingForSize = false
        if showsSizeCard { return .handled }
        return canStart ? .start(plan) : .handled
    }

    /// The card's keys: ⌘↩ a goal, ⌥↩ a session, ⌃↩ a chat; in NORMAL, `j`, `↓` or `⇥` put the card away for the
    /// fields. Nil: the key is the dialog's as usual (typing in the prompt goes on).
    internal mutating func answerSizeCard(_ stroke: KeyStroke) -> Outcome? {
        switch stroke {
        case KeyStroke("CR", .command):
            return .goal(startGoal)
        case KeyStroke("CR", .option):
            setSizingAside()
            guard canStart else { return .handled }
            return .start(plan)
        case KeyStroke("CR", .control):
            setSizingAside()
            setChat(true)
            guard canStart else { return .handled }
            return .start(plan)
        case KeyStroke("j"), KeyStroke("Down"):
            guard !editing else { return nil }
            setSizingAside()
            focus(field: fields.first { $0 != .prompt } ?? .repo)
            return .handled
        case KeyStroke("Tab"):
            // ⇥ moves on as always; the fields it moves to show.
            setSizingAside()
            return nil
        default:
            return nil
        }
    }

    /// The card goes away for this sizing; a later one for another prompt can bring it back.
    mutating func setSizingAside() {
        sizingSetAside = sizing?.prompt
    }
}
