import Foundation

/// Who may answer a swarm's question, by what the question is about, never by how sure a model is. The owner decided
/// (2026-10-28): the controller answers reversible implementation choices, reassigning idle agents and repeats of
/// questions you answered before; it always asks you about the goal, limits, deleting data, merging to main, and more
/// agents or time. The lead answers workers' scope questions (its structural plan changes still wait for you).
///
/// The category comes from the question's words and its options, so an agent cannot talk its way past it: a question
/// that mentions deleting data is yours whatever else it says. What the words do not place goes to you too.
public enum SwarmAuthority {
    public enum Category: String, Hashable, Sendable, Codable, CaseIterable {
        /// Always yours.
        case goal, limits, deleteData, mergeMain, moreAgentsOrTime
        /// The plan and its scope: a worker's goes to the lead first, the lead's to you.
        case scope
        /// A reversible implementation choice: naming, defaults, test strategy.
        case implementation
        /// Reassigning an idle agent.
        case reassign
        /// Nothing the words place: yours, after a peer if one was asked.
        case other

        /// Only you answer it (a repeat of your earlier answer does not either).
        public var alwaysYou: Bool {
            switch self {
            case .goal, .limits, .deleteData, .mergeMain, .moreAgentsOrTime: true
            case .scope, .implementation, .reassign, .other: false
            }
        }

        /// The controller may answer it.
        public var controllerMay: Bool { self == .implementation || self == .reassign }

        /// `the goal`, `deleting data`, `a reversible implementation choice`.
        public var title: String {
            switch self {
            case .goal: "the goal"
            case .limits: "limits"
            case .deleteData: "deleting data"
            case .mergeMain: "merging to main"
            case .moreAgentsOrTime: "more agents or time"
            case .scope: "the plan's scope"
            case .implementation: "a reversible implementation choice"
            case .reassign: "reassigning an idle agent"
            case .other: "a question heed cannot place"
            }
        }
    }

    /// A step of the ladder: who answers there.
    public enum Answerer: String, Hashable, Sendable, Codable, CaseIterable {
        /// The task owning the nearest work (`--to <task>`, or the one the asker's task waits for).
        case peer
        case lead
        /// heed's deciders (Settings › Inference & decisions), within its authority.
        case controller
        case you

        public var title: String {
            switch self {
            case .peer: "a peer"
            case .lead: "the lead"
            case .controller: "the controller"
            case .you: "you"
            }
        }
    }

    /// Who asks.
    public enum Asker: Equatable, Sendable {
        case lead
        /// A worker on a task (its item id).
        case worker(String)
        /// Another session on the goal, or a terminal.
        case other
    }

    /// Whom the asker addressed (`--to`).
    public enum Target: Equatable, Sendable {
        case lead, you
        case task(String)
    }

    /// Who may answer, in the order the ladder asks them.
    public struct Verdict: Equatable, Sendable {
        public var category: Category
        public var ladder: [Answerer]
        /// The task asked at the peer step.
        public var peer: String?
        /// Why, in a line: `deleting data: only you answer it`.
        public var reason: String

        public init(category: Category, ladder: [Answerer], peer: String? = nil, reason: String) {
            self.category = category
            self.ladder = ladder
            self.peer = peer
            self.reason = reason
        }

        public var mayAnswer: Set<Answerer> { Set(ladder) }
    }

    // MARK: Classifying

