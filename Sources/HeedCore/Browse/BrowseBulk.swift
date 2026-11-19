import Foundation

/// A change made to every picked item on GitHub: labels added, the item assigned to you, a comment, a close. A plan
/// says what each item would get before anything is written (`BrowsePlan`); a report says what each got after
/// (`BrowseReport`). Nothing here is hidden behind the confirm step: every line of the plan is a write.
public enum BrowseBulkAction: Equatable, Sendable {
    public enum CloseReason: String, Equatable, Sendable, CaseIterable {
        case completed, notPlanned = "not planned"
        public var apiValue: String { self == .notPlanned ? "not_planned" : "completed" }
    }

    case label([String])
    case assignMe(String?)
    case comment(String)
    case close(CloseReason)

    public static let caller = "browse.bulk"

    /// `Label`, `Assign to me`, `Comment on all`, `Close as...`
    public var title: String {
        switch self {
        case .label: "Label"
        case .assignMe: "Assign to me"
        case .comment: "Comment on all"
        case .close: "Close as…"
        }
    }
}

/// What a plan does to one item: a write, or why nothing is written.
public struct BrowseStep: Equatable, Sendable {
    public var itemID: String
    public var place: String
    public var isPull: Bool
    /// What the write does, as a line of the confirm step; nil when the item is left alone.
    public var change: String?
    /// Why the item is left alone.
    public var skipped: String?
}

public struct BrowsePlan: Equatable, Sendable {
    public var action: BrowseBulkAction
    public var steps: [BrowseStep]
    /// Why the action cannot be run at all (no label typed, no login known), else nil.
    public var blocked: String?

    public var writes: [BrowseStep] { steps.filter { $0.change != nil } }

    /// The question the confirm step asks: `Add bug to 3 items on GitHub?`
    public var headline: String {
        let count = writes.count
        let noun = "\(count) item\(count == 1 ? "" : "s")"
        switch action {
        case let .label(names): return "Add \(names.map { "“\($0)”" }.joined(separator: ", ")) to \(noun) on GitHub?"
        case .assignMe: return "Assign \(noun) to you on GitHub?"
        case .comment: return "Post this comment on \(noun) on GitHub?"
        case let .close(reason):
            let pulls = writes.filter(\.isPull).count
            return "Close \(noun) as \(reason.rawValue)"
                + (pulls > 0 ? " (\(pulls) pull request\(pulls == 1 ? "" : "s") closed without merging)" : "") + "?"
        }
    }

    /// The lines under it: one per item, what changes or why not.
    public var lines: [String] {
        steps.map { step in
            step.change.map { "\(step.place)  \($0)" } ?? "\(step.place)  left alone: \(step.skipped ?? "nothing to do")"
        }
    }

    /// The comment's text, when the action is one.
    public var commentBody: String? {
        if case let .comment(text) = action { return text }
        return nil
    }
}

public enum BrowseOutcome: Equatable, Sendable {
    case done
    case skipped(String)
    case failed(String)
}

/// What each item got, and the line that says so.
public struct BrowseReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var itemID: String
        public var place: String
        public var outcome: BrowseOutcome
    }

    public var action: BrowseBulkAction
    public var entries: [Entry]

    public var done: Int { entries.count(where: { $0.outcome == .done }) }
    public var failed: [Entry] { entries.filter { if case .failed = $0.outcome { true } else { false } } }
    public var skipped: Int { entries.count(where: { if case .skipped = $0.outcome { true } else { false } }) }

    /// `Labelled 3 of 4 items. 1 failed.`
    public var summary: String {
        let verb = switch action {
        case .label: "Labelled"
        case .assignMe: "Assigned"
        case .comment: "Commented on"
        case .close: "Closed"
        }
        var text = "\(verb) \(done) of \(entries.count) item\(entries.count == 1 ? "" : "s")."
        if skipped > 0 { text += " \(skipped) left alone." }
        if !failed.isEmpty { text += " \(failed.count) failed." }
        return text
    }

    /// Whether every write that was tried worked.
    public var clean: Bool { failed.isEmpty }

    /// `acme/docs#12  failed: ...` per entry.
    public var lines: [String] {
        entries.map { entry in
            switch entry.outcome {
            case .done: "\(entry.place)  done"
            case let .skipped(why): "\(entry.place)  left alone: \(why)"
            case let .failed(why): "\(entry.place)  failed: \(why)"
            }
        }
    }
}

public enum BrowseBulk {
    /// More than this many sessions at once asks first.
    public static let eachCap = 5

    public static func eachNeedsConfirm(_ count: Int) -> Bool { count > eachCap }

