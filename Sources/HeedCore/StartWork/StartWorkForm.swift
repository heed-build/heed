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
        /// Promoting a scratch chat with files: copy them into the worktree.
        case copyFiles
    }

    /// The options shown: copying a chat's files only when promoting a scratch chat that has any.
    public var options: [Option] {
        [.autostart, .planFirst, .shellSplit] + (promotion?.canCopy == true ? [.copyFiles] : [])
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
    /// The guesses by the rules alone, before a model's pick.
    private var ruledGuesses: [RepoGuess] = []
    /// The model's last repo pick and why: kept while you type on, until it answers again or the prompt names a repo.
    private var advisedRepo: (id: String, why: String?)?
    /// What the model is told about your repos (`StartWorkHints`); the app fills it in.
    public var hints = StartWorkHints()
    /// A question is out to the model: the dialog shows it, subtly.
    public var thinking = false
    /// What Start work guessed, before you changed anything: recorded with what you chose (`StartWorkOutcome`).
    public private(set) var guessedRepo: String?
    public private(set) var guessedName = ""
    /// The model's advice made it into the guesses.
    public private(set) var advised = false
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
    /// A chat instead of work in repos (the chat chip in the repo field, or `chat.new`); nil for work in worktrees.
    public private(set) var chat: ChatChoice?
    /// Hosts a chat can run on, besides this Mac.
    public let hosts: [String]

    /// A chat's folder and where it runs. The Folder field (in place of Worktree) holds the scratch folder's name in
    /// `name`, or the picked folder's path in `path`.
    public struct ChatChoice: Equatable, Sendable {
        public var kind: ChatFolder.Kind = .scratch
        public var path = "~/"
        /// The host it runs on; nil for this Mac.
        public var host: String?
        /// The focused chip in the Folder field: the kinds, then this Mac and each host.
        public var cursor = 0
    }

    /// The Folder field's chips in a chat: scratch, folder, then this Mac and each host.
    public var chatChips: [(label: String, selected: Bool)] {
        guard let chat else { return [] }
        return [("scratch", chat.kind == .scratch), ("folder", chat.kind == .folder), ("this Mac", chat.host == nil)]
            + hosts.map { ("@\($0)", chat.host == $0) }
    }

    /// Where the chat chip sits in the repo field: after the repos and the search chip.
    public var chatChipIndex: Int { repoChoices.isEmpty ? 0 : repoChoices.count + 1 }

    /// A chat being promoted into this work (`chat.promote`); nil for plain Start work. It has no chat chip: the
    /// work goes in a repo.
    public private(set) var promotion: Promotion?

    /// The last stop in the repo field: the chat chip, or the search chip when promoting.
    private var lastRepoStop: Int { promotion == nil ? chatChipIndex : repoChoices.count }

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
    /// When you last worked in each repo: recent ones rank higher.
    private let lastWorked: [String: Date]
    /// What the cursor was on when Start work opened.
    private let context: StartContext?
    private let prefixes: BranchPrefixes
    private let sessionID = StartWorkForm.newSessionID()

    /// Makes the new session's id; screenshots pin it so the command preview never changes between runs.
    public nonisolated(unsafe) static var newSessionID: () -> String = { UUID().uuidString.lowercased() }
    private let integration: IntegrationFiles?
    /// The agents' hook files on each host (under its ~/.heed), for work started there.
    private let hostIntegrations: [String: IntegrationFiles]
    private var nameEdited = false
    private var reposTouched = false

    public init(
        repos: [RepoRecord], lastWorked: [String: Date] = [:], context: StartContext? = nil,
        settings: WorkSettings, prompt: String = "", integration: IntegrationFiles? = nil,
        hostIntegrations: [String: IntegrationFiles] = [:], hosts: [String] = [], chat: Bool = false,
        promotion: Promotion? = nil
    ) {
        self.promotion = promotion
        self.hostIntegrations = hostIntegrations
        self.hosts = hosts
        self.repos = repos
        self.lastWorked = lastWorked
        self.context = context
        prefixes = settings.prefixes
        shellSplit = settings.shellSplit
        signOff = settings.signOff
        self.integration = integration
        agents = settings.agents.map(Optional.some) + [nil]
        // Promoting: the chat's own agent unless you pick another.
        let preferred = promotion?.chatAgent ?? settings.defaultAgent
        agentIndex = settings.agents.firstIndex { $0.name == preferred }
            ?? settings.agents.firstIndex { $0.name == settings.defaultAgent } ?? 0
        if chat { self.chat = ChatChoice() }
        setPrompt(prompt)
        if chat { repoCursor = chatChipIndex }
    }

    /// `chat.new`, or the chat chip: a chat, no repo. Off again goes back to the guessed repo.
    public mutating func setChat(_ on: Bool) {
        guard on != (chat != nil) else { return }
        chat = on ? ChatChoice() : nil
        reposTouched = on
        if on { selectedRepos = [] }
        let typed = prompt
        setPrompt(typed)
    }

    /// `:agent codex`: that agent, chosen.
    @discardableResult
    public mutating func choose(agent name: String) -> Bool {
        guard let index = agents.firstIndex(where: { $0?.name == name.lowercased() }) else { return false }
        agentIndex = index
        return true
    }

    /// Start work from a repo (`o` on a Repos row): that repo, chosen, whatever the prompt suggests later.
    public mutating func choose(repo id: String) {
        guard repos.contains(where: { $0.id == id }) else { return }
        setChat(false)
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
        if let chat {
            let location = chat.host.map(Location.host) ?? .local
            var plan = StartWorkPlan(
                prompt: prompt, repos: [], name: name, agent: agent, sessionID: sessionID,
                integration: chat.host.map { hostIntegrations[$0] } ?? integration
            )
            plan.chat = ChatPlan(kind: chat.kind, name: chat.kind == .scratch ? name : chat.path, location: location)
            plan.autostart = autostart && agent != nil
            plan.planFirst = planFirst
            plan.shellSplit = shellSplit
            plan.signOff = signOffArguments(nil)
            return plan
        }
        let records = selectedRecords
        var plan = StartWorkPlan(
            prompt: prompt, repos: records, name: name, agent: agent, sessionID: sessionID,
            integration: records.first?.location.hostName.map { hostIntegrations[$0] } ?? integration
        )
        plan.autostart = autostart && agent != nil
        plan.planFirst = planFirst
        plan.shellSplit = shellSplit
        plan.promotion = promotion
        plan.instructions = instructions[records.first?.repo.slug ?? ""] ?? ""
        plan.signOff = signOffArguments(records.first?.repo)
        return plan
    }

    /// `start_instructions` per repo slug, for a promotion's handoff prompt.
    public var instructions: [String: String] = [:]
    /// Which repos' agents are asked to sign off with a summary.
    public var signOff = SignOffRule()

    private func signOffArguments(_ repo: Repo?) -> [String] {
        guard let agent, signOff.applies(to: repo) else { return [] }
        return SignOff.arguments(agent: agent.name)
    }

    public var canStart: Bool {
        if let chat { return chat.kind == .scratch ? !name.isEmpty : !folderPath(chat).isEmpty }
        return !selectedRepos.isEmpty && !name.isEmpty
    }

    private func folderPath(_ chat: ChatChoice) -> String {
        let path = chat.path.trimmingCharacters(in: .whitespaces)
        return path == "~/" || path == "~" ? "" : path
    }

    /// Why ⌘↩ does not start.
    private var cannotStart: String {
        if let chat { return chat.kind == .scratch ? "name the chat's folder first" : "type the folder's path first" }
        return selectedRepos.isEmpty ? "pick a repo first" : "name the worktree first"
    }

    // MARK: Keys

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        error = nil
        if stroke == KeyStroke("CR", .command) {
            guard canStart else {
                error = cannotStart
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
        let folder = field == .worktree && chat?.kind == .folder
        var text = field == .prompt ? prompt : folder ? chat?.path ?? "" : name
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
        } else if folder {
            chat?.path = text
        } else {
            // A scratch folder's name is one folder: no `/`.
            name = chat == nil ? Self.branchSafe(text) : Self.branchSafe(text).replacingOccurrences(of: "/", with: "-")
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
        let ranked = RepoOrder.recent(repos, lastWorked: lastWorked)
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
            add(searched: record)
        }
        return .handled
    }

    private mutating func add(searched record: RepoRecord) {
        repoSearch = nil
        reposTouched = true
        if !selectedRepos.contains(record.id) { selectedRepos.append(record.id) }
        repoCursor = repoChoices.firstIndex { $0.repo.id == record.id } ?? repoCursor
    }

    // MARK: Mouse

    // A click lands on the field it is in, and then does what the keys there do: space on a chip, `i` in a text field.

    /// A click on a field: it has focus, and a text field (the prompt, the worktree's name or the folder) is edited
    /// when `edit` is set. Focusing elsewhere closes the repo search.
    public mutating func focus(field: Field, edit: Bool = false) {
        error = nil
        if field != .repo { repoSearch = nil }
        self.field = field
        editing = edit && (field == .prompt || field == .worktree)
    }

    /// A click on a chip in the repo field (a guess, the search chip or the chat chip): as space there.
    public mutating func pickRepo(at index: Int) {
        guard (0 ... lastRepoStop).contains(index) else { return }
        focus(field: .repo)
        repoCursor = index
        toggle()
    }

    /// A click on a row of the repo search: that repo, added.
    public mutating func pickSearchMatch(at index: Int) {
        guard var typeahead = repoSearch, let record = typeahead.pick(at: index) else { return }
        error = nil
        add(searched: record)
    }

    /// A click on an agent: chosen.
    public mutating func pickAgent(at index: Int) {
        guard agents.indices.contains(index) else { return }
        focus(field: .agent)
        agentIndex = index
    }

    /// A click on a chip in a chat's Folder field (scratch, folder, this Mac, a host): as space there.
    public mutating func pickChatChip(_ index: Int) {
        guard chat != nil, chatChips.indices.contains(index) else { return }
        focus(field: .worktree)
        chat?.cursor = index
        toggle()
    }

    /// A click on an option's switch: flipped.
    public mutating func toggleOption(_ option: Option) {
        guard let index = options.firstIndex(of: option) else { return }
        focus(field: .options)
        optionCursor = index
        toggle()
    }

    /// Paste goes into whatever is being edited.
    public mutating func paste(_ text: String) {
        if field == .worktree, chat?.kind == .folder {
            chat?.path += text.trimmingCharacters(in: .newlines)
        } else if field == .worktree {
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
            // The last stops are the search chip and the chat chip.
            repoCursor = min(max(repoCursor + delta, 0), lastRepoStop)
        case .worktree where chat != nil:
            let last = chatChips.count - 1
            let next = min(max((chat?.cursor ?? 0) + delta, 0), last)
            chat?.cursor = next
        case .agent:
            agentIndex = ((agentIndex + delta) % agents.count + agents.count) % agents.count
        case .options:
            optionCursor = min(max(optionCursor + delta, 0), options.count - 1)
        default:
            break
        }
    }

    private mutating func toggle() {
        switch field {
        case .repo where repoCursor == chatChipIndex && promotion == nil:
            setChat(chat == nil)
        case .repo where repoCursor == repoChoices.count:
            openSearch()
        case .repo where repoChoices.indices.contains(repoCursor):
            reposTouched = true
            let id = repoChoices[repoCursor].repo.id
            // Picking a repo is work in it, not a chat: that repo, alone.
            if chat != nil {
                setChat(false)
                reposTouched = true
                selectedRepos = [id]
                return
            }
            if let index = selectedRepos.firstIndex(of: id) {
                selectedRepos.remove(at: index)
            } else {
                selectedRepos.append(id)
            }
        case .worktree:
            guard var picked = chat else { break }
            switch picked.cursor {
            case 0: picked.kind = .scratch
            case 1: picked.kind = .folder
            case 2: picked.host = nil
            default: picked.host = hosts[picked.cursor - 3]
            }
            chat = picked
        case .options:
            switch options[optionCursor] {
            case .autostart: autostart.toggle()
            case .planFirst: planFirst.toggle()
            case .shellSplit: shellSplit.toggle()
            case .copyFiles: promotion?.copyFiles.toggle()
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
            // A chat has no repo to guess.
            guard chat == nil, !guesses.isEmpty else { return .handled }
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
        ruledGuesses = StartWork.guessRepos(for: text, in: repos, lastWorked: lastWorked, context: context)
        guesses = ruledGuesses
        if let advisedRepo, !reposTouched, chat == nil, !ruledGuesses.contains(where: \.settled) {
            guesses = StartWork.merge(ruledGuesses, pick: advisedRepo.id, why: advisedRepo.why)
        } else {
            advisedRepo = nil
        }
        advised = advisedRepo != nil
        if !nameEdited {
            name = chat != nil ? Chats.scratchName(for: text, on: Clock.now)
                : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : StartWork.branchName(
                    for: text,
                    prefixes: prefixes
                )
        }
        if !reposTouched, chat == nil {
            // The top guess only. Each selected repo gets a worktree, so a second one is yours to add (space), never a
            // guess: a prompt names repos for many reasons (an issue link, a repo it reads from).
            selectedRepos = guesses.first.flatMap { $0.confidence > 0 ? [$0.repo.id] : nil } ?? []
            guessedRepo = selectedRepos.first
        }
        if !nameEdited { guessedName = name }
    }

    // MARK: Smart guesses

    /// What is still open to ask the model about this prompt, or nil when nothing is: not in a chat, not with an
    /// empty prompt. The repo only when you have not picked one and the prompt names none; the name only while you
    /// have not typed one; the prefix only when the first word picked none (and there is a default prefix).
    public var question: StartWorkQuestion? {
        guard chat == nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let asksRepo = !reposTouched && repos.count > 1 && !ruledGuesses.contains(where: \.settled)
        let candidates = asksRepo ? ruledGuesses.prefix(StartWorkHints.candidates).map { guess in
            StartWorkQuestion.Candidate(
                id: guess.repo.id, about: hints.about[guess.repo.id] ?? "", recent: hints.recent[guess.repo.id] ?? []
            )
        } : []
        let asksName = !nameEdited
        guard !candidates.isEmpty || asksName else { return nil }
        let asksPrefix = asksName && !prefixes.defaultPrefix.isEmpty
            && StartWork.keywordPrefix(for: prompt, prefixes: prefixes) == nil
        return StartWorkQuestion(
            prompt: prompt, candidates: candidates, asksName: asksName,
            prefixes: asksPrefix ? StartWork.prefixChoices(prefixes) : [], examples: asksName ? hints.branches : []
        )
    }

    /// The model's answer to `question`: its repo on top of the guesses (and selected, unless you picked repos), its
    /// name in the worktree field (unless you typed one). An answer to an older prompt changes nothing.
    public mutating func apply(_ advice: StartWorkAdvice?, for question: StartWorkQuestion) {
        guard question.prompt == prompt else { return }
        thinking = false
        guard let advice else { return }
        if question.asksRepo, !reposTouched, chat == nil, !ruledGuesses.contains(where: \.settled),
           let pick = advice.repo,
           question.candidates.contains(where: { $0.id == pick })
        {
            advisedRepo = (pick, advice.why)
            guesses = StartWork.merge(ruledGuesses, pick: pick, why: advice.why)
            selectedRepos = [pick]
            guessedRepo = pick
            advised = true
        }
        if question.asksName, !nameEdited, chat == nil {
            let named = StartWorkAdvice(name: advice.name, prefix: question.prefixes.isEmpty ? nil : advice.prefix)
            name = StartWork.branchName(for: prompt, prefixes: prefixes, advice: named)
            guessedName = name
            advised = advised || advice.name != nil || named.prefix != nil
        }
    }

    /// What was guessed and what you chose, for work in repos (a chat has neither repo nor branch).
    public func outcome(at date: Date) -> StartWorkOutcome? {
        guard chat == nil else { return nil }
        return StartWorkOutcome(
            at: date, prompt: prompt, guessedRepo: guessedRepo, guessedName: guessedName, advised: advised,
            repos: selectedRepos, name: name, agent: agent?.name, planFirst: planFirst
        )
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
