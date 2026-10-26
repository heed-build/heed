import Foundation

/// A goal's GitHub mirror as heed last left it: whether it is on, the meta issue and each item's sub-issue as heed last
/// wrote them, what it has read back, and the colleague changes waiting for you. heed is the source of truth: the
/// mirror only ever follows the goal, and what colleagues do there comes back as asks and proposals, never as changes.
///
/// Kept in `goal_mirrors` (one JSON row per goal). The issue numbers are also in `goals.tracker_issue` and
/// `goal_items.issue_number`, where the views read them.
public struct GoalMirrorState: Hashable, Sendable, Codable {
    /// Mirroring is on: heed writes to the tracker on its own.
    public var on: Bool
    /// The tracker repo the issues below are in; a change of tracker starts over there.
    public var repo: String?
    public var meta: MirroredIssue?
    /// Each item's sub-issue, by item id.
    public var items: [String: MirroredIssue]
    /// The last sync that wrote everything there was to write, or found nothing to.
    public var syncedAt: Date?
    /// What went wrong in the last sync, in words; nil after one that went through.
    public var error: String?
    /// Writes the last sync left for the next (the batch was full).
    public var pending: Int
    /// The newest `updated_at` read back from the tracker: the next poll asks for what changed since.
    public var seen: Date?
    /// The newest comment on the meta issue that was read (its id); nil: none yet, the first poll starts from now.
    public var lastComment: Int64?
    /// Colleague changes to sub-issues waiting for you (closed while heed has the item open, and the other way).
    public var asks: [MirrorAsk]

    public init(
        on: Bool = false, repo: String? = nil, meta: MirroredIssue? = nil, items: [String: MirroredIssue] = [:],
        syncedAt: Date? = nil, error: String? = nil, pending: Int = 0, seen: Date? = nil, lastComment: Int64? = nil,
        asks: [MirrorAsk] = []
    ) {
        self.on = on
        self.repo = repo
        self.meta = meta
        self.items = items
        self.syncedAt = syncedAt
        self.error = error
        self.pending = pending
        self.seen = seen
        self.lastComment = lastComment
        self.asks = asks
    }

    public static let off = GoalMirrorState()

    public func issue(_ key: MirrorKey) -> MirroredIssue? {
        switch key {
        case .meta: meta
        case let .item(id): items[id]
        }
    }

    public mutating func set(_ key: MirrorKey, _ issue: MirroredIssue?) {
        switch key {
        case .meta: meta = issue
        case let .item(id): items[id] = issue
        }
    }

    /// The ask about an item, if one waits.
    public func ask(for item: String) -> MirrorAsk? { asks.first { $0.item == item } }
}

/// An issue heed made (or found by its marker), as heed last wrote it.
public struct MirroredIssue: Hashable, Sendable, Codable {
    public var number: Int
    /// The REST id (`id`, GraphQL `databaseId`): what adding a sub-issue takes.
    public var id: Int64
    public var title: String
    /// `MirrorDigest` of the body heed last wrote; empty for an issue found by its marker (written over once).
    public var body: String
    public var open: Bool
    /// Attached to the meta issue as a sub-issue (items only).
    public var attached: Bool

    public init(number: Int, id: Int64, title: String, body: String, open: Bool = true, attached: Bool = false) {
        self.number = number
        self.id = id
        self.title = title
        self.body = body
        self.open = open
        self.attached = attached
    }
}

/// A colleague changed a sub-issue's state on GitHub: heed asks whether the item follows.
public struct MirrorAsk: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Closed on GitHub while heed has the item open: is it done?
        case done
        /// Reopened on GitHub while heed has it done: is it not?
        case reopen
    }

    public var item: String
    public var issue: Int
    public var kind: Kind
    public var at: Date

    public init(item: String, issue: Int, kind: Kind, at: Date) {
        self.item = item
        self.issue = issue
        self.kind = kind
        self.at = at
    }

    public var id: String { "\(item):\(kind.rawValue)" }
}

/// Which issue: the goal's meta issue, or an item's sub-issue.
public enum MirrorKey: Hashable, Sendable, Codable, Comparable {
    case meta
    case item(String)

    public static func < (lhs: MirrorKey, rhs: MirrorKey) -> Bool {
        switch (lhs, rhs) {
        case (.meta, .item): true
        case let (.item(a), .item(b)): a < b
        default: false
        }
    }
}

