import Foundation

/// `[start_work]`: how Start work guesses.
public struct StartWorkSettings: Equatable, Sendable {
    /// Ask the on-device model (Apple's Foundation Models, where the Mac has them) to improve the repo, branch name
    /// and prefix guesses as you type. Where it is not available Start work guesses as it always did.
    public var smartGuesses = true

    public init(smartGuesses: Bool = true) {
        self.smartGuesses = smartGuesses
    }
}

/// What Start work asks a model while you type: the prompt, and only what is still open. A repo the prompt names, a
/// name you typed or a prefix the first word picked are settled and not asked.
public struct StartWorkQuestion: Hashable, Sendable {
    /// A repo to choose from, as the model sees it.
    public struct Candidate: Hashable, Sendable {
        /// The record id (`org/name`, `org/name@host`): also the answer.
        public var id: String
        /// What the repo is, from its README; empty when unknown.
        public var about: String
        /// Titles of your last sessions there, newest first.
        public var recent: [String]

        public init(id: String, about: String = "", recent: [String] = []) {
            self.id = id
            self.about = about
            self.recent = recent
        }
    }

    public var prompt: String
    /// The repos to choose among, best guess first; empty when the repo is not asked.
    public var candidates: [Candidate]
    /// Ask for a branch name (the words after the prefix).
    public var asksName: Bool
    /// The prefixes to choose among; empty when the prefix is not asked.
    public var prefixes: [String]
    /// A few of your recent branch names, for their style.
    public var examples: [String]

    public init(
        prompt: String, candidates: [Candidate] = [], asksName: Bool = false, prefixes: [String] = [],
        examples: [String] = []
    ) {
        self.prompt = prompt
        self.candidates = candidates
        self.asksName = asksName
        self.prefixes = prefixes
        self.examples = examples
    }

    public var asksRepo: Bool { !candidates.isEmpty }
}

/// A model's answer. Anything may be missing or off: `StartWorkForm.apply` keeps only what fits the question.
public struct StartWorkAdvice: Hashable, Sendable {
    /// A candidate's id.
    public var repo: String?
    /// Why that repo, in a few words.
    public var why: String?
    /// The branch name's words, uncleaned.
    public var name: String?
    public var prefix: String?

    public init(repo: String? = nil, why: String? = nil, name: String? = nil, prefix: String? = nil) {
        self.repo = repo
        self.why = why
        self.name = name
        self.prefix = prefix
    }
}

/// Something that improves Start work's guesses: the on-device model in the app, a fake in tests.
public protocol StartWorkAdvisor: Sendable {
    func advise(_ question: StartWorkQuestion) async throws -> StartWorkAdvice
    /// Start work opened: load what the first answer needs, so it comes sooner.
    func prewarm()
}

public extension StartWorkAdvisor {
    func prewarm() {}
}

/// What Start work knows about your repos beyond their names, for the question: filled in by the app.
public struct StartWorkHints: Equatable, Sendable {
    /// Record id → what the repo is (its README's first line).
    public var about: [String: String]
    /// Record id → titles of your recent sessions there, newest first.
    public var recent: [String: [String]]
    /// Your recent branch names, newest first.
    public var branches: [String]

    public init(about: [String: String] = [:], recent: [String: [String]] = [:], branches: [String] = []) {
        self.about = about
        self.recent = recent
        self.branches = branches
    }

    /// How many repos the model chooses among, and how much it is told about each.
    public static let candidates = 10
    static let titlesPerRepo = 3
    static let examples = 5

    /// Recent titles per repo and recent branch names, from sessions open and closed. Chats have neither.
    public static func from(sessions: [Session], closed: [HistoryEntry]) -> StartWorkHints {
        let all = (sessions.map { ($0, $0.lastActivity) } + closed.map { ($0.session, $0.closedAt) })
            .filter { !$0.0.isChat }
            .sorted { $0.1 > $1.1 }
        var recent: [String: [String]] = [:]
        var branches: [String] = []
        for (session, _) in all {
            for repo in session.repos {
                let id = StartContext.id(repo, session.location)
                let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, recent[id, default: []].count < titlesPerRepo, recent[id]?.contains(title) != true {
                    recent[id, default: []].append(title)
                }
            }
            if !session.branch.isEmpty, branches.count < examples, !branches.contains(session.branch) {
                branches.append(session.branch)
            }
        }
        return StartWorkHints(recent: recent, branches: branches)
    }

    /// What a README says the repo is: its first line of prose, skipping headings, badges, HTML and front matter;
    /// the first heading when there is no prose near the top. At most 140 characters; nil when there is nothing.
    public static func readmeSummary(_ text: String) -> String? {
        var heading: String?
        var inFrontMatter = false
        var inCode = false
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---", index == 0 || inFrontMatter {
                inFrontMatter.toggle()
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inFrontMatter || inCode || line.isEmpty || line.hasPrefix("<") || line.hasPrefix("[![")
                || line.hasPrefix("![") || line.allSatisfy({ "=-_*".contains($0) })
            {
                continue
            }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if heading == nil, !title.isEmpty { heading = title }
                continue
            }
            let prose = line.trimmingCharacters(in: CharacterSet(charactersIn: ">*_ "))
            guard !prose.isEmpty else { continue }
            return clipped(prose)
        }
        return heading.map(clipped)
    }

    private static func clipped(_ text: String) -> String {
        text.count > 140 ? String(text.prefix(139)) + "…" : text
    }
}