    /// What `action` would do to each of `items`: nothing is written to build it.
    public static func plan(_ action: BrowseBulkAction, items: [BrowseItem]) -> BrowsePlan {
        var blocked: String?
        let steps: [BrowseStep] = items.map { item in
            var step = BrowseStep(itemID: item.id, place: item.place, isPull: item.kind == .pull)
            switch action {
            case let .label(names):
                let missing = names
                    .filter { name in !item.labels.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                if missing.isEmpty { step.skipped = "already has \(names.joined(separator: ", "))" } else {
                    step.change = "adds \(missing.joined(separator: ", "))"
                }
            case let .assignMe(login):
                if let login {
                    if item.assignees.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
                        step.skipped = "already assigned to you"
                    } else { step.change = "assigns @\(login)" }
                }
            case let .comment(text):
                step.change = "comments “\(oneLine(text, 60))”"
            case let .close(reason):
                if item.state != .open { step.skipped = "already \(item.state.rawValue)" } else {
                    step.change = item.kind == .pull ? "closes without merging" : "closes as \(reason.rawValue)"
                }
            }
            return step
        }
        switch action {
        case let .label(names) where names.isEmpty: blocked = "type a label first"
        case .assignMe(nil): blocked = "heed does not know your GitHub login yet"
        case let .comment(text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            blocked = "type the comment first"
        default: break
        }
        if items.isEmpty { blocked = "nothing is picked" }
        return BrowsePlan(action: action, steps: steps, blocked: blocked)
    }

    static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// The `gh` arguments that write `step` (the comment goes through `GitHub.comment`, so none here). Repo and
    /// number come from the item; labels and logins are passed as separate fields, never joined into a path.
    public static func arguments(_ action: BrowseBulkAction, item: BrowseItem) -> [String]? {
        let path = "repos/\(item.repo.slug)/issues/\(item.number)"
        switch action {
        case let .label(names):
            return ["api", "-X", "POST", "\(path)/labels"] + names.flatMap { ["-f", "labels[]=\($0)"] }
        case let .assignMe(login):
            guard let login else { return nil }
            return ["api", "-X", "POST", "\(path)/assignees", "-f", "assignees[]=\(login)"]
        case .comment: return nil
        case let .close(reason):
            // A pull request has no reason: GitHub takes only the state.
            return ["api", "-X", "PATCH", path, "-f", "state=closed"]
                + (item.kind == .pull ? [] : ["-f", "state_reason=\(reason.apiValue)"])
        }
    }

    /// Writes the plan, one item at a time, and reports each. A failed item does not stop the rest.
    public static func run(
        _ plan: BrowsePlan, items: [BrowseItem],
        write: @Sendable (BrowseBulkAction, BrowseItem) async throws -> Void = BrowseBulk.write
    ) async -> BrowseReport {
        var entries: [BrowseReport.Entry] = []
        for step in plan.steps {
            guard step.change != nil, let item = items.first(where: { $0.id == step.itemID }) else {
                entries.append(.init(
                    itemID: step.itemID, place: step.place, outcome: .skipped(step.skipped ?? "nothing to do")
                ))
                continue
            }
            do {
                try await write(plan.action, item)
                entries.append(.init(itemID: step.itemID, place: step.place, outcome: .done))
            } catch {
                entries.append(.init(itemID: step.itemID, place: step.place, outcome: .failed("\(error)")))
            }
        }
        return BrowseReport(action: plan.action, entries: entries)
    }

    /// The real write: gh, `write: true`, caller `browse.bulk`.
    public static func write(_ action: BrowseBulkAction, item: BrowseItem) async throws {
        if case let .comment(body) = action {
            return try await GitHub.comment(
                repo: item.repo,
                number: item.number,
                body: body,
                caller: BrowseBulkAction.caller
            )
        }
        guard let arguments = arguments(action, item: item)
        else { throw GitHub.Failure(description: "nothing to write") }
        let result = try await GitHub.gh(
            arguments, operation: "\(arguments[2]) issues", write: true, shown: arguments,
            timeout: .seconds(30), caller: BrowseBulkAction.caller
        )
        guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
    }

    // MARK: What an agent is told, and what a goal starts from

    /// A goal from the picked items: its title and statement name the items by place only (no one else's words), the
    /// items go on it one each.
    public static func goalDraft(_ items: [BrowseItem]) -> (title: String, statement: String) {
        let repos = Array(Set(items.map(\.repo.name))).sorted()
        let title = repos.count == 1
            ? "\(items.count) items in \(repos[0])" : "\(items.count) items across \(repos.count) repos"
        let statement = "Work through these GitHub items and close them:\n"
            + items.map { "- \($0.place) \($0.url)" }.joined(separator: "\n")
        return (title, statement)
    }
}

public extension BrowseBulk {
    /// The item as it stands after `action` was written to it: labels added, you assigned, closed. The list shows it
    /// at once; the next fetch confirms it.
    static func updated(_ item: BrowseItem, by action: BrowseBulkAction) -> BrowseItem {
        var item = item
        switch action {
        case let .label(names):
            for name in names where !item.labels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                item.labels.append(name)
            }
        case let .assignMe(login):
            if let login, !item.assignees.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
                item.assignees.append(login)
            }
        case .comment: item.comments += 1
        case .close: item.state = .closed
        }
        return item
    }
}
