import Foundation

/// The Start work dialog as a value: what is typed and picked, which field has focus, and what the keys do. The view
/// draws it; the app feeds it keys. design/screens/StartWork.png.
///
/// Like the app it has two modes: editing (INSERT: keys type into the prompt or the worktree name) and moving
/// (NORMAL: `j k` or `⇥` between fields, `h l` within one, `space` toggles). `⌃n ⌃p` cycle guesses in both,
/// `<D-CR>` starts, `<Esc>` stops editing and then cancels. The model and effort fields step through the agent's
/// catalogue with `h l`; Custom… is typed (`i`). They are skipped when the agent has nothing to pick.
public struct StartWorkForm: Sendable {
    public enum Field: Int, CaseIterable, Sendable {
        case prompt, kind, repo, worktree, agent, model, effort, options
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
        /// ⌘↩ on a longer prompt not sized yet: the app sizes it now, then starts or shows the card (`sized`).
        case sizeFirst
        /// Make it a goal (⌘↩ on the sizing card): the app makes the goal and opens its wizard.
        case goal(StartGoal)
    }

    public private(set) var field: Field = .prompt
    public private(set) var editing = true
    public private(set) var prompt = ""
    public private(set) var name = ""
    /// What the work is; it picks the branch prefix. Guessed from the prompt until you choose (`h l` on its row).
    public private(set) var kind: WorkKind = .feat
    /// Big pastes, kept beside the prompt (`PromptAttachments`); the agent is told where they are.
    public private(set) var attachments: [PromptAttachment] = []
    /// The attachment chip `h l` are on in the prompt field (NORMAL); `x` drops it, `P` puts it back in the prompt.
    public private(set) var attachmentCursor = 0
    /// Titles of the PRs and issues the prompt links, by URL; the app fills them in as it fetches them.
    public private(set) var linkTitles: [String: String] = [:]
    private var kindEdited = false
    /// Branch names already used, by repo slug (its worktrees' and sessions' branches): a guessed name gets `-2`
    /// rather than clash.
    public private(set) var takenBranches: [String: Set<String>] = [:]
    public private(set) var guesses: [RepoGuess] = []
    /// The guesses by the rules alone, before a model's pick.
    private var ruledGuesses: [RepoGuess] = []
    /// The model's last repo pick and why: kept while you type on, until it answers again or the prompt names a repo.
    private var advisedRepo: (id: String, why: String?)?
    /// What the model is told about your repos (`StartWorkHints`); the app fills it in.
    public var hints = StartWorkHints()
    /// A question is out to the model: the dialog shows it, subtly.
    public var thinking = false
    /// `[start_work] size_check`, and the app can ask: longer prompts are sized (`TaskSizer`).
    public var sizeCheck = false
    /// The latest sizing; the card shows while it says goal (`showsSizeCard`).
    public internal(set) var sizing: TaskSizing?
    /// The prompt (`TaskSizer.key`) sized last, with or without an answer: ⌘↩ does not wait for it again.
    public internal(set) var sizedPrompt: String?
    /// ⌘↩ is waiting for the size of the prompt: the next answer starts the work or shows the card.
    public internal(set) var waitingForSize = false
    /// The sizing the card was put away for (⌥↩, or moving to the fields): it does not come back for that prompt.
    var sizingSetAside: String?
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
    /// The model picked; nil: the agent's default. With `customModel`, what is typed.
    public private(set) var model: String?
    /// Custom… is picked: the model is typed in.
    public private(set) var customModel = false
    /// The effort picked; nil: the agent's default.
    public private(set) var effort: String?
    /// What each agent offers (`AgentModels`, with what its CLI lists); the app fills it in. An agent missing here
    /// gets its seed.
    public var catalogs: [String: AgentModelCatalog] = [:]
    public private(set) var optionCursor = 0
    public private(set) var autostart = true
    public private(set) var planFirst = false
    public private(set) var shellSplit = false
    public private(set) var error: String?
    /// Picking any repo by name (the last chip in the repo field, or `/` there); nil when not searching.
    public private(set) var repoSearch: Typeahead<RepoRecord>?
    /// What heed found out about repos typed into the search (`RepoEntry`), by `RepoEntry.Parsed.key`: the app asks
    /// GitHub (or looks at the path) and fills it in.
    public var entryLookups: [String: RepoEntry.Lookup] = [:]
    /// Repos heed has seen anywhere (hosts, PRs, issues): known to exist, nothing to ask. The app fills it in.
    public var knownSlugs: [String] = []
    /// Where a typed repo that is not on this Mac is cloned when the work starts (the first repo root).
    public var cloneRoot = "~/Projects"
    /// Cloning the typed repos, or why that failed: shown under the repo field.
    public var cloneNote: FieldNote?
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

