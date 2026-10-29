import Foundation

/// Reads a goal for a set over GitHub ("review all open PRs in acme/web", "close every issue labelled flaky") and
/// proposes the source that keeps its items: a cheap Decider call says what kind of set it is, the words say which
/// repo, label or milestone; without a model (or when the call fails) the words alone decide. Nothing is added
/// without your yes.
public enum ItemSourceDetect {
    /// What kind of set a goal is over.
    public enum Intent: String, Hashable, Sendable, CaseIterable {
        case reviewPulls = "review-prs"
        case mergePulls = "merge-prs"
        case reviewRequests = "review-requests"
        case closeIssues = "close-issues"
        case none
    }

    /// The things a source needs that only the words carry.
    public struct Words: Hashable, Sendable {
        public var repo: String?
        public var label: String?
        public var milestone: String?
        /// The sentence they were found in, for `because`.
        public var sentence: String
    }

    /// The proposal for `title` and its GOAL.md's goal statement, or nil when it does not read like a set over
    /// GitHub. `repos` are the repos the goal's sessions work in: the first stands in when the words name none.
    public static func detect(
        title: String, statement: String, repos: [String], goal: String, decider: (any Decider)?, now: Date
    ) async -> SourceProposal? {
        let text = [title, statement].filter { !$0.isEmpty }.joined(separator: ". ")
        let words = words(text)
        guard let decider else { return byWords(title: title, statement: statement, repos: repos, now: now) }
        // Only a goal that speaks of PRs, issues or reviews is worth a call.
        guard has(text.lowercased(), [
            "pr",
            "prs",
            "pull request",
            "pull requests",
            "pulls",
            "issue",
            "issues",
            "bugs",
            "review",
            "reviews",
            "milestone",
            "label",
            "labelled",
            "labeled",
        ])
        else { return nil }
        let question = Question.choice(
            instructions: "Is this goal about a set of GitHub pull requests or issues, one item each? review-prs: "
                + "review every open PR somewhere; merge-prs: get a set of PRs merged; review-requests: the PRs "
                + "that ask for my review; close-issues: close or fix a set of issues; none: anything else.",
            options: Intent.allCases.map(\.rawValue)
        )
        let state = "Goal: \(title)\n\(statement)"
        guard let answers = try? await decider.decide(
            subject: "goal:\(goal)", state: state, questions: ["set": question]
        ), let choice = answers["set"]?.choice, let intent = Intent(rawValue: choice) else {
            return byWords(title: title, statement: statement, repos: repos, now: now)
        }
        return proposal(intent, words, repos: repos, by: .model, now: now)
    }

    /// The proposal the words alone make, with no model: the fallback, and fixtures.
    public static func byWords(title: String, statement: String, repos: [String], now: Date) -> SourceProposal? {
        let text = [title, statement].filter { !$0.isEmpty }.joined(separator: ". ")
        return proposal(intent(text), words(text), repos: repos, by: .words, now: now)
    }

    /// The source an intent and its words make; nil when it has no repo to search (only review requests need none).
    static func proposal(_ intent: Intent, _ words: Words, repos: [String], by: SourceProposal.By, now: Date)
        -> SourceProposal?
    {
        let repo = words.repo ?? repos.first
        let parsed: ItemSourceQuery.Parsed?
        var rule: ItemSource.Rule
        switch intent {
        case .none:
            return nil
        case .reviewRequests:
            parsed = try? ItemSourceQuery.parse(["reviews", words.repo].compactMap(\.self).joined(separator: " "))
            rule = .reviewed
        case .reviewPulls, .mergePulls:
            guard let repo else { return nil }
            if let label = words.label {
                parsed = ItemSourceQuery.Parsed(
                    query: "is:pr is:open label:\(ItemSourceQuery.quoted(label)) repo:\(repo)",
                    label: "open PRs labelled \(label) in \(repo)", rule: .merged
                )
            } else {
                parsed = try? ItemSourceQuery.parse("prs \(repo)")
            }
            rule = intent == .reviewPulls ? .reviewed : .merged
        case .closeIssues:
            if let milestone = words.milestone, let repo {
                parsed = ItemSourceQuery.Parsed(
                    query: "is:issue is:open milestone:\(ItemSourceQuery.quoted(milestone)) repo:\(repo)",
                    label: "open issues in milestone \(milestone) of \(repo)", rule: .closed
                )
            } else if let label = words.label {
                parsed = ItemSourceQuery.Parsed(
                    query: "is:issue is:open label:\(ItemSourceQuery.quoted(label))" +
                        (repo.map { " repo:\($0)" } ?? ""),
                    label: "open issues labelled \(label)" + (repo.map { " in \($0)" } ?? ""), rule: .closed
                )
            } else if let repo {
                parsed = try? ItemSourceQuery.parse("issues \(repo)")
            } else {
                parsed = nil
            }
            rule = .closed
        }
        guard let parsed else { return nil }
        return SourceProposal(
            source: ItemSource(query: parsed.query, label: parsed.label, rule: rule, origin: .proposal, addedAt: now),
            because: words.sentence, by: by
        )
    }