/// What an issue should say: its title, its body and whether it is open; the comment heed leaves when it closes or
/// reopens it.
public struct MirrorSpec: Hashable, Sendable {
    public var key: MirrorKey
    public var title: String
    public var body: String
    public var open: Bool
    public var closing: String
    public var reopening: String

    public init(key: MirrorKey, title: String, body: String, open: Bool, closing: String = "", reopening: String = "") {
        self.key = key
        self.title = title
        self.body = body
        self.open = open
        self.closing = closing
        self.reopening = reopening
    }
}

/// One write to GitHub. The sync makes them one at a time, in the order `GoalMirrorPlan.writes` gives.
public enum MirrorWrite: Hashable, Sendable {
    case create(MirrorKey, title: String, body: String)
    case edit(MirrorKey, number: Int, title: String?, body: String?)
    case close(MirrorKey, number: Int, comment: String)
    case reopen(MirrorKey, number: Int, comment: String)
    /// The item's issue under the meta issue.
    case attach(item: String, parent: Int, child: Int64)

    public var key: MirrorKey {
        switch self {
        case let .create(key, _, _), let .edit(key, _, _, _), let .close(key, _, _), let .reopen(key, _, _): key
        case let .attach(item, _, _): .item(item)
        }
    }

    /// For the log and the tests: `create meta`, `close item a/b #12`.
    public var line: String {
        func name(_ key: MirrorKey) -> String {
            switch key {
            case .meta: "meta"
            case let .item(id): "item \(id)"
            }
        }
        return switch self {
        case let .create(key, _, _): "create \(name(key))"
        case let .edit(key, number, title, body):
            "edit \(name(key)) #\(number)" + (title != nil ? " title" : "") + (body != nil ? " body" : "")
        case let .close(key, number, _): "close \(name(key)) #\(number)"
        case let .reopen(key, number, _): "reopen \(name(key)) #\(number)"
        case let .attach(item, parent, _): "attach item \(item) to #\(parent)"
        }
    }
}

/// The markers that make heed's issues findable again: in the body, invisible on GitHub, searchable.
public enum MirrorMarker {
    public static func goal(_ id: String) -> String { "<!-- heed:goal \(id) -->" }
    public static func item(_ id: String) -> String { "<!-- heed:item \(id) -->" }
    /// On every comment heed writes, so reading comments back skips heed's own.
    public static let comment = "<!-- heed -->"

    /// The issue a body is, by its marker: the meta issue of `goal`, or one of its items' sub-issues. A marker for
    /// another goal (or none) is nil.
    public static func key(in body: String, goal: String) -> MirrorKey? {
        if body.contains(Self.goal(goal)) { return .meta }
        let prefix = "<!-- heed:item \(goal)/"
        guard let start = body.range(of: prefix) else { return nil }
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: " -->") else { return nil }
        let slug = rest[..<end.lowerBound]
        guard !slug.isEmpty, !slug.contains(where: \.isWhitespace) else { return nil }
        return .item("\(goal)/\(slug)")
    }
}

/// A short stable digest of a body: what the state keeps, to tell whether a body changed without keeping it.
public enum MirrorDigest {
    /// FNV-1a, 64 bits, in hex: the same text gives the same digest in every run (`Hasher` does not).
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// What the issues say, from the goal: pure, so the same goal always renders the same text and a sync with nothing
/// new writes nothing.
public enum GoalMirrorRender {
    public static let footer = "Maintained by heed: this follows the goal and is written over. Comment instead, and "
        + "heed proposes what you say for the goal."

