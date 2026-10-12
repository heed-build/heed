import Foundation

/// The Start work dialog as a value: what is typed and picked, which field has focus, and what the keys do. The view
/// draws it; the app feeds it keys. design/screens/StartWork.png.
///
/// Like the app it has two modes: editing (INSERT: keys type into the prompt or the worktree name) and moving
/// (NORMAL: `j k` or `⇥` between fields, `h l` within one, `space` toggles). `⌃n ⌃p` cycle guesses in both,
/// `<D-CR>` starts, `<Esc>` stops editing and then cancels.
public struct StartWorkForm: Sendable {
    public enum Field: Int, CaseIterable, Sendable {
        case prompt, repo, worktree, agent, options
    }

    public enum Option: Int, CaseIterable, Sendable {
        case autostart, planFirst, shellSplit
    }

    public enum Outcome: Equatable, Sendable {
        case handled
        case start(StartWorkPlan)
        case cancel
        /// The key means nothing here (it is swallowed anyway: nothing behind the dialog reacts to it).
        case ignored
    }

    public private(set) var field: Field = .prompt
    public private(set) var editing = true
    public private(set) var prompt = ""
    public private(set) var name = ""
    public private(set) var guesses: [RepoGuess] = []
    /// Selected repo ids (`org/name`), in the order they were picked; the first is primary.
    public private(set) var selectedRepos: [String] = []
    /// The focused chip in the repo field.
    public private(set) var repoCursor = 0
    /// Agents to choose from; nil is "none, shell only".
    public let agents: [AgentProfile?]
    public private(set) var agentIndex = 0
    public private(set) var optionCursor = 0
    public private(set) var autostart = true
    public private(set) var planFirst = false
    public private(set) var shellSplit = true
    public private(set) var error: String?

    private let repos: [RepoRecord]
    private let history: [Session]
    private var nameEdited = false
    private var reposTouched = false

    public init(repos: [RepoRecord], history: [Session], settings: WorkSettings, prompt: String = "") {
        self.repos = repos
        self.history = history
        agents = settings.agents.map(Optional.some) + [nil]
        agentIndex = settings.agents.firstIndex { $0.name == settings.defaultAgent } ?? 0
        setPrompt(prompt)
    }

    // MARK: Derived

    public var agent: AgentProfile? { agents[agentIndex] }

    public var selectedRecords: [RepoRecord] {
        selectedRepos.compactMap { id in repos.first { $0.id == id } }
    }

    public var plan: StartWorkPlan {
        var plan = StartWorkPlan(prompt: prompt, repos: selectedRecords, name: name, agent: agent)
        plan.autostart = autostart && agent != nil
        plan.planFirst = planFirst
        plan.shellSplit = shellSplit
        return plan
    }

    public var canStart: Bool { !selectedRepos.isEmpty && !name.isEmpty }

    // MARK: Keys

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        error = nil
        if stroke == KeyStroke("CR", .command) {
            guard canStart else {
                error = selectedRepos.isEmpty ? "pick a repo first" : "name the worktree first"
                return .handled
            }
            return .start(plan)
        }
        if stroke == KeyStroke("n", .control) { return cycleGuess(by: 1) }
        if stroke == KeyStroke("p", .control) { return cycleGuess(by: -1) }
        if stroke.key == "Tab" {
            move(by: stroke.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        return editing ? edit(stroke) : navigate(stroke)
    }

    private mutating func edit(_ stroke: KeyStroke) -> Outcome {
        if stroke == .escape {
            editing = false
            return .handled
        }
        var text = field == .prompt ? prompt : name
        switch stroke {
        case KeyStroke("BS"):
            if !text.isEmpty { text.removeLast() }
        case KeyStroke("BS", .option), KeyStroke("w", .control):
            text = Self.deletingLastWord(text)
        case KeyStroke("u", .control):
            text = ""
        case KeyStroke("Space"):
            text += " "
        case KeyStroke("CR"):
            guard field == .prompt else {
                editing = false
                return .handled
            }
            text += "\n"
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return .ignored }
            text += stroke.key
        }
        if field == .prompt {
            setPrompt(text)
        } else {
            name = Self.branchSafe(text)
            nameEdited = true
        }
        return .handled
    }

