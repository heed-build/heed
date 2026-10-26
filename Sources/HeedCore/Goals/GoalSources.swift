import Foundation

/// The planner (`SummaryKind.goalPlan`): a goal broken into planned items, on a new goal and on each version that
/// changes its scope.
public enum GoalPlanner {
    /// What the model reads: the goal's GOAL.md and the items it has.
    public static func inputs(title: String, doc text: String, items: [GoalItem]) -> SummaryInputs {
        SummaryInputs(title: title, goal: text, known: items.map(\.title))
    }

    /// The `- ` lines of the answer, as titles: numbered lines and `*` bullets too, at most eight, no repeats.
    public static func titles(_ answer: String) -> [String] {
        var titles: [String] = []
        for item in GoalDoc.bullets(answer.components(separatedBy: "\n")) {
            var title = GoalDoc.oneLine(item.text).trimmingCharacters(in: CharacterSet(charactersIn: " .*_`"))
            if title.lowercased() == "none" || title.isEmpty || title.hasSuffix(":") { continue }
            if title.count > 80 { title = String(title.prefix(79)) + "…" }
            if !titles.contains(where: { GoalEdits.same($0, title) }) { titles.append(title) }
        }
        return Array(titles.prefix(8))
    }

    /// Whether a new version changes what the planner reads: the goal, what it is not, when it is done.
    public static func scopeChanged(from old: GoalDoc?, to new: GoalDoc) -> Bool {
        guard let old else { return true }
        return old.goal != new.goal || old.notTheGoal != new.notTheGoal || old.doneWhen.map(\.text) != new.doneWhen
            .map(\.text)
    }
}

/// Whether a title found in the work is an item the goal already has.
public enum GoalItemMatch {
    /// A title matched against the goal's items.
    public enum Outcome: Hashable, Sendable {
        /// The same work as `item`.
        case existing(item: String, confidence: Double)
        /// New work, this sure.
        case new(confidence: Double)
    }

    /// At or above: the same item without asking. Below `differentBelow`: new without asking. Between: the Decider.
    public static let sameAbove = 0.75
    public static let differentBelow = 0.25

    /// How alike two titles are, 0–1: the share of their words in common (case, punctuation and small words aside).
    public static func similarity(_ one: String, _ other: String) -> Double {
        let left = words(one)
        let right = words(other)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        let shared = left.intersection(right).count
        return Double(shared) / Double(left.union(right).count)
    }

    static let small: Set<String> = [
        "a", "an", "the", "of", "to", "for", "in", "on", "and", "or", "with", "is", "it", "be", "by", "at", "as",
    ]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !small.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// The decision without a model: sure matches and sure misses; nil when it is close enough to ask.
    public static func quick(_ title: String, items: [GoalItem]) -> Outcome? {
        let scored = items.map { ($0.id, similarity(title, $0.title)) }
        guard let best = scored.max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }) else {
            return .new(confidence: 1)
        }
        if best.1 >= sameAbove { return .existing(item: best.0, confidence: best.1) }
        if best.1 < differentBelow { return .new(confidence: 1 - best.1) }
        return nil
    }

    /// The decision, asking `decider` when the words alone do not settle it. A failed call errs toward the closest
    /// item when it is at least half alike, so a flaky model does not fill the board with near copies.
    public static func decide(
        _ title: String, items: [GoalItem], goal: String, decider: (any Decider)?
    ) async -> Outcome {
        if let quick = quick(title, items: items) { return quick }
        let candidates = items.map { ($0, similarity(title, $0.title)) }.sorted { $0.1 > $1.1 }.prefix(5)
        let fallback: Outcome = if let closest = candidates.first, closest.1 >= 0.5 {
            .existing(item: closest.0.id, confidence: closest.1)
        } else {
            .new(confidence: 0.5)
        }
        guard let decider else { return fallback }
        var options = candidates.map { "\($0.0.slug)" }
        options.append("new")
        let state = "Goal: \(goal)\nFound in the work: \(title)\nItems the goal has:\n"
            + candidates.map { "- \($0.0.slug): \($0.0.title)" }.joined(separator: "\n")
        let question = Question.choice(
            instructions: "Is what was found the same work as one of the goal's items (pick its id), or new work "
                + "(new)?",
            options: options
        )
        let answers = try? await decider.decide(subject: "goal:\(goal)", state: state, questions: ["same": question])
        guard let answer = answers?["same"], let choice = answer.choice else { return fallback }
        let confidence = answer.probabilities[choice] ?? answer.confidence
        if choice == "new" { return .new(confidence: confidence) }
        guard let item = candidates.first(where: { $0.0.slug == choice })?.0 else { return fallback }
        return .existing(item: item.id, confidence: confidence)
    }
}