    /// The meta issue: the goal, what it is not, when it is done (with the evidence for each criterion met), the
    /// decisions and open questions, the quality bars with today's scores, and the PRs in any repo.
    public static func meta(
        goal: HeedGoal, doc: GoalDoc, lenses: [GoalScore.Lens], pulls: [String]
    ) -> MirrorSpec {
        var out: [String] = []
        out += ["## Goal", "", doc.goal.isEmpty ? "_Not written yet._" : doc.goal, ""]
        if !doc.notTheGoal.isEmpty {
            out += ["## Not the goal", ""] + doc.notTheGoal.map { "- \($0)" } + [""]
        }
        out += ["## Done when", ""]
        if doc.doneWhen.isEmpty { out.append("_No criteria yet._") }
        out += doc.doneWhen.map { criterion in
            "- [\(criterion.met ? "x" : " ")] \(criterion.text)"
                + (criterion.evidence.map { " (evidence: \($0))" } ?? "")
        }
        out.append("")
        if !doc.decisions.isEmpty {
            out += ["## Decisions", ""] + doc.decisions.map { decision in
                "- \(decision.text)" + (decision.source.map { " (source: \($0))" } ?? "")
            } + [""]
        }
        if !doc.openQuestions.isEmpty {
            out += ["## Open questions", ""] + doc.openQuestions.map { "- \($0)" } + [""]
        }
        if !lenses.isEmpty {
            out += ["## Quality", "", "| Lens | Bar | Score |", "| --- | --- | --- |"]
            out += lenses.map { lens in
                let score = lens.score.map(GoalBarTable.number) ?? "–"
                return "| \(lens.lens.title) | \(GoalBarTable.number(lens.bar)) | \(score)\(lens.met ? " ✓" : "") |"
            }
            out.append("")
        }
        if !pulls.isEmpty {
            out += ["## Pull requests", ""] + pulls.map { "- \($0)" } + [""]
        }
        out += ["---", "", "_\(footer)_", "", MirrorMarker.goal(goal.id)]
        let done = goal.status != .active
        return MirrorSpec(
            key: .meta, title: goal.title, body: out.joined(separator: "\n"), open: !done,
            closing: goal.status == .done ? "Done: every criterion has evidence and every lens is at its bar."
                : "Archived in heed.",
            reopening: "Back on in heed."
        )
    }

    /// An item's sub-issue: what it is, where it stands, its PRs. Open until the item is Done.
    public static func item(
        _ item: GoalItem, goal: HeedGoal, column: Board.Column, marks: [Stage: StageMark], evidence: [GoalEvidence]
    ) -> MirrorSpec {
        var out: [String] = []
        out.append(item.kind == .question ? "A question on the goal **\(goal.title)**." :
            "Part of the goal **\(goal.title)**.")
        out.append("")
        let stages = Stage.allCases.compactMap { stage -> String? in
            guard let mark = marks[stage], mark != .notApplicable else { return nil }
            return "\(stage.title) \(mark.glyph)"
        }
        out.append("Stage: **\(column.title)** · " + stages.joined(separator: " · "))
        let pulls = item.linked(.pr)
        if !pulls.isEmpty {
            out += ["", "Pull requests:"] + pulls.map { "- \($0)" }
        }
        out += ["", "---", "", "_\(footer)_", "", MirrorMarker.item(item.id)]
        return MirrorSpec(
            key: .item(item.id), title: item.title, body: out.joined(separator: "\n"), open: column != .done,
            closing: "Done in heed: \(doneEvidence(item, evidence: evidence)).",
            reopening: "Reopened: heed has it in \(column.title) again."
        )
    }

    /// What showed the item done, for the closing comment: its merge, else the newest done evidence, else your move.
    static func doneEvidence(_ item: GoalItem, evidence: [GoalEvidence]) -> String {
        let mine = evidence.filter { $0.item == item.id && $0.state == .done }.sorted { Stages.newer($1, than: $0) }
        if let merged = mine.last(where: { $0.kind == .merged }) {
            return "merged \(merged.ref ?? merged.text)"
        }
        if let item = item.placement, item.column == .done {
            return "moved to Done by hand"
        }
        if let last = mine.last {
            let what = last.ref ?? last.text
            return what.isEmpty ? last.kind.rawValue : what
        }
        return "moved to Done"
    }

