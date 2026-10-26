import Foundation

/// What heed knows about a session or chat when it looks for its goal: where it works, what it touched, what it links
/// to and what it was asked. Kept with each attach decision, so the Unassigned view and suggested goals read it back
/// without the session.
public struct AttachSubject: Hashable, Sendable, Codable {
    public var kind: GoalLink.Kind
    public var id: String
    public var title: String
    public var prompt: String
    /// `org/name`.
    public var repos: [String]
    public var branch: String
    public var worktreePaths: [String]
    /// Files its work touched (the ledger's), repo-relative.
    public var files: [String]
    /// `org/repo#n` of its PRs.
    public var pulls: [String]
    /// `org/repo#n` of its issues.
    public var issues: [String]
    public var at: Date

    public init(
        kind: GoalLink.Kind, id: String, title: String, prompt: String = "", repos: [String] = [], branch: String = "",
        worktreePaths: [String] = [], files: [String] = [], pulls: [String] = [], issues: [String] = [], at: Date
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.prompt = prompt
        self.repos = repos
        self.branch = branch
        self.worktreePaths = worktreePaths
        self.files = files
        self.pulls = pulls
        self.issues = issues
        self.at = at
    }

    /// A session or chat as it is now, with the files its ledger entry lists.
    public init(_ session: Session, files: [String] = []) {
        self.init(
            kind: GoalLink.kind(of: session), id: session.id, title: session.title, prompt: session.prompt,
            repos: session.repos.map(\.slug), branch: session.isChat ? "" : session.branch,
            worktreePaths: session.isChat ? [] : session.worktreePaths, files: files,
            pulls: (session.trackedPRs + session.untrackedPRs).map(\.description),
            issues: session.issues.map(\.description), at: session.createdAt
        )
    }

    /// The link key it would have on a goal (`session:<id>`, `chat:<id>`).
    public var key: String { "\(kind.rawValue):\(id)" }

    /// The worktree folder names it works in.
    public var worktreeNames: [String] { worktreePaths.map { ($0 as NSString).lastPathComponent } }
}

/// What a goal already has, for comparing a newcomer with: its `GOAL.md` and what the things on it have in common.
public struct GoalContext: Hashable, Sendable {
    public var goal: HeedGoal
    public var doc: GoalDoc
    public var repos: Set<String>
    public var branches: Set<String>
    public var worktreePaths: Set<String>
    public var files: Set<String>
    public var pulls: Set<String>
    public var issues: Set<String>
    /// When something last happened on it (a link made, a session on it active, a version saved).
    public var lastActivity: Date?

    public init(
        goal: HeedGoal, doc: GoalDoc, repos: Set<String> = [], branches: Set<String> = [],
        worktreePaths: Set<String> = [], files: Set<String> = [], pulls: Set<String> = [], issues: Set<String> = [],
        lastActivity: Date? = nil
    ) {
        self.goal = goal
        self.doc = doc
        self.repos = repos
        self.branches = branches
        self.worktreePaths = worktreePaths
        self.files = files
        self.pulls = pulls
        self.issues = issues
        self.lastActivity = lastActivity
    }

    /// Each active goal with what is on it: the subjects of the sessions and chats linked to it (open or closed),
    /// and the PRs linked to it directly.
    public static func build(snapshot: GoalSnapshot, subjects: [String: AttachSubject]) -> [GoalContext] {
        snapshot.ordered.filter { $0.status == .active }.map { goal in
            var context = GoalContext(
                goal: goal, doc: snapshot.docs[goal.id] ?? GoalDoc(title: goal.title), lastActivity: goal.updatedAt
            )
            for link in snapshot.links(of: goal.id) {
                context.lastActivity = max(context.lastActivity ?? link.at, link.at)
                if link.kind == .pr { context.pulls.insert(link.target) }
                guard let subject = subjects[link.key] else { continue }
                context.repos.formUnion(subject.repos)
                if !subject.branch.isEmpty { context.branches.insert(subject.branch) }
                context.worktreePaths.formUnion(subject.worktreePaths)
                context.files.formUnion(subject.files)
                context.pulls.formUnion(subject.pulls)
                context.issues.formUnion(subject.issues)
                context.lastActivity = max(context.lastActivity ?? subject.at, subject.at)
            }
            return context
        }
    }
}