/// What a ledger entry of a session or chat on a goal says for the goal: follow-ups become items, questions become
/// To explore cards, decisions go into GOAL.md.
public struct GoalDiscovery: Hashable, Sendable {
    public var items: [String]
    public var questions: [String]
    public var decisions: [String]

    public static func from(_ entry: LedgerEntry) -> GoalDiscovery {
        func clean(_ lines: [String]) -> [String] {
            lines.map(GoalDoc.oneLine).filter { !$0.isEmpty && $0.lowercased() != "none" }
        }
        let followUps = clean(entry.followUps)
        return GoalDiscovery(
            items: followUps.filter { !$0.hasSuffix("?") }, questions: followUps.filter { $0.hasSuffix("?") },
            decisions: clean(entry.decisions)
        )
    }
}

/// PRs on a goal's work: what they say about its items. A PR on a linked branch puts its item in Verify; merged, in
/// Done.
public enum GoalPulls {
    /// A PR that belongs to the goal, the item it is about (nil: an item is made for it), and what it shows.
    public struct Finding: Hashable, Sendable {
        public var ref: PullRef
        public var title: String
        public var item: String?
        /// The session whose branch or tracking brought it in.
        public var session: String?
        public var evidence: [GoalEvidence]
    }

    /// The goal's PRs: the ones its sessions track or have a branch for, and the ones linked to it or its items.
    public static func findings(
        goal: String, links: [GoalLink], items: [GoalItem], sessions: [Session], pulls: [PullRequest], now: Date
    ) -> [Finding] {
        let goalSessions = links.filter { $0.goal == goal && ($0.kind == .session || $0.kind == .chat) }
        var found: [Finding] = []
        var seen: Set<PullRef> = []
        for pull in pulls.sorted(by: { $0.ref.description < $1.ref.description }) {
            let ref = pull.ref
            let itemByLink = items.first { item in
                item.linked(.pr).contains(ref.description) || item.linked(.branch).contains(pull.headBranch)
            }
            let session = goalSessions.first { link in
                guard let session = sessions.first(where: { $0.id == link.target }) else { return false }
                return session.trackedPRs.contains(ref)
                    || session.repos.contains(ref.repo) && session.branches.contains(pull.headBranch)
            }
            let linked = links.contains { $0.goal == goal && $0.kind == .pr && $0.target == ref.description }
            guard itemByLink != nil || session != nil || linked, !seen.contains(ref) else { continue }
            seen.insert(ref)
            let item: String? = itemByLink?.id ?? session.flatMap { link in
                link.item ?? items.first { $0.linked(.session).contains(link.target) }?.id
            }
            found.append(Finding(
                ref: ref, title: pull.title, item: item, session: session?.target,
                evidence: evidence(pull, goal: goal, item: item, now: now)
            ))
        }
        return found
    }