    /// Every spec for a goal: its meta issue and one per item, oldest item first.
    public static func specs(
        goal: HeedGoal, doc: GoalDoc, snapshot: GoalSnapshot, lenses: [GoalScore.Lens], requiredLenses: Set<Stage>
    ) -> [MirrorSpec] {
        let items = snapshot.items(of: goal.id).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let evidence = snapshot.evidence(of: goal.id)
        var pulls: [String] = []
        for ref in snapshot.links(of: goal.id).filter({ $0.kind == .pr }).map(\.target)
            + items.flatMap({ $0.linked(.pr) }) where !pulls.contains(ref)
        {
            pulls.append(ref)
        }
        return [meta(goal: goal, doc: doc, lenses: lenses, pulls: pulls)] + items.map { item in
            self.item(
                item, goal: goal, column: Board.column(item, evidence: evidence),
                marks: Stages.of(item, evidence: evidence, requiredLenses: requiredLenses), evidence: evidence
            )
        }
    }
}

/// The writes that bring GitHub to what heed says: a pure diff of the specs against the state heed last wrote. Nothing
/// new gives no writes; a write made gives a state the next diff does not repeat it from (`GoalMirrorState.applied`).
public enum GoalMirrorPlan {
    /// In order: the meta issue first (its number is what items attach to), then new items' issues, attaching them,
    /// edits, and opening or closing. An item whose state a colleague changed waits for your answer: its state is
    /// left alone until then.
    public static func writes(_ specs: [MirrorSpec], state: GoalMirrorState) -> [MirrorWrite] {
        var creates: [MirrorWrite] = []
        var attaches: [MirrorWrite] = []
        var edits: [MirrorWrite] = []
        var states: [MirrorWrite] = []
        let asked = Set(state.asks.map(\.item))
        for spec in specs {
            guard let issue = state.issue(spec.key) else {
                creates.append(.create(spec.key, title: spec.title, body: spec.body))
                continue
            }
            if case let .item(id) = spec.key, !issue.attached, let meta = state.meta {
                attaches.append(.attach(item: id, parent: meta.number, child: issue.id))
            }
            let title = issue.title == spec.title ? nil : spec.title
            let body = issue.body == MirrorDigest.of(spec.body) ? nil : spec.body
            if title != nil || body != nil {
                edits.append(.edit(spec.key, number: issue.number, title: title, body: body))
            }
            if case let .item(id) = spec.key, asked.contains(id) { continue }
            if issue.open, !spec.open {
                states.append(.close(spec.key, number: issue.number, comment: spec.closing))
            } else if !issue.open, spec.open {
                states.append(.reopen(spec.key, number: issue.number, comment: spec.reopening))
            }
        }
        // Items wait for the meta issue: created before it, they would have nothing to attach to yet.
        let metaFirst = creates.filter { $0.key == .meta }
        return metaFirst + (state.meta == nil && !metaFirst.isEmpty ? [] : creates.filter { $0.key != .meta })
            + attaches + edits + states
    }
}

public extension GoalMirrorState {
    /// The state after `write` went through; `made` is the issue a create made.
    func applied(_ write: MirrorWrite, made: RemoteIssue? = nil) -> GoalMirrorState {
        var next = self
        switch write {
        case let .create(key, title, body):
            guard let made else { return self }
            next.set(key, MirroredIssue(
                number: made.number, id: made.id, title: title, body: MirrorDigest.of(body), open: true
            ))
        case let .edit(key, _, title, body):
            guard var issue = issue(key) else { return self }
            if let title { issue.title = title }
            if let body { issue.body = MirrorDigest.of(body) }
            next.set(key, issue)
        case let .close(key, _, _), let .reopen(key, _, _):
            guard var issue = issue(key) else { return self }
            issue.open = if case .reopen = write { true } else { false }
            next.set(key, issue)
        case let .attach(item, _, _):
            next.items[item]?.attached = true
        }
        return next
    }

    /// The state with issues found by their markers taken in: heed never makes a second issue for what it made once.
    /// A found issue's body is written over once (heed does not know what it said).
    func adopting(_ found: [RemoteIssue], goal: String, meta: Int? = nil) -> GoalMirrorState {
        var next = self
        for remote in found.sorted(by: { $0.number < $1.number }) {
            guard let key = MirrorMarker.key(in: remote.body ?? "", goal: goal),
                  next.issue(key) == nil else { continue }
            let parent = meta ?? next.meta?.number
            next.set(key, MirroredIssue(
                number: remote.number, id: remote.id, title: remote.title, body: "", open: remote.open,
                attached: key != .meta && parent != nil && remote.parent == parent
            ))
        }
        return next
    }
}

/// An issue as GitHub tells it.
public struct RemoteIssue: Hashable, Sendable {
    public var number: Int
    public var id: Int64
    public var title: String
    public var body: String?
    public var open: Bool
    public var updatedAt: Date
    /// The number of the issue it is a sub-issue of, when GitHub says.
    public var parent: Int?

    public init(
        number: Int, id: Int64, title: String = "", body: String? = nil, open: Bool = true,
        updatedAt: Date = .distantPast, parent: Int? = nil
    ) {
        self.number = number
        self.id = id
        self.title = title
        self.body = body
        self.open = open
        self.updatedAt = updatedAt
        self.parent = parent
    }
}

/// A comment on the meta issue.
public struct RemoteComment: Hashable, Sendable {
    public var id: Int64
    public var author: String
    public var body: String
    public var at: Date