    private var repos: [RepoRecord]
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
    /// The field being typed in, with its cursor (`caret`).
    private var input = EditableText()
    private var inputField: Field?
    private var reposTouched = false

    public init(
        repos: [RepoRecord], lastWorked: [String: Date] = [:], context: StartContext? = nil,
        settings: WorkSettings, prompt: String = "", integration: IntegrationFiles? = nil,
        hostIntegrations: [String: IntegrationFiles] = [:], hosts: [String] = [], chat: Bool = false,
        promotion: Promotion? = nil, takenBranches: [String: Set<String>] = [:]
    ) {
        self.takenBranches = takenBranches
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
        setAgent(index)
        return true
    }

    /// Another agent: its own defaults for model and effort, whatever the last one had picked.
    private mutating func setAgent(_ index: Int) {
        guard index != agentIndex else { return }
        agentIndex = index
        model = nil
        effort = nil
        customModel = false
    }

    /// The models and efforts the agent offers; nil for none (a shell).
    public var catalog: AgentModelCatalog? {
        agent.map { catalogs[$0.name] ?? AgentModels.catalog(for: $0) }
    }

    /// The fields `j k` and `⇥` stop at: model and effort only when there is something to pick.
    public var fields: [Field] {
        Field.allCases.filter { field in
            switch field {
            case .kind: chat == nil
            case .model: catalog?.takesModel == true
            case .effort: !(catalog.map { ModelPicker.efforts($0, model: model, current: effort) } ?? []).isEmpty
            default: true
            }
        }
    }

    /// The model picker's tag: the default, a model's id, or Custom….
    public var modelSelection: String {
        guard let catalog else { return ModelPicker.defaultTag }
        return customModel ? ModelPicker.customTag : ModelPicker.selection(model, in: catalog)
    }

    /// A click on a model in the menu (or Custom…).
    public mutating func pickModel(_ tag: String) {
        guard let catalog else { return }
        focus(field: .model)
        customModel = tag == ModelPicker.customTag
        model = customModel ? nil : ModelPicker.value(picking: tag, current: model, in: catalog)
        effort = ModelPicker.effort(effort, after: model, in: catalog)
        editing = customModel
    }