    private mutating func navigate(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape:
            return .cancel
        case KeyStroke("j"), KeyStroke("Down"):
            move(by: 1)
        case KeyStroke("k"), KeyStroke("Up"):
            move(by: -1)
        case KeyStroke("h"), KeyStroke("Left"):
            moveWithin(by: -1)
        case KeyStroke("l"), KeyStroke("Right"):
            moveWithin(by: 1)
        case KeyStroke("i"), KeyStroke("a"), KeyStroke("CR"):
            if field == .prompt || field == .worktree { editing = true } else { toggle() }
        case KeyStroke("Space"):
            toggle()
        default:
            return .ignored
        }
        return .handled
    }

    /// Paste goes into whatever is being edited.
    public mutating func paste(_ text: String) {
        if field == .worktree {
            name = Self.branchSafe(name + text)
            nameEdited = true
        } else {
            field = .prompt
            editing = true
            setPrompt(prompt + text)
        }
    }

    // MARK: Editing state

    private mutating func move(by delta: Int) {
        let count = Field.allCases.count
        field = Field(rawValue: ((field.rawValue + delta) % count + count) % count)!
        editing = field == .prompt
    }

    private mutating func moveWithin(by delta: Int) {
        switch field {
        case .repo where !guesses.isEmpty:
            repoCursor = min(max(repoCursor + delta, 0), guesses.count - 1)
        case .agent:
            agentIndex = ((agentIndex + delta) % agents.count + agents.count) % agents.count
        case .options:
            optionCursor = min(max(optionCursor + delta, 0), Option.allCases.count - 1)
        default:
            break
        }
    }

    private mutating func toggle() {
        switch field {
        case .repo where guesses.indices.contains(repoCursor):
            reposTouched = true
            let id = guesses[repoCursor].repo.id
            if let index = selectedRepos.firstIndex(of: id) {
                selectedRepos.remove(at: index)
            } else {
                selectedRepos.append(id)
            }
        case .options:
            switch Option(rawValue: optionCursor)! {
            case .autostart: autostart.toggle()
            case .planFirst: planFirst.toggle()
            case .shellSplit: shellSplit.toggle()
            }
        default:
            break
        }
    }

    /// `⌃n ⌃p`: in the repo field, make the next guess the primary repo; in the agent field, the next agent.
    private mutating func cycleGuess(by delta: Int) -> Outcome {
        switch field {
        case .agent:
            moveWithin(by: delta)
        default:
            guard !guesses.isEmpty else { return .handled }
            reposTouched = true
            let current = selectedRepos.first.flatMap { id in guesses.firstIndex { $0.repo.id == id } } ?? -delta
            let next = ((current + delta) % guesses.count + guesses.count) % guesses.count
            let id = guesses[next].repo.id
            selectedRepos.removeAll { $0 == id }
            if selectedRepos.isEmpty { selectedRepos = [id] } else { selectedRepos[0] = id }
            repoCursor = next
        }
        return .handled
    }

    private mutating func setPrompt(_ text: String) {
        prompt = text
        guesses = StartWork.guessRepos(for: text, in: repos, history: history)
        if !nameEdited {
            name = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : StartWork.name(for: text)
        }
        if !reposTouched {
            // The top guess, plus every repo the prompt names outright.
            let picked = guesses.enumerated().filter { index, guess in
                guess.confidence >= 80 || (index == 0 && guess.confidence > 0)
            }.map(\.element.repo.id)
            selectedRepos = picked
        }
    }

    static func deletingLastWord(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        while let last = text.last, !last.isWhitespace {
            text.removeLast()
        }
        return text
    }

    /// Lowercase, spaces to dashes, nothing git would reject.
    static func branchSafe(_ text: String) -> String {
        let mapped = text.lowercased().map { char -> Character in
            char.isLetter || char.isNumber || char == "-" || char == "." || char == "/" ? char : "-"
        }
        return String(mapped).replacingOccurrences(of: "--", with: "-")
    }
}