public extension StartWork {
    /// The prefix the prompt's first word picks (`fix …` → `fix`); nil when no word list has it.
    static func keywordPrefix(for prompt: String, prefixes: BranchPrefixes) -> String? {
        slugWords(prompt).first.flatMap(prefixes.prefix(forWord:))
    }

    /// What the model may choose as a prefix: every configured one, and the default.
    static func prefixChoices(_ prefixes: BranchPrefixes) -> [String] {
        var choices = prefixes.prefixes.keys.sorted()
        if !prefixes.defaultPrefix.isEmpty, !choices.contains(prefixes.defaultPrefix) {
            choices.append(prefixes.defaultPrefix)
        }
        return choices
    }

    /// A model's branch name made branch-safe: lowercase `a-z 0-9` words joined by `-`, at most `maxWords`, without a
    /// leading prefix (`fix/…`, or a first word that is a prefix: `fix-crash` is `crash` under `fix/`). Nil when
    /// nothing is left.
    static func cleanSlug(_ raw: String, prefixes: [String] = [], maxWords: Int = 5) -> String? {
        // `slowDeploys` is two words.
        let split = raw.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1-$2", options: .regularExpression)
        var text = split.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        var words = text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
        if words.count > 1, let first = words.first, prefixes.contains(first) { words.removeFirst() }
        let slug = words.prefix(maxWords).joined(separator: "-")
        return slug.isEmpty ? nil : String(slug.prefix(48))
    }

    /// The branch name with a model's advice laid over the rules: its words in place of the prompt's first ones, and
    /// its prefix only when the first word picked none (and there is a default prefix at all).
    static func branchName(
        for prompt: String, prefixes: BranchPrefixes, advice: StartWorkAdvice?, maxWords: Int = 4
    ) -> String {
        let plain = branchName(for: prompt, prefixes: prefixes, maxWords: maxWords)
        guard let advice else { return plain }
        let ruled = keywordPrefix(for: prompt, prefixes: prefixes)
        let advised = advice.prefix.map { $0.lowercased() }.flatMap { prefixChoices(prefixes).contains($0) ? $0 : nil }
        let prefix = ruled ?? (prefixes.defaultPrefix.isEmpty ? "" : advised ?? prefixes.defaultPrefix)
        let slug = advice.name.flatMap { cleanSlug($0, prefixes: prefix.isEmpty ? [] : [prefix]) }
        let words: String = if let slug {
            slug
        } else if ruled != nil, let index = plain.firstIndex(of: "/") {
            String(plain[plain.index(after: index)...])
        } else {
            name(for: prompt, maxWords: maxWords)
        }
        return prefix.isEmpty ? words : "\(prefix)/\(words)"
    }

    /// The guesses with a model's pick on top, saying why. Every other guess stays, in its order. A pick that is not
    /// among the guesses changes nothing.
    static func merge(_ guesses: [RepoGuess], pick: String?, why: String?) -> [RepoGuess] {
        guard let pick, let index = guesses.firstIndex(where: { $0.repo.id == pick }) else { return guesses }
        let picked = guesses[index]
        let because = why
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let reason = ["Fits the prompt\(because.map { ": \($0)" } ?? "").", picked.reason]
            .filter { !$0.isEmpty }.joined(separator: " ")
        // As sure as the guess it displaced, so the chips still read best first.
        let confidence = max(picked.confidence, guesses.first?.confidence ?? 0, 1)
        var merged = guesses
        merged.remove(at: index)
        merged.insert(
            RepoGuess(
                repo: picked.repo,
                confidence: confidence,
                reason: reason,
                named: picked.named,
                opened: picked.opened,
                advised: true
            ),
            at: 0
        )
        return merged
    }
}

/// Asks the advisor once typing pauses: each new question cancels the one before (waiting or in flight), and an
/// answer is delivered only for the question still current. Typing never waits on it.
@MainActor
public final class StartWorkAdviceScheduler {
    private let advisor: any StartWorkAdvisor
    private let debounce: Duration
    private var task: Task<Void, Never>?
    /// The question asked last (waiting, in flight or answered): asking it again does nothing.
    public private(set) var current: StartWorkQuestion?

    public init(advisor: any StartWorkAdvisor, debounce: Duration = .milliseconds(400)) {
        self.advisor = advisor
        self.debounce = debounce
    }

    /// Asks `question` after the pause, unless it is the one already asked; nil cancels. `deliver` gets the advice,
    /// or nil when the advisor failed. Returns the task, for tests to await.
    @discardableResult
    public func ask(
        _ question: StartWorkQuestion?, deliver: @escaping @MainActor (StartWorkQuestion, StartWorkAdvice?) -> Void
    ) -> Task<Void, Never>? {
        guard question != current else { return nil }
        task?.cancel()
        current = question
        guard let question else { return nil }
        let advisor = advisor, debounce = debounce
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            let advice = try? await advisor.advise(question)
            guard !Task.isCancelled, let self, current == question else { return }
            deliver(question, advice)
        }
        return task
    }

    /// The dialog closed: nothing more is delivered.
    public func cancel() {
        task?.cancel()
        task = nil
        current = nil
    }
}