    /// The question's category from its words and options. The categories that are always yours are checked first, so
    /// a question touching one of them is yours whatever else it touches.
    public static func category(_ text: String, options: [String] = []) -> Category {
        let words = " " + ([text] + options).map(SwarmRepeat.normalised).joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" \($0) ") } }
        let raw = ([text] + options).joined(separator: " ")
        if has(deleting) { return .deleteData }
        if has(merging), has(mainBranch) { return .mergeMain }
        if has(limitWords) || raw.contains("$") { return .limits }
        if has(moreWords) { return .moreAgentsOrTime }
        if has(goalWords) { return .goal }
        if has(scopeWords) { return .scope }
        if has(reassignWords) { return .reassign }
        if has(implementationWords) { return .implementation }
        return .other
    }

    /// Who may answer, in order. `peer`: the task a worker's question goes to first, when it was addressed (`--to`) or
    /// inferred (the nearest work, whose worker is at work); nil when there is none.
    public static func classify(
        _ text: String, options: [String] = [], asker: Asker, to target: Target? = nil, peer: String? = nil
    ) -> Verdict {
        let category = category(text, options: options)
        if category.alwaysYou {
            return Verdict(category: category, ladder: [.you], reason: "\(category.title): only you answer it")
        }
        if target == .you { return Verdict(category: category, ladder: [.you], reason: "asked of you") }
        // Addressed to a task: that task is the peer; to the lead: the lead, and no peer inferred.
        let addressed: String? = if case let .task(task) = target { task } else { nil }
        let peer = addressed ?? (target == .lead ? nil : peer)
        let peerStep: [Answerer] = peer == nil ? [] : [.peer]
        switch category {
        case .scope:
            if case .worker = asker {
                return Verdict(
                    category: category, ladder: [.lead, .you],
                    reason: "the plan's scope: the lead answers a worker's, its structural changes wait for you"
                )
            }
            return Verdict(category: category, ladder: [.you], reason: "the plan's scope: the lead's is yours")
        case .implementation, .reassign:
            let lead: [Answerer] = target == .lead && asker != .lead ? [.lead] : []
            return Verdict(
                category: category, ladder: lead + peerStep + [.controller, .you], peer: peer,
                reason: "\(category.title): the controller may answer it"
            )
        case .other:
            let lead: [Answerer] = target == .lead && asker != .lead ? [.lead] : []
            return Verdict(
                category: category, ladder: lead + peerStep + [.you], peer: peer,
                reason: "heed cannot place it: yours" + (peer == nil && lead.isEmpty ? "" : ", after who was asked")
            )
        case .goal, .limits, .deleteData, .mergeMain, .moreAgentsOrTime:
            preconditionFailure("always yours, answered above")
        }
    }

    /// Whether the controller may answer the question with a repeat of an answer of yours: anything but what is
    /// always yours.
    public static func mayRepeat(_ category: Category) -> Bool { !category.alwaysYou }

    // MARK: The words

    static let deleting = [
        "delete", "deletes", "deleting", "deletion", "drop table", "drop the table", "drop column", "drop the column",
        "drop database", "drop the database", "wipe", "wiping", "purge", "purging", "truncate", "erase", "destroy",
        "rm rf", "remove data", "remove the data", "data loss", "lose data", "force push", "force pushing",
        "push force", "reset hard",
    ]
    static let merging = ["merge", "merges", "merging", "merged", "push", "pushing", "land", "landing"]
    static let mainBranch = ["main", "master", "default branch", "trunk"]
    static let limitWords = [
        "limit", "limits", "budget", "budgets", "spend", "spending", "cost", "costs", "dollar", "dollars", "usd",
        "quota",
    ]
    static let moreWords = [
        "more agents", "another agent", "extra agent", "more workers", "another worker", "extra worker", "spawn",
        "more time", "more hours", "extra time", "extra hours", "extend", "extension", "deadline",
    ]
    static let goalWords = [
        "goal", "goals", "goal md", "non goal", "not the goal", "done when", "success criteria", "criterion",
    ]
    static let scopeWords = [
        "scope", "out of scope", "in scope", "split", "add a task", "new task", "another task", "drop the task",
        "drop task", "remove the task", "plan", "replan", "re plan", "reorder", "separate task", "separate pr",
        "follow up", "phase",
    ]
    static let reassignWords = ["reassign", "re assign", "idle", "take over", "hand over", "hand off", "handoff"]
    static let implementationWords = [
        "name", "names", "naming", "rename", "call it", "called", "default", "defaults", "test", "tests", "testing",
        "unit test", "fixture", "fixtures", "mock", "mocks", "stub", "format", "formatting", "style", "convention",
        "warn", "warning", "log level", "flag",
    ]
}
