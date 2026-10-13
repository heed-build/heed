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
    public private(set) var shellSplit = false
    public private(set) var error: String?
    /// Picking any repo by name (the last chip in the repo field, or `/` there); nil when not searching.
    public private(set) var repoSearch: Typeahead<RepoRecord>?

    /// How many guesses get a chip of their own; the rest are a search away.
    public static let chipCount = 6

    /// The repo field's chips: the top guesses, plus anything picked from search that is not among them. The cursor
    /// can also sit one past these, on the search chip.
    public var repoChoices: [RepoGuess] {
        let top = Array(guesses.prefix(Self.chipCount))
        let extra = selectedRepos.filter { id in !top.contains { $0.repo.id == id } }
            .compactMap { id in guesses.first { $0.repo.id == id } }
        return top + extra
    }

    private let repos: [RepoRecord]
    private let history: [Session]
    /// Added worktrees per repo: repos with more rank higher.
    private let worktreeCounts: [String: Int]
    private let prefixes: BranchPrefixes
    private let sessionID = StartWorkForm.newSessionID()

    /// Makes the new session's id; screenshots pin it so the command preview never changes between runs.
    public nonisolated(unsafe) static var newSessionID: () -> String = { UUID().uuidString.lowercased() }
    private let integration: IntegrationFiles?
    private var nameEdited = false
    private var reposTouched = false

    public init(
        repos: [RepoRecord], history: [Session], settings: WorkSettings, prompt: String = "",
        integration: IntegrationFiles? = nil, worktreeCounts: [String: Int] = [:]
    ) {
        self.repos = repos
        self.history = history
        self.worktreeCounts = worktreeCounts
        prefixes = settings.prefixes
        shellSplit = settings.shellSplit
        self.integration = integration
        agents = settings.agents.map(Optional.some) + [nil]
        agentIndex = settings.agents.firstIndex { $0.name == settings.defaultAgent } ?? 0
        setPrompt(prompt)
    }

    /// Start work from a repo (`o` on a Repos row): that repo, chosen, whatever the prompt suggests later.
    public mutating func choose(repo id: String) {
        guard repos.contains(where: { $0.id == id }) else { return }
        reposTouched = true
        selectedRepos = [id]
        repoCursor = repoChoices.firstIndex { $0.repo.id == id } ?? repoCursor
    }

    // MARK: Derived

    public var agent: AgentProfile? { agents[agentIndex] }

    public var selectedRecords: [RepoRecord] {
        selectedRepos.compactMap { id in repos.first { $0.id == id } }
    }

    public var plan: StartWorkPlan {
        var plan = StartWorkPlan(
            prompt: prompt, repos: selectedRecords, name: name, agent: agent, sessionID: sessionID,
            integration: integration
        )
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
        if repoSearch != nil { return search(stroke) }
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
        case KeyStroke("/") where field == .repo:
            openSearch()
        default:
            return .ignored
        }
        return .handled
    }

    private mutating func openSearch() {
        let ranked = RepoOrder.sorted(repos, counts: worktreeCounts)
        repoSearch = Typeahead(items: ranked) { [$0.repo.slug] }
    }

    private mutating func search(_ stroke: KeyStroke) -> Outcome {
        guard var typeahead = repoSearch else { return .ignored }
        switch typeahead.handle(stroke) {
        case .handled:
            repoSearch = typeahead
        case .cancel:
            repoSearch = nil
        case let .picked(record):
            repoSearch = nil
            reposTouched = true
            if !selectedRepos.contains(record.id) { selectedRepos.append(record.id) }
            repoCursor = repoChoices.firstIndex { $0.repo.id == record.id } ?? repoCursor
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
        case .repo:
            // The last stop is the search chip.
            repoCursor = min(max(repoCursor + delta, 0), repoChoices.count)
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
        case .repo where repoCursor == repoChoices.count:
            openSearch()
        case .repo where repoChoices.indices.contains(repoCursor):
            reposTouched = true
            let id = repoChoices[repoCursor].repo.id
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
        guesses = StartWork.guessRepos(for: text, in: repos, history: history, worktrees: worktreeCounts)
        if !nameEdited {
            name = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : StartWork.branchName(
                for: text,
                prefixes: prefixes
            )
        }
        if !reposTouched {
            // The top guess only. Each selected repo gets a worktree, so a second one is yours to add (space), never a
            // guess: a prompt names repos for many reasons (an issue link, a repo it reads from).
            selectedRepos = guesses.first.flatMap { $0.confidence > 0 ? [$0.repo.id] : nil } ?? []
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
