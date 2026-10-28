import Foundation

/// Who runs a `heed goal` command: the session whose pane it was typed in (`HEED_SESSION_ID`), as the app knows it.
/// Nil fields when it runs outside a Heed pane.
public struct GoalCaller: Codable, Equatable, Sendable {
    public var session: String
    public var title: String
    public var isChat: Bool
    /// `org/name` of its first repo, for `link pr #n`.
    public var repo: String?
    /// A swarm worker's task (its item id), when the command came from a worker's tab: the session is then the one
    /// hosting the tab (the lead's), and the caller is the worker, not the lead.
    public var worker: String?

    public init(session: String, title: String, isChat: Bool = false, repo: String? = nil, worker: String? = nil) {
        self.session = session
        self.title = title
        self.isChat = isChat
        self.repo = repo
        self.worker = worker
    }

    public init(_ session: Session) {
        self.init(session: session.id, title: session.title, isChat: session.isChat, repo: session.repos.first?.slug)
    }

    /// The link that puts it on a goal.
    var linkKind: GoalLink.Kind { isChat ? .chat : .session }
    var itemLinkKind: GoalItem.Link.Kind { isChat ? .chat : .session }
}

/// What `heed goal` gets back: the exit code, a line for people, and what changed, for `--json`.
public struct GoalReply: Codable, Equatable, Sendable {
    /// `applied` (a record edit, now in GOAL.md), `proposed` (a scope edit, waiting for you), `moot` (nothing to
    /// change), `added`, `moved`, `attached`, `linked`, `started`, `asked`, `held`, or `read`.
    public var outcome: String
    public var exit: GoalExit
    public var message: String
    public var goal: String?
    public var item: String?
    /// The GOAL.md edit's id, for undo in Heed.
    public var edit: Int64?
    /// The GOAL.md version an applied edit made.
    public var version: Int?
    /// A session it started.
    public var session: String?
    /// `list`.
    public var goals: [GoalRow]?
    /// `show`.
    public var view: GoalView?
    /// `plan show`, and what `plan propose` and `ask` leave the plan as.
    public var plan: SwarmPlanView?

    public init(
        _ outcome: String, exit: GoalExit = .ok, message: String, goal: String? = nil, item: String? = nil,
        edit: Int64? = nil, version: Int? = nil, session: String? = nil, goals: [GoalRow]? = nil,
        view: GoalView? = nil, plan: SwarmPlanView? = nil
    ) {
        self.outcome = outcome
        self.exit = exit
        self.message = message
        self.goal = goal
        self.item = item
        self.edit = edit
        self.version = version
        self.session = session
        self.goals = goals
        self.view = view
        self.plan = plan
    }

    public static func refused(_ message: String, goal: String? = nil) -> GoalReply {
        GoalReply("refused", exit: .refused, message: message, goal: goal)
    }

    /// What the CLI prints: JSON (sorted keys, one object) or the text for people.
    public func rendered(json: Bool) -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        if let goals { return GoalRow.table(goals) }
        if let view { return view.text }
        if let plan, outcome == "read" { return plan.text }
        return message
    }
}