    // MARK: The words

    private static let sets = ["all", "every", "each", "any", "the open", "open"]

    /// The intent the words alone show: a verb and a set of PRs or issues ("review all open PRs", "close every
    /// issue labelled flaky", "PRs that ask for my review").
    public static func intent(_ text: String) -> Intent {
        let lower = text.lowercased()
        let prs = has(lower, ["prs", "pr", "pull requests", "pull request", "pull-requests", "pulls"])
        let issues = has(lower, ["issues", "issue", "bugs"])
        if prs, has(lower, [
            "review requests",
            "requesting my review",
            "ask for my review",
            "asks for my review",
            "requested my review",
            "review-requested",
            "waiting on my review",
            "asking for my review",
        ]) {
            return .reviewRequests
        }
        let set = sets.contains { lower.contains($0 + " ") }
        if prs, set, has(lower, ["review", "reviewed", "look at", "go through", "triage"]) { return .reviewPulls }
        if prs, set,
           has(lower, ["merge", "merged", "land", "landed", "get in", "ship", "shipped"]) { return .mergePulls }
        if issues, set, has(
            lower,
            ["close", "closed", "fix", "fixed", "resolve", "resolved", "triage", "answer", "burn down", "clear"]
        ) {
            return .closeIssues
        }
        return .none
    }

    /// The repo (`org/name`), label and milestone the words name, and the sentence they are in.
    public static func words(_ text: String) -> Words {
        let sentence = text.split(whereSeparator: { ".\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                let lower = line.lowercased()
                return has(lower, ["pr", "pull request", "issue", "review"])
            } ?? text
        let repo = text.split(whereSeparator: { $0.isWhitespace || ",;()`'\"“”".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .first { word in
                !word.contains("://") && word.split(separator: "/").count == 2 && TrackerCheck.slug(word) != nil
                    && word.first?.isLetter == true
            }
        return Words(
            repo: repo,
            label: first(text, [
                #"label:\s*"([^"]+)""#,
                #"label:\s*(\S+)"#,
                #"label(?:led|ed)\s+[“"']([^”"']+)[”"']"#,
                #"label(?:led|ed)\s+([\w\-]+)"#,
                #"with the [“"']?([\w\- ]+?)[”"']? label"#,
            ]),
            milestone: first(text, [#"milestone\s+[“"']([^”"']+)[”"']"#, #"milestone\s+(v?[\w.\-]+)"#]),
            sentence: String(sentence.prefix(120))
        )
    }

    private static func has(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { needle in
            var from = text.startIndex
            while let range = text.range(of: needle, range: from ..< text.endIndex) {
                // Whole words: "pr" is not "print".
                let before = range.lowerBound == text.startIndex ? " " : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? " " : text[range.upperBound]
                if !before.isLetter, !after.isLetter { return true }
                from = range.upperBound
            }
            return false
        }
    }

    private static func first(_ text: String, _ patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: text)
            else { continue }
            let value = text[range].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