    /// What a PR shows: opened (a draft is in progress, failing checks are an issue), merged, or closed unmerged.
    public static func evidence(_ pull: PullRequest, goal: String, item: String?, now: Date) -> [GoalEvidence] {
        let ref = pull.ref.description
        let source = "#\(pull.ref.number)"
        func entry(_ kind: GoalEvidence.Kind, _ state: GoalEvidence.State, _ text: String) -> GoalEvidence {
            GoalEvidence(
                goal: goal,
                item: item,
                kind: kind,
                state: state,
                at: now,
                source: source,
                text: text,
                ref: ref
            )
        }
        switch pull.state {
        case .merged:
            return [entry(.pr, .done, "\(source) merged"), entry(.merged, .done, "\(source) merged")]
        case .closed:
            return [entry(.pr, .issue, "\(source) closed without merging")]
        case .open:
            if pull.checks.failed > 0 { return [entry(.pr, .issue, "\(source) open · CI failing")] }
            if pull.isDraft { return [entry(.pr, .inProgress, "\(source) draft")] }
            let ci = pull.checks.pending > 0 ? "CI running" : pull.checks.passed > 0 ? "CI ok" : "open"
            return [entry(.pr, .done, "\(source) open · \(ci)")]
        }
    }

    /// The evidence not yet recorded: what differs from the newest of its kind for the item.
    public static func fresh(_ evidence: [GoalEvidence], known: [GoalEvidence]) -> [GoalEvidence] {
        evidence.filter { entry in
            let last = known.filter { $0.item == entry.item && $0.kind == entry.kind && $0.ref == entry.ref }
                .max { Stages.newer($1, than: $0) }
            return last.map { $0.state != entry.state || $0.text != entry.text } ?? true
        }
    }
}

/// The proposer's and the sharpener's answer, read into edits.
public enum GoalEditProposer {
    /// What the model reads: the goal's GOAL.md, and what the work found.
    public static func inputs(goal title: String, doc text: String, entry: LedgerEntry, lastMessage: String?)
        -> SummaryInputs
    {
        var lines: [String] = []
        if let summary = entry.summary { lines.append("Summary: \(summary)") }
        lines += entry.decisions.map { "Decision: \($0)" }
        lines += entry.followUps.map { "Follow-up: \($0)" }
        lines += entry.pulls.map { "PR: \($0.description)" }
        return SummaryInputs(
            title: "\(entry.title) (on the goal \(title))", timeline: lines, lastMessage: lastMessage, goal: text
        )
    }

    /// `{"edits": [...]}` to edits; entries that do not name a known section and op, or have no text, are dropped.
    /// The kind is never read from the answer: `GoalEdits.classify` decides it, and `scopeOnly` makes every one wait.
    public static func edits(_ answer: String, goal: String, from: String, now: Date, scopeOnly: Bool = false)
        -> [GoalEdit]
    {
        guard let data = LLMDialect.jsonObject(in: answer),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["edits"] as? [[String: Any]]
        else { return [] }
        return list.prefix(8).compactMap { entry in
            func string(_ key: String) -> String? {
                (entry[key] as? String).map(GoalDoc.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let section = string("section").flatMap(section), let op = string("op").flatMap(GoalEdit.Op.init),
                  let text = string("text") ?? string("target")
            else { return nil }
            var edit = GoalEdit(
                goal: goal, section: section, op: op, text: text, target: string("target"),
                evidence: string("evidence"), from: from, reason: string("reason"), at: now
            )
            if scopeOnly { edit.kind = .scope }
            return edit
        }
    }

    /// A section as models write it: `notTheGoal`, `not the goal`, `done_when`, `Decisions`.
    static func section(_ name: String) -> GoalEdit.Section? {
        let key = name.lowercased().filter(\.isLetter)
        return GoalEdit.Section.allCases.first { $0.rawValue.lowercased() == key }
            ?? [
                "nongoals": .notTheGoal,
                "nongoal": .notTheGoal,
                "questions": .openQuestions,
                "decision": .decisions,
                "criteria": .doneWhen,
                "criterion": .doneWhen,
            ][key]
    }
}

/// A goal's model calls in a day: the planner, the proposer and the sharpener share it.
public enum GoalBudget {
    public static let daily = 6

    /// Whether one more call may go today, after `runs`.
    public static func allows(runs: [Date], now: Date, limit: Int = daily, calendar: Calendar = .current) -> Bool {
        runs.count { calendar.isDate($0, inSameDayAs: now) } < limit
    }
}