/// One reason a thing may belong to a goal, and how much it says (0–1).
public struct AttachSignal: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case worktree, branch, family, files, pull, issue, terms, repo, recency
    }

    public var kind: Kind
    public var weight: Double
    public var reason: String

    public init(_ kind: Kind, _ weight: Double, _ reason: String) {
        self.kind = kind
        self.weight = weight
        self.reason = reason
    }
}

/// A goal a thing may belong to, how sure heed is (0–1), and why.
public struct AttachCandidate: Hashable, Sendable, Codable {
    public var goal: String
    public var confidence: Double
    public var signals: [AttachSignal]
    /// Its repos and the goal's have nothing in common: the confidence was damped.
    public var otherRepo: Bool

    public init(goal: String, confidence: Double, signals: [AttachSignal], otherRepo: Bool = false) {
        self.goal = goal
        self.confidence = confidence
        self.signals = signals
        self.otherRepo = otherRepo
    }

    /// The reasons, strongest first, in a line.
    public var reason: String {
        var parts = signals
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.kind.rawValue < $1.kind.rawValue }
            .map(\.reason)
        if otherRepo { parts.append("other repo") }
        return parts.joined(separator: " · ")
    }
}

/// The free, local signals (plan pipeline 1): where the work is, what it touched, what it links to, what it was asked,
/// and when. Each signal has a weight; a goal's confidence combines them as independent evidence,
/// `1 − Π(1 − weight)`, so two middling signals agree into a strong one and no number of weak ones reaches certainty.
/// Work in repos the goal has never seen is damped (`× otherRepoFactor`). No model, no IO: a function of its inputs.
public enum AttachSignals {
    /// Same worktree folder as something on the goal.
    public static let worktreeWeight = 0.9
    /// The same branch (not a default one).
    public static let branchWeight = 0.85
    /// A branch or worktree of the same family (`feature/anchors-redirects`, `anchors-validator`: `anchors`).
    public static let familyWeight = 0.65
    /// A PR of its is on the goal already.
    public static let pullWeight = 0.9
    public static let issueWeight = 0.8
    /// Times the share of its touched files that are on the goal already.
    public static let filesWeight = 0.8
    /// Times the share of its prompt's terms (weighed by rarity) that the goal's text has.
    public static let termsWeight = 0.6
    public static let repoWeight = 0.15
    /// For a goal active in the last `recencyWindow`, falling to nothing at its end.
    public static let recencyWeight = 0.1
    public static let recencyWindow: TimeInterval = 48 * 3600
    public static let otherRepoFactor = 0.6

    /// Branches that say nothing about the work.
    static let defaultBranches: Set<String> = ["main", "master", "trunk", "develop", "dev", "head", ""]