    /// A click on an effort in the menu.
    public mutating func pickEffort(_ tag: String) {
        focus(field: .effort)
        effort = tag == ModelPicker.defaultTag ? nil : tag
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

    /// Repos typed into the search that are not on this Mac yet (`owner/name`): cloned into `cloneRoot` when the work
    /// starts, then `adopt`ed.
    public var typedRepos: [String] {
        selectedRepos.filter { id in !repos.contains { $0.id == id } }
    }

    /// The slugs checked out on this Mac.
    private var hereSlugs: [String] { repos.filter(\.location.isLocal).map(\.repo.slug) }

    /// A repo heed did not know until now (a typed path, a clone): it joins the form's repos, selected when typed.
    public mutating func adopt(_ record: RepoRecord) {
        if !repos.contains(where: { $0.id == record.id }) { repos.append(record) }
        if let index = selectedRepos.firstIndex(where: { $0.lowercased() == record.id.lowercased() }) {
            selectedRepos[index] = record.id
        }
    }

    /// What is typed in the repo search, read as a repo, when it matches none heed knows; nil otherwise.
    public var searchEntry: RepoEntry.Parsed? {
        guard let search = repoSearch, search.matches.isEmpty,
              case let .success(parsed)? = RepoEntry.parse(search.query) else { return nil }
        return parsed
    }

    /// The note under the repo search when what is typed matches no known repo: the format, then what GitHub (or the
    /// path) says.
    public var searchNote: FieldNote? {
        guard let search = repoSearch, search.matches.isEmpty, let parsed = RepoEntry.parse(search.query) else {
            return nil
        }
        switch parsed {
        case let .failure(note): return note
        case let .success(entry):
            return RepoEntry.note(
                entry, place: "this Mac", local: true, here: hereSlugs, known: knownSlugs, lookups: entryLookups,
                clonesInto: cloneRoot, starting: "the work starts"
            )
        }
    }

    /// The typed entry the app should look up (GitHub, or the path), or nil when there is nothing to ask.
    public var entryToLookUp: RepoEntry.Parsed? {
        guard let entry = searchEntry,
              RepoEntry.needsLookup(entry, here: hereSlugs, known: knownSlugs, lookups: entryLookups)
        else { return nil }
        return entry
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
            plan.model = pickedModel
            plan.effort = effort
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
        plan.model = pickedModel
        plan.effort = effort
        plan.promotion = promotion
        plan.kind = kind
        plan.attachments = attachments
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

    /// The model the agent starts on: what is picked, a typed custom id trimmed; nil for the default.
    private var pickedModel: String? {
        guard agent != nil, let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return model
    }

    /// Why the typed custom model cannot be used; nil when it can (or none is being typed).
    public var modelProblem: String? {
        guard customModel, agent != nil else { return nil }
        return ModelPicker.problem(custom: model ?? "")
    }

    public var canStart: Bool {
        if modelProblem != nil { return false }
        if let chat { return chat.kind == .scratch ? !name.isEmpty : !folderPath(chat).isEmpty }
        return !selectedRepos.isEmpty && !name.isEmpty && cloneNote?.tone != .checking
    }

    private func folderPath(_ chat: ChatChoice) -> String {
        let path = chat.path.trimmingCharacters(in: .whitespaces)
        return path == "~/" || path == "~" ? "" : path
    }

    /// Why ⌘↩ does not start.
    private var cannotStart: String {
        if let modelProblem { return "\(modelProblem), or pick a model" }
        if let chat { return chat.kind == .scratch ? "name the chat's folder first" : "type the folder's path first" }
        if cloneNote?.tone == .checking { return "wait for the clone" }
        return selectedRepos.isEmpty ? "pick a repo first" : "name the worktree first"
    }

    // MARK: Keys

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        error = nil
        if showsSizeCard, let outcome = answerSizeCard(stroke) { return outcome }
        if stroke == KeyStroke("CR", .command) {
            if let key = sizeQuestion, sizedPrompt != key, !waitingForSize, canStart {
                waitingForSize = true
                return .sizeFirst
            }
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
        syncInput()
        switch stroke {
        case KeyStroke("CR"):
            guard field == .prompt else {
                editing = false
                return .handled
            }
            input.insert("\n")
        case KeyStroke("Space") where field == .model:
            // A model id has no spaces.
            return .handled
        default:
            guard input.handle(stroke) else { return .ignored }
        }
        store(input.text)
        return .handled
    }

    /// The text of the field being edited: the prompt, the model id, the folder's path or the worktree's name.
    private var editedText: String {
        let folder = field == .worktree && chat?.kind == .folder
        return field == .prompt ? prompt : field == .model ? model ?? "" : folder ? chat?.path ?? "" : name
    }

    /// The edited field with its cursor; a field the cursor has not been in yet has it at its end.
    public var caret: EditableText {
        inputField == field && input.text == editedText
            ? input : EditableText(editedText, multiline: field == .prompt)
    }

    /// The cursor follows the field: a field whose text changed since (or another field) starts at its end.
    private mutating func syncInput() {
        input = caret
        inputField = field
    }

    /// Puts edited text into its field. The worktree's name is made branch-safe on the way, which can change what was
    /// typed (a space becomes `-`): the cursor keeps its place, as near as the shorter text allows.
    private mutating func store(_ text: String) {
        let folder = field == .worktree && chat?.kind == .folder
        if field == .prompt {
            setPrompt(text)
        } else if field == .model {
            model = text
        } else if folder {
            chat?.path = text
        } else {
            // A scratch folder's name is one folder: no `/`.
            name = chat == nil ? Self.branchSafe(text) : Self.branchSafe(text).replacingOccurrences(of: "/", with: "-")
            nameEdited = true
            if name != text {
                let cursor = input.cursor
                input = EditableText(name)
                input.moveCursor(to: cursor)
            }
        }
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
            if field == .prompt || field == .worktree || (field == .model && customModel) {
                editing = true
            } else {
                toggle()
            }
        case KeyStroke("Space"):
            toggle()
        case KeyStroke("/") where field == .repo:
            openSearch()
        case KeyStroke("x") where field == .prompt && !attachments.isEmpty:
            dropAttachment(at: attachmentCursor)
        case KeyStroke("P") where field == .prompt && !attachments.isEmpty:
            inlineAttachment(at: attachmentCursor)
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
        // ↩ on a typed repo heed does not know: added once its note says it is fine.
        if stroke == KeyStroke("CR"), typeahead.matches.isEmpty, let entry = searchEntry {
            if searchNote?.tone == .fine,
               let slug = RepoEntry.picked(entry, here: hereSlugs, known: knownSlugs, lookups: entryLookups)
            {
                addTyped(slug)
            }
            return .handled
        }
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

    /// A typed repo: the one on this Mac when it is here, else its slug, to clone on start.
    private mutating func addTyped(_ slug: String) {
        if let record = repos.first(where: { $0.location.isLocal && $0.repo.slug.lowercased() == slug.lowercased() }) {
            return add(searched: record)
        }
        repoSearch = nil
        reposTouched = true
        cloneNote = nil
        selectedRepos = [slug]
        suggestName()
    }

    /// A click on a typed repo's chip: dropped.
    public mutating func dropTyped(_ slug: String) {
        selectedRepos.removeAll { $0 == slug }
        cloneNote = nil
    }

    private mutating func add(searched record: RepoRecord) {
        repoSearch = nil
        reposTouched = true
        selectedRepos = [record.id]
        suggestName()
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
        editing = edit && (field == .prompt || field == .worktree || (field == .model && customModel))
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

    /// A click on a kind: chosen.
    public mutating func pickKind(_ kind: WorkKind) {
        focus(field: .kind)
        choose(kind: kind)
    }

    /// "worked here 2 days ago" for a repo in the search; nil for one you never worked in.
    public func lastWorkedText(_ record: RepoRecord) -> String? {
        lastWorked[record.id].map { StartWork.ago($0, now: Clock.now) }
    }

    /// The prefixes in effect, for the kind row's note.
    public var branchPrefixes: BranchPrefixes { prefixes }

    /// A click on an agent: chosen.
    public mutating func pickAgent(at index: Int) {
        guard agents.indices.contains(index) else { return }
        focus(field: .agent)
        setAgent(index)
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

    /// Paste goes into whatever is being edited, at its cursor.
    public mutating func paste(_ text: String) {
        if var search = repoSearch {
            search.paste(text)
            repoSearch = search
            return
        }
        let folder = field == .worktree && chat?.kind == .folder
        let pasted: String
        if field == .model, customModel {
            pasted = text.filter { !$0.isWhitespace }
        } else if folder {
            pasted = text.trimmingCharacters(in: .newlines)
        } else if field == .worktree {
            pasted = text
        } else {
            field = .prompt
            editing = true
            // A log or a diff is kept beside the prompt, not in it.
            if PromptAttachments.isLarge(text) {
                attachments.append(PromptAttachment(id: (attachments.map(\.id).max() ?? 0) + 1, text: text))
                attachmentCursor = attachments.count - 1
                return
            }
            pasted = text
        }
        syncInput()
        input.paste(pasted)
        store(input.text)
    }

    // MARK: Editing state

    private mutating func move(by delta: Int) {
        let stops = fields
        let current = stops.firstIndex(of: field) ?? 0
        field = stops[((current + delta) % stops.count + stops.count) % stops.count]
        editing = field == .prompt
    }

    private mutating func moveWithin(by delta: Int) {
        switch field {
        case .prompt where !attachments.isEmpty:
            attachmentCursor = min(max(attachmentCursor + delta, 0), attachments.count - 1)
        case .repo:
            // The last stops are the search chip and the chat chip.
            repoCursor = min(max(repoCursor + delta, 0), lastRepoStop)
        case .worktree where chat != nil:
            let last = chatChips.count - 1
            let next = min(max((chat?.cursor ?? 0) + delta, 0), last)
            chat?.cursor = next
        case .kind:
            let all = WorkKind.allCases
            let index = all.firstIndex(of: kind) ?? 0
            choose(kind: all[((index + delta) % all.count + all.count) % all.count])
        case .agent:
            setAgent(((agentIndex + delta) % agents.count + agents.count) % agents.count)
        case .model:
            guard let catalog else { break }
            let tags = ModelPicker.models(catalog).map(\.tag)
            let current = tags.firstIndex(of: modelSelection) ?? 0
            let tag = tags[((current + delta) % tags.count + tags.count) % tags.count]
            customModel = tag == ModelPicker.customTag
            model = customModel ? nil : ModelPicker.value(picking: tag, current: model, in: catalog)
            effort = ModelPicker.effort(effort, after: model, in: catalog)
        case .effort:
            guard let catalog else { break }
            effort = ModelPicker.stepEffort(effort, by: delta, in: catalog, model: model)
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
            // One repo, one worktree: another chip replaces it. A session still shows the repos its PRs land in.
            selectedRepos = [id]
            suggestName()
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

    /// `h l` on the kind row, or a click on a kind: that kind, and its prefix on the name heed suggests.
    public mutating func choose(kind: WorkKind) {
        kindEdited = true
        self.kind = kind
        suggestName()
        if !nameEdited { guessedName = name }
    }

    /// The name heed suggests while you have not typed one: the prompt's meaningful words, without links or the repos
    /// it names, after the kind's prefix, made unique in the repo. Until you choose a kind, the name's prefix (from
    /// the first word, or the on-device model) says which kind it is.
    private mutating func suggestName(advice: StartWorkAdvice? = nil) {
        guard !nameEdited else { return }
        if chat != nil {
            name = Chats.scratchName(for: prompt, on: Clock.now)
            return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            name = ""
            return
        }
        let stripped = StartWork.namingText(prompt, repoNames: repos.map(\.repo.name))
        // A linked PR or issue says what the work is better than the words around the link.
        let titles = linkTitles
        let linked = links.lazy.compactMap { titles[$0.url] }.first
        let text = linked ?? (StartWork.slugWords(stripped).isEmpty ? prompt : stripped)
        var suggested = advice.map { StartWork.branchName(for: text, prefixes: prefixes, advice: $0) }
            ?? StartWork.branchName(for: text, prefixes: prefixes)
        if kindEdited {
            suggested = StartWork.prefixed(suggested, with: kind.prefix(in: prefixes), known: knownPrefixes)
        } else {
            let prefix = suggested.firstIndex(of: "/").map { String(suggested[..<$0]) }
            kind = prefix.flatMap(WorkKind.init(prefix:)) ?? WorkKind.guess(for: text, prefixes: prefixes)
        }
        let slug = selectedRecords.first?.repo.slug ?? selectedRepos.first ?? ""
        name = StartWork.unique(suggested, taken: takenBranches[slug] ?? [])
    }

    /// A click on an attachment's ✕, or `x` on it: dropped.
    public mutating func dropAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        attachmentCursor = min(attachmentCursor, max(attachments.count - 1, 0))
    }

    /// `P` on an attachment, or a click on it: its text back in the prompt, at the end.
    public mutating func inlineAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        let attachment = attachments.remove(at: index)
        attachmentCursor = min(attachmentCursor, max(attachments.count - 1, 0))
        let joined = prompt.isEmpty ? attachment.text : prompt + "\n\n" + attachment.text
        setPrompt(joined)
    }

    /// The PRs and issues the prompt links, in order.
    public var links: [PromptLink] { PromptLink.links(in: prompt) }

    /// What heed fetched for the prompt's links: their titles, which the branch is named from.
    public mutating func setLinkTitles(_ titles: [String: String]) {
        guard titles != linkTitles else { return }
        linkTitles = titles
        suggestName()
        if !nameEdited { guessedName = name }
    }

    /// Every prefix a name may start with: the configured ones and each kind's names.
    private var knownPrefixes: Set<String> {
        Set(StartWork.prefixChoices(prefixes)).union(WorkKind.allCases.flatMap(\.prefixNames))
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
        if !reposTouched, chat == nil {
            // The top guess only: a prompt names repos for many reasons (an issue link, a repo it reads from).
            selectedRepos = guesses.first.flatMap { $0.confidence > 0 ? [$0.repo.id] : nil } ?? []
            guessedRepo = selectedRepos.first
        }
        suggestName()
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
            suggestName(advice: named)
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