    public init(id: Int64, author: String, body: String, at: Date) {
        self.id = id
        self.author = author
        self.body = body
        self.at = at
    }
}

/// Reading GitHub back: colleagues' changes become asks and proposals, never changes to the goal.
public enum GoalMirrorBack {
    /// What changed on the tracker since the last poll: a sub-issue a colleague closed while heed has its item open
    /// becomes a "done?" ask, one reopened while heed has it done a "not done?" ask. An ask is not asked twice, and
    /// one whose question went away (heed caught up, or GitHub went back) is dropped. `done`: the items heed has in
    /// Done.
    public static func read(
        _ state: GoalMirrorState, updated: [RemoteIssue], done: Set<String>, now: Date
    ) -> GoalMirrorState {
        var next = state
        let byNumber = Dictionary(state.items.map { ($0.value.number, $0.key) }) { first, _ in first }
        for remote in updated {
            next.seen = max(next.seen ?? .distantPast, remote.updatedAt)
            guard let item = byNumber[remote.number], var issue = next.items[item], issue.open != remote.open else {
                continue
            }
            issue.open = remote.open
            next.items[item] = issue
            let kind: MirrorAsk.Kind? = !remote.open && !done.contains(item) ? .done
                : remote.open && done.contains(item) ? .reopen : nil
            next.asks.removeAll { $0.item == item }
            if let kind { next.asks.append(MirrorAsk(item: item, issue: remote.number, kind: kind, at: now)) }
        }
        // An ask whose question went away: heed moved the item where GitHub has it.
        next.asks.removeAll { ask in
            switch ask.kind {
            case .done: done.contains(ask.item)
            case .reopen: !done.contains(ask.item)
            }
        }
        return next
    }

    /// The comments on the meta issue a person wrote since the last read, oldest first (heed's own are skipped).
    public static func fresh(_ comments: [RemoteComment], after last: Int64?) -> [RemoteComment] {
        comments.filter { ($0.id > (last ?? .min)) && !$0.body.contains(MirrorMarker.comment) }
            .sorted { $0.id < $1.id }
    }

    /// What the proposer reads: the goal's GOAL.md and the comments, each with who wrote it.
    public static func inputs(goal title: String, doc text: String, comments: [RemoteComment], issue: String)
        -> SummaryInputs
    {
        SummaryInputs(
            title: "Comments on \(issue), the GitHub issue that mirrors the goal \(title)",
            timeline: comments.map { "@\($0.author): \(GoalDoc.oneLine($0.body))" }, goal: text
        )
    }

    /// The proposer's edits a comment may suggest: an open question or a decision, added; each waits for you.
    public static func proposals(_ edits: [GoalEdit]) -> [GoalEdit] {
        edits.filter { ($0.section == .openQuestions || $0.section == .decisions) && $0.op == .add }.map { edit in
            var edit = edit
            edit.kind = .scope
            return edit
        }
    }
}

/// `[goals]` mirror keys, with their per-org and per-repo defaults: where a new goal mirrors to, and whether it does
/// from the start. A goal keeps its own tracker and its own on or off once made; these only fill in a new one.
public struct GoalMirrorSettings: Equatable, Sendable {
    /// `[goals] tracker`: the tracker repo when no org or repo names one; empty: none.
    public var tracker = ""
    /// `[goals] mirror`: new goals mirror from the start (off by default: mirroring publishes).
    public var on = false
    /// `[goals] mirror_label`: a label put on the issues heed makes; empty: none.
    public var label = ""
    /// `[orgs.<name>] goals_tracker` and `[repos."org/name"] goals_tracker`, by org or `org/name`.
    public var trackers: [String: String] = [:]
    /// `[orgs.<name>] goals_mirror` and `[repos."org/name"] goals_mirror`.
    public var mirrors: [String: Bool] = [:]

    public init() {}

    /// The tracker a new goal from work in `repo` (`org/name`, or nil) gets: the repo's, its org's, else the default.
    public func tracker(for repo: String?) -> String? {
        let found = repo.flatMap { trackers[$0] } ?? repo.flatMap { org($0) }.flatMap { trackers[$0] } ?? tracker
        return TrackerCheck.slug(found)
    }

    /// Whether a new goal from work in `repo` mirrors from the start.
    public func mirrors(for repo: String?) -> Bool {
        repo.flatMap { mirrors[$0] } ?? repo.flatMap { org($0) }.flatMap { mirrors[$0] } ?? on
    }

    private func org(_ repo: String) -> String? {
        repo.split(separator: "/").first.map(String.init)
    }

    /// The labels to put on what heed makes.
    public var labels: [String] { label.isEmpty ? [] : [label] }
}