    /// Every active goal it may belong to, most likely first (equal ones by goal id); goals with no signal are left
    /// out, so an empty result is "none".
    public static func score(_ subject: AttachSubject, goals: [GoalContext], now: Date) -> [AttachCandidate] {
        let index = TermIndex(goals.map(\.doc))
        return goals.indices.compactMap { candidate(
            subject,
            goals[$0],
            terms: index.overlap(subject.title + "\n" + subject.prompt, with: $0),
            now: now
        ) }
        .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.goal < $1.goal }
    }

    static func candidate(
        _ subject: AttachSubject, _ goal: GoalContext, terms: (share: Double, shared: [String]), now: Date
    ) -> AttachCandidate? {
        var signals: [AttachSignal] = []
        if let path = subject.worktreePaths.first(where: goal.worktreePaths.contains) {
            signals.append(AttachSignal(
                .worktree,
                worktreeWeight,
                "same worktree \((path as NSString).lastPathComponent)"
            ))
        } else if !defaultBranches.contains(subject.branch.lowercased()), goal.branches.contains(subject.branch) {
            signals.append(AttachSignal(.branch, branchWeight, "same branch \(subject.branch)"))
        } else if let family = family(subject, goal) {
            signals.append(AttachSignal(.family, familyWeight, "branch family \(family)"))
        }
        if let pull = subject.pulls.sorted().first(where: goal.pulls.contains) {
            signals.append(AttachSignal(.pull, pullWeight, "\(pull) is on the goal"))
        }
        if let issue = subject.issues.sorted().first(where: goal.issues.contains) {
            signals.append(AttachSignal(.issue, issueWeight, "\(issue) is on the goal"))
        }
        let touched = Set(subject.files)
        let shared = touched.intersection(goal.files)
        if !shared.isEmpty {
            let share = Double(shared.count) / Double(touched.count)
            signals.append(AttachSignal(
                .files, filesWeight * share, "\(shared.count) of \(touched.count) touched files on the goal"
            ))
        }
        if terms.share > 0 {
            signals.append(AttachSignal(
                .terms, termsWeight * terms.share, "mentions " + terms.shared.prefix(3).joined(separator: ", ")
            ))
        }
        let repos = Set(subject.repos)
        let sameRepo = !repos.isDisjoint(with: goal.repos)
        if sameRepo, let repo = subject.repos.first(where: goal.repos.contains) {
            signals.append(AttachSignal(.repo, repoWeight, "same repo \(repo)"))
        }
        guard !signals.isEmpty else { return nil }
        if let last = goal.lastActivity {
            let age = now.timeIntervalSince(last)
            if age >= 0, age < recencyWindow {
                signals.append(AttachSignal(.recency, recencyWeight * (1 - age / recencyWindow), "goal active lately"))
            }
        }
        let otherRepo = !repos.isEmpty && !goal.repos.isEmpty && !sameRepo
        return AttachCandidate(
            goal: goal.goal.id, confidence: combine(signals.map(\.weight)) * (otherRepo ? otherRepoFactor : 1),
            signals: signals, otherRepo: otherRepo
        )
    }

    /// Independent evidence: `1 − Π(1 − w)`, each weight held to 0…1.
    public static func combine(_ weights: [Double]) -> Double {
        1 - weights.reduce(1) { $0 * (1 - min(1, max(0, $1))) }
    }

    /// The family the thing shares with one of the goal's branches or worktrees, if it does.
    static func family(_ subject: AttachSubject, _ goal: GoalContext) -> String? {
        let mine = Set(([subject.branch] + subject.worktreeNames).compactMap(BranchFamily.stem))
        guard !mine.isEmpty else { return nil }
        let theirs = Set((goal.branches + goal.worktreePaths.map { ($0 as NSString).lastPathComponent })
            .compactMap(BranchFamily.stem))
        return mine.intersection(theirs).sorted().first
    }
}

/// A branch's or worktree's family: its last part without a kind (`feature/`, `fix-`), then its first word, or its
/// first two when the first is short (`anchors`, `docs-nav`). Versions and numbers do not count as words.
public enum BranchFamily {
    static let kinds: Set<String> = [
        "feature", "feat", "fix", "bugfix", "bug", "hotfix", "chore", "docs-only", "spike", "wip", "refactor", "test",
        "tests", "experiment", "try", "tmp", "users", "user", "dev",
    ]

    public static func stem(_ name: String) -> String? {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        var words = words(last)
        while let first = words.first, kinds.contains(first) {
            words.removeFirst()
        }
        guard let first = words.first, !AttachSignals.defaultBranches.contains(first) else { return nil }
        if first.count < 5, words.count > 1 { return first + "-" + words[1] }
        return first.count >= 3 ? first : nil
    }

    /// The prefix a rule line matches the family with: `feature/anchors-`, `docs-nav`.
    public static func prefix(_ name: String) -> String? {
        guard let stem = stem(name) else { return nil }
        let lower = name.lowercased()
        guard let range = lower.range(of: stem) else { return stem }
        let head = String(lower[..<range.upperBound])
        return range.upperBound < lower.endIndex ? head + "-" : head
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init).filter { word in
            !(word.allSatisfy(\.isNumber) || (word.first == "v" && word.dropFirst().allSatisfy(\.isNumber)
                    && word.count > 1))
        }
    }
}