/// A goal in `heed goal list`.
public struct GoalRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var criteriaMet: Int
    public var criteriaTotal: Int
    public var items: Int
    public var score: Double?
    /// The calling session is on it.
    public var current: Bool

    public static func table(_ rows: [GoalRow]) -> String {
        guard !rows.isEmpty else { return "no goals yet: make one in Heed (gG, then n)" }
        return rows.map { row in
            [
                (row.current ? "* " : "  ") + row.id, row.status, "\(row.criteriaMet)/\(row.criteriaTotal) done when",
                "\(row.items) items", row.score.map { String(format: "%.1f", $0) } ?? "–", row.title,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

/// A goal in `heed goal show`: its GOAL.md, its items with their stages, its quality bars and scores.
public struct GoalView: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: String
        public var column: String
        public var source: String
        public var parent: String?
        /// Stage → `done`, `inProgress`, `issue`, `notYet`, `notApplicable`.
        public var stages: [String: String]
    }

    public struct Bar: Codable, Equatable, Sendable {
        public var lens: String
        public var bar: Double
        public var score: Double?
        public var met: Bool
    }

    public var id: String
    public var title: String
    public var status: String
    public var version: Int
    public var path: String
    public var doc: String
    public var criteriaMet: Int
    public var criteriaTotal: Int
    public var items: [Item]
    public var bars: [Bar]
    public var score: Double?
    public var proposals: [String]

    public var text: String {
        var lines = ["\(title) (\(id), \(status), GOAL.md v\(version): \(path))", "", doc.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), ""]
        let order = Stage.allCases
        lines.append("Items (" + order.map(\.title).joined(separator: " ") + ")")
        if items.isEmpty { lines.append("  none yet: heed goal item add <title>") }
        for item in items {
            let marks = order.map { StageMark(rawValue: item.stages[$0.rawValue] ?? "")?.glyph ?? "?" }
            lines
                .append(
                    "  \(marks.joined(separator: " "))  \(item.column.padding(toLength: 8, withPad: " ", startingAt: 0)) \(item.id)  \(item.title)"
                )
        }
        if !bars.isEmpty {
            lines.append("")
            lines.append("Quality" + (score.map { String(format: " (goal %.1f)", $0) } ?? ""))
            for bar in bars {
                let score = bar.score.map { String(format: "%.1f", $0) } ?? "–"
                lines.append("  \(bar.met ? "✓" : "○") \(bar.lens): \(score) of bar \(String(format: "%g", bar.bar))")
            }
        }
        if !proposals.isEmpty {
            lines.append("")
            lines.append("Waiting for you")
            lines += proposals.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// What the app does for a command `GoalControl` cannot finish by itself.
public enum GoalAppAction: Equatable, Sendable {
    /// Start a session (or a background run) on an item.
    case spawn(GoalSpawn)
    /// Ask the goal's reviewer of `kind` for a re-check.
    case review(goal: String, kind: String)
}

/// `item spawn`: what to start, for whom.
public struct GoalSpawn: Codable, Equatable, Sendable {
    public var goal: String
    public var item: String
    public var agent: String?
    public var background: Bool
    /// Who asked: the calling session's title, or `heed goal`.
    public var from: String
    public var caller: String?

    public init(goal: String, item: String, agent: String?, background: Bool, from: String, caller: String?) {
        self.goal = goal
        self.item = item
        self.agent = agent
        self.background = background
        self.from = from
        self.caller = caller
    }
}

/// Runs `heed goal` commands against `GoalOps`, with the rules the Goals view has: items, moves, links and record
/// edits apply at once; scope edits become proposals (`GoalOps.propose` decides which is which, not the command).
/// What needs the app (starting a session, a reviewer) comes back as a `GoalAppAction`.
public enum GoalControl {
    public enum Outcome: Equatable, Sendable {
        case reply(GoalReply)
        case app(GoalAppAction, goal: HeedGoal)
    }

    public static func run(
        _ command: GoalCommand, caller: GoalCaller?, ops: GoalOps, files: GoalFiles, table: GoalBarTable = .defaults,
        now: Date
    ) async -> Outcome {
        do {
            return try await route(command, caller: caller, ops: ops, files: files, table: table, now: now)
        } catch let error as GoalOpError {
            return .reply(.refused(error.description))
        } catch let reply as GoalReplyError {
            return .reply(reply.reply)
        } catch {
            return .reply(.refused("\(error)"))
        }
    }

    struct GoalReplyError: Error {
        var reply: GoalReply
    }

    /// The goal a command works on: `--goal` (its id, or its title), else the caller's.
    static func goal(
        for command: GoalCommand, caller: GoalCaller?, snapshot: GoalSnapshot
    ) throws -> HeedGoal {
        if let named = command.goal {
            let key = named.lowercased()
            if let goal = snapshot.goal(named) ?? snapshot.goals.first(where: { $0.title.lowercased() == key }) {
                return goal
            }
            throw GoalReplyError(reply: .refused("no goal \(named) (heed goal list shows them)"))
        }
        guard let caller else {
            throw GoalReplyError(reply: GoalReply(
                "no goal", exit: .noGoal,
                message: "not in a Heed pane: pass --goal <id> (heed goal list shows them)"
            ))
        }
        guard let link = snapshot.links.first(where: {
            $0.target == caller.session && ($0.kind == .session || $0.kind == .chat)
        }), let goal = snapshot.goal(link.goal) else {
            throw GoalReplyError(reply: GoalReply(
                "no goal", exit: .noGoal,
                message: "\(caller.title) is on no goal: heed goal attach <goal>, or pass --goal <id> "
                    + "(heed goal list shows them)"
            ))
        }
        return goal
    }

    /// An item of `goal` by its id or its slug.
    static func item(_ word: String, goal: String, snapshot: GoalSnapshot) throws -> GoalItem {
        if let item = snapshot.item(word), item.goal == goal { return item }
        if let item = snapshot.item("\(goal)/\(word)") { return item }
        throw GoalReplyError(reply: .refused("no item \(word) on \(goal) (heed goal show lists them)", goal: goal))
    }

    /// Who an edit or item is from: the session or chat, or a subagent in it.
    public static func from(_ caller: GoalCaller?, subagent: String? = nil) -> String {
        let base = caller.map { ($0.isChat ? "chat · " : "") + $0.title } ?? "heed goal"
        return subagent.map { "subagent \($0) in \(base)" } ?? base
    }

    static func evidenceSource(_ caller: GoalCaller?) -> String {
        if let task = caller?.worker { return "swarm worker on \(SwarmPlan.short(task))" }
        return caller.map { "session \($0.session)" } ?? "heed goal"
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func route(
        _ command: GoalCommand, caller: GoalCaller?, ops: GoalOps, files: GoalFiles, table: GoalBarTable, now: Date
    ) async throws -> Outcome {
        let snapshot = try await ops.snapshot()
        if command.verb == .list {
            let current = caller.flatMap { caller in snapshot.links.first { $0.target == caller.session }?.goal }
            let rows = snapshot.goals.filter { $0.status != .archived || command.goal != nil }.map { goal in
                let met = snapshot.docs[goal.id]?.criteriaMet ?? (met: 0, total: 0)
                return GoalRow(
                    id: goal.id, title: goal.title, status: goal.status.rawValue, criteriaMet: met.met,
                    criteriaTotal: met.total, items: snapshot.items(of: goal.id).count,
                    score: goal.score, current: goal.id == current
                )
            }
            return .reply(GoalReply("read", message: GoalRow.table(rows), goals: rows))
        }
        if command.verb == .attach {
            guard let caller else {
                return .reply(GoalReply(
                    "no goal",
                    exit: .noGoal,
                    message: "attach puts this session on a goal: run "
                        + "it in a Heed pane"
                ))
            }
            guard let named = command.subject else {
                let goal = try goal(for: command, caller: caller, snapshot: snapshot)
                return .reply(GoalReply(
                    "read",
                    message: "\(caller.title) is on \(goal.id): \(goal.title)",
                    goal: goal.id
                ))
            }
            var lookup = command
            lookup.goal = named
            let goal = try goal(for: lookup, caller: caller, snapshot: snapshot)
            let previous = try await ops.attach(GoalLink(
                goal: goal.id, kind: caller.linkKind, target: caller.session, origin: .manual,
                reason: "attached with heed goal attach", at: now
            ))
            return .reply(GoalReply(
                "attached", message: "\(caller.title) is on \(goal.id) now" + (previous.map { " (was \($0))" } ?? "")
                    + ": read \(files.doc(goal.id).path)", goal: goal.id
            ))
        }
        let goal = try goal(for: command, caller: caller, snapshot: snapshot)
        let from = from(caller, subagent: command.bySubagent)
        switch command.verb {
        case .list, .attach:
            preconditionFailure("handled above")
        case .show:
            return try await .reply(show(goal, snapshot: snapshot, ops: ops, files: files, table: table))
        case .itemAdd:
            let parent = try command.parent.map { try item($0, goal: goal.id, snapshot: snapshot).id }
            let source: GoalItem.Source = command.bySubagent != nil ? .subagent
                : caller.map { $0.isChat ? .chat : .session } ?? .you
            let added = try await ops.addItem(
                goal: goal.id, title: command.text ?? "", source: source, parent: parent,
                links: caller.map { [GoalItem.Link($0.itemLinkKind, $0.session)] } ?? [],
                reason: "added by \(from)", now: now
            )
            return .reply(GoalReply(
                "added", message: "added \(added.id)" + (parent.map { " under \($0)" } ?? ""), goal: goal.id,
                item: added.id
            ))
        case .itemDone:
            let item = try item(command.subject ?? "", goal: goal.id, snapshot: snapshot)
            if let evidence = command.evidence {
                try await ops.addEvidence(GoalEvidence(
                    goal: goal.id, item: item.id, kind: .built, state: .done, at: now,
                    source: evidenceSource(caller), text: GoalDoc.oneLine(evidence), ref: caller?.session
                ))
            }
            try await ops.done(item: item.id, now: now)
            return .reply(GoalReply("moved", message: "\(item.id) is in Done", goal: goal.id, item: item.id))
        case .itemMove:
            let item = try item(command.subject ?? "", goal: goal.id, snapshot: snapshot)
            guard let column = Board.Column(word: command.text ?? "") else {
                return .reply(.refused("no column \(command.text ?? "")", goal: goal.id))
            }
            try await ops.move(item: item.id, to: column, now: now)
            return .reply(GoalReply(
                "moved", message: "\(item.id) is in \(column.title)", goal: goal.id, item: item.id
            ))
        case .itemSpawn:
            let item = try item(command.subject ?? "", goal: goal.id, snapshot: snapshot)
            return .app(.spawn(GoalSpawn(
                goal: goal.id, item: item.id, agent: command.agent, background: command.background, from: from,
                caller: caller?.session
            )), goal: goal)
        case .decisionAdd:
            return try await .reply(edit(GoalEdit(
                goal: goal.id, section: .decisions, op: .add, text: command.text ?? "",
                evidence: command.evidence ?? from, from: from, at: now
            ), ops: ops, now: now))
        case .questionAdd:
            let added = try await ops.addItem(
                goal: goal.id, title: command.text ?? "", kind: .question,
                source: caller.map { $0.isChat ? .chat : .session } ?? .you,
                links: caller.map { [GoalItem.Link($0.itemLinkKind, $0.session)] } ?? [],
                reason: "asked in \(from)", now: now
            )
            return .reply(GoalReply(
                "added", message: "asked \(added.id): a card in To explore", goal: goal.id, item: added.id
            ))
        case .questionAnswer:
            return try await .reply(answer(
                command,
                goal: goal,
                from: from,
                caller: caller,
                snapshot: snapshot,
                ops: ops,
                now: now
            ))
        case .criterionCheck where command.item != nil:
            return try await .reply(checkTask(
                command,
                goal: goal,
                caller: caller,
                snapshot: snapshot,
                ops: ops,
                now: now
            ))
        case .criterionCheck:
            let doc = try await GoalDoc.parse(ops.text(of: goal.id))
            let subject = command.subject ?? ""
            let criterion: GoalDoc.Criterion? = if let number = Int(subject),
                                                   doc.doneWhen.indices.contains(number - 1)
            {
                doc.doneWhen[number - 1]
            } else {
                doc.doneWhen.first { GoalEdits.same($0.text, subject) }
            }
            guard let criterion else {
                let list = doc.doneWhen.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
                return .reply(.refused(
                    "no criterion \(subject) in Done when" + (list.isEmpty ? "" : ":\n" + list.joined(separator: "\n")),
                    goal: goal.id
                ))
            }
            return try await .reply(edit(GoalEdit(
                goal: goal.id, section: .doneWhen, op: .check, text: criterion.text, target: criterion.text,
                evidence: command.evidence, from: from, at: now
            ), ops: ops, now: now))
        case .propose:
            guard let section = GoalCommandLine.section(command.subject ?? "") else {
                return .reply(.refused("no section \(command.subject ?? "")", goal: goal.id))
            }
            return try await .reply(edit(GoalEdit(
                goal: goal.id, section: section, op: section == .goal ? .replace : .add, text: command.text ?? "",
                evidence: from, from: from, reason: "proposed with heed goal propose", at: now
            ), ops: ops, now: now))
        case .linkPR:
            guard let ref = pull(command.subject ?? "", repo: caller?.repo) else {
                return .reply(.refused(
                    "\(command.subject ?? "") names no PR here: give org/repo#n or its URL", goal: goal.id
                ))
            }
            let item = try command.item.map { try item($0, goal: goal.id, snapshot: snapshot) }
            try await ops.attach(GoalLink(
                goal: goal.id, kind: .pr, target: ref.description, origin: .manual, item: item?.id,
                reason: "linked by \(from)", at: now
            ))
            if let item { try await ops.link(item: item.id, GoalItem.Link(.pr, ref.description)) }
            return .reply(GoalReply(
                "linked", message: "\(ref) is on \(goal.id)" + (item.map { ", item \($0.id)" } ?? ""), goal: goal.id,
                item: item?.id
            ))
        case .reviewRequest:
            return .app(.review(goal: goal.id, kind: command.subject ?? ""), goal: goal)
        case .planShow, .planPropose, .planApprove, .ask:
            return try await .reply(SwarmControl.run(command, goal: goal, caller: caller, ops: ops, now: now))
        }
    }

    /// `org/repo#n`, a PR URL, or `#n` in the caller's repo.
    public static func pull(_ word: String, repo: String?) -> PullRef? {
        if let ref = PullRef(url: word) ?? PullRef(slug: word) { return ref }
        guard word.hasPrefix("#"), let number = Int(word.dropFirst()), let repo,
              let ref = PullRef(slug: "\(repo)#\(number)")
        else { return nil }
        return ref
    }

    /// A GOAL.md edit through `GoalOps.propose`: it applies when it records, waits when it changes scope.
    static func edit(_ edit: GoalEdit, ops: GoalOps, now: Date) async throws -> GoalReply {
        let done = try await ops.propose(edit, now: now)
        switch done.state {
        case .applied:
            return GoalReply(
                "applied", message: "applied: \(GoalEdits.note(done)) (GOAL.md v\(done.version ?? 0); undo in Heed)",
                goal: done.goal, edit: done.id, version: done.version
            )
        case .proposed:
            return GoalReply(
                "proposed", message: "proposed: \(done.line). It changes the goal's scope, so it waits for you in Heed",
                goal: done.goal, edit: done.id
            )
        default:
            return GoalReply(
                "moot", message: "nothing to change: GOAL.md already says so, or what it is about is not there",
                goal: done.goal, edit: done.id
            )
        }
    }

    /// The answer to a question card or a GOAL.md open question: a decision (recorded), and the question closed (the
    /// card to Done by its decision evidence; the open question out of GOAL.md, which also only records).
    static func answer(
        _ command: GoalCommand, goal: HeedGoal, from: String, caller: GoalCaller?, snapshot: GoalSnapshot,
        ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        let subject = command.subject ?? ""
        let answer = command.text ?? ""
        let card = (try? item(subject, goal: goal.id, snapshot: snapshot)).flatMap { $0.kind == .question ? $0 : nil }
        let doc = try await GoalDoc.parse(ops.text(of: goal.id))
        let open: String? = if let number = Int(subject), doc.openQuestions.indices.contains(number - 1) {
            doc.openQuestions[number - 1]
        } else {
            doc.openQuestions.first { GoalEdits.same($0, subject) } ?? card.flatMap { card in
                doc.openQuestions.first { GoalEdits.same($0, card.title) }
            }
        }
        guard card != nil || open != nil else {
            let questions = snapshot.items(of: goal.id).filter { $0.kind == .question }
                .map { "  \($0.id)  \($0.title)" }
                + doc.openQuestions.enumerated().map { "  \($0.offset + 1). \($0.element)" }
            return .refused(
                "no question \(subject) on \(goal.id)" +
                    (questions.isEmpty ? "" : ":\n" + questions.joined(separator: "\n")),
                goal: goal.id
            )
        }
        let question = card?.title ?? open ?? subject
        var reply = try await edit(GoalEdit(
            goal: goal.id, section: .decisions, op: .add, text: answer, evidence: "answers: \(question)", from: from,
            at: now
        ), ops: ops, now: now)
        if let card {
            try await ops.addEvidence(GoalEvidence(
                goal: goal.id, item: card.id, kind: .decision, state: .done, at: now, source: evidenceSource(caller),
                text: GoalDoc.oneLine(answer), ref: caller?.session
            ))
            reply.item = card.id
        }
        if let open {
            try await ops.propose(GoalEdit(
                goal: goal.id, section: .openQuestions, op: .remove, text: open, target: open, evidence: answer,
                from: from, at: now
            ), now: now)
        }
        reply.outcome = "applied"
        reply.message = "answered: \(question) → \(GoalDoc.oneLine(answer)) (a decision in GOAL.md; undo in Heed)"
        return reply
    }

    /// `criterion check <n|text> --item <id> --evidence <text>`: a line of a swarm task's done-when met, as evidence on
    /// its item. A task is done once every line has some.
    static func checkTask(
        _ command: GoalCommand, goal: HeedGoal, caller: GoalCaller?, snapshot: GoalSnapshot, ops: GoalOps, now: Date
    ) async throws -> GoalReply {
        let item = try item(command.item ?? "", goal: goal.id, snapshot: snapshot)
        let subject = command.subject ?? ""
        let line: String? = if let number = Int(subject), item.doneWhen.indices.contains(number - 1) {
            item.doneWhen[number - 1]
        } else {
            item.doneWhen.first { GoalEdits.same($0, subject) }
        }
        guard let line else {
            let list = item.doneWhen.enumerated().map { "\($0.offset + 1). \($0.element)" }
            return .refused(
                "no done-when \(subject) on \(item.id)" + (list.isEmpty ? ": it has none" : ":\n" + list
                    .joined(separator: "\n")),
                goal: goal.id
            )
        }
        try await ops.addEvidence(GoalEvidence(
            goal: goal.id, item: item.id, kind: .criterion, state: .done, at: now, source: evidenceSource(caller),
            text: line, ref: GoalDoc.oneLine(command.evidence ?? "")
        ))
        let met = try await ops.snapshot().evidence(of: goal.id).filter {
            $0.item == item.id && $0.kind == .criterion && $0.state == .done
        }
        let count = item.doneWhen.count { line in met.contains { GoalEdits.same($0.text, line) } }
        return GoalReply(
            "applied", message: "\(item.id): \(line) (\(count) of \(item.doneWhen.count) done-when met)", goal: goal.id,
            item: item.id
        )
    }

    static func show(
        _ goal: HeedGoal, snapshot: GoalSnapshot, ops: GoalOps, files: GoalFiles, table: GoalBarTable
    ) async throws -> GoalReply {
        let text = try await ops.text(of: goal.id)
        let quality = try await ops.quality(of: goal.id, table: table)
        let doc = GoalDoc.parse(text)
        let evidence = snapshot.evidence(of: goal.id)
        let lenses = ReviewEvidence.requiredStages(quality)
        let items = snapshot.items(of: goal.id).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.map { item in
            GoalView.Item(
                id: item.id, title: item.title, kind: item.kind.rawValue,
                column: Board.column(item, evidence: evidence).word, source: item.source.rawValue, parent: item.parent,
                stages: Dictionary(uniqueKeysWithValues: Stages.of(item, evidence: evidence, requiredLenses: lenses)
                    .map { ($0.key.rawValue, $0.value.rawValue) })
            )
        }
        let met = doc.criteriaMet
        let view = GoalView(
            id: goal.id, title: goal.title, status: goal.status.rawValue, version: goal.version,
            path: files.doc(goal.id).path, doc: text, criteriaMet: met.met, criteriaTotal: met.total, items: items,
            bars: quality.lenses.map { GoalView.Bar(lens: $0.lens.title, bar: $0.bar, score: $0.score, met: $0.met) },
            score: quality.confidence?.value ?? goal.score,
            proposals: snapshot.proposals(of: goal.id).map(\.line)
        )
        return GoalReply("read", message: view.text, goal: goal.id, view: view)
    }
}