/// Words of a goal's text and how rare each is across the goals, for "the prompt mentions what the goal is about".
/// Only what a goal is counts (its title, statement, criteria, questions and decisions), never its Not the goal list.
struct TermIndex {
    private let terms: [[String: Int]]
    private let docs: [GoalDoc]
    private let frequency: [String: Int]

    init(_ docs: [GoalDoc]) {
        self.docs = docs
        terms = docs.map { Self.counts(Self.text(of: $0)) }
        var frequency: [String: Int] = [:]
        for counts in terms {
            for term in counts.keys {
                frequency[term, default: 0] += 1
            }
        }
        self.frequency = frequency
    }

    static func text(of doc: GoalDoc) -> String {
        ([doc.title, doc.goal] + doc.doneWhen.map(\.text) + doc.openQuestions + doc.decisions.map(\.text))
            .joined(separator: "\n")
    }

    /// Rarer across the goals weighs more: `log((N + 1) / (df + 1)) + 1`.
    func idf(_ term: String) -> Double {
        log(Double(docs.count + 1) / Double((frequency[term] ?? 0) + 1)) + 1
    }

    /// The share of the text's distinct terms, weighed by rarity, that the goal's text has; and those terms, rarest
    /// first.
    func overlap(_ text: String, with position: Int) -> (share: Double, shared: [String]) {
        guard terms.indices.contains(position) else { return (0, []) }
        let mine = Set(Self.terms(text))
        guard !mine.isEmpty else { return (0, []) }
        let theirs = terms[position]
        let shared = mine.filter { theirs[$0] != nil }
        let total = mine.reduce(0) { $0 + idf($1) }
        let share = shared.reduce(0) { $0 + idf($1) } / total
        return (share, shared.sorted { idf($0) != idf($1) ? idf($0) > idf($1) : $0 < $1 })
    }

    static func counts(_ text: String) -> [String: Int] {
        terms(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Lowercased words of three letters or more, without common words, a plural `s` dropped.
    static func terms(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.compactMap { word in
            var word = String(word)
            guard word.count >= 3, !stopwords.contains(word), !word.allSatisfy(\.isNumber) else { return nil }
            if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            return word
        }
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "what", "when", "why", "how", "are", "was",
        "were", "not", "but", "can", "does", "did", "has", "have", "had", "its", "it's", "our", "you", "your", "all",
        "any", "each", "one", "two", "should", "would", "could", "will", "make", "made", "get", "got", "use", "using",
        "work", "working", "please", "need", "needs", "also", "there", "their", "them", "then", "than", "out", "now",
        "new", "way", "let", "lets", "see", "look", "take", "like", "just", "only", "more", "some", "who", "which",
        "where", "while", "about", "after", "before", "over", "under", "again", "still", "every", "keep", "keeps",
        "fix", "add", "goal", "thing",
    ]
}

/// Which of a goal's items a thing attached to it works on, when that is clear: one whose links name its branch or one
/// of its PRs, else the one whose title shares the most of its words (two at least, and half the item's).
public enum AttachItems {
    public static func match(_ subject: AttachSubject, items: [GoalItem]) -> GoalItem? {
        let open = items.filter { $0.kind == .work }
        if !subject.branch.isEmpty, let item = open.first(where: { $0.linked(.branch).contains(subject.branch) }) {
            return item
        }
        if let item = open.first(where: { !Set($0.linked(.pr)).isDisjoint(with: subject.pulls) }) { return item }
        let words = Set(TermIndex.terms(subject.title + "\n" + subject.prompt))
        let scored = open.compactMap { item -> (GoalItem, Int)? in
            let title = Set(TermIndex.terms(item.title))
            let shared = title.intersection(words).count
            return shared >= 2 && shared * 2 >= title.count ? (item, shared) : nil
        }
        return scored.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id > $1.0.id }?.0
    }
}
