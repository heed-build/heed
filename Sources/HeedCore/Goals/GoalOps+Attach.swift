import Foundation

public extension GoalFiles {
    /// `goals/attach.rules`: the lines heed learnt from your corrections, and yours.
    var rules: URL { root.appendingPathComponent("attach.rules") }
}

/// Why an attachment operation did nothing.
public enum AttachOpError: Error, Equatable, CustomStringConvertible {
    case unknownDecision
    case nothingToUndo
    /// The thing is no longer where heed put it: you moved or took it off since.
    case movedSince(String)
    case notAProposal

    public var description: String {
        switch self {
        case .unknownDecision: "that decision is gone"
        case .nothingToUndo: "nothing heed attached is left to undo"
        case let .movedSince(title): "\(title) moved since: nothing to undo"
        case .notAProposal: "that one is not waiting for an answer"
        }
    }
}

/// Your answer to one of heed's asks.
public enum AttachAnswer: Hashable, Sendable {
    /// y: on the goal heed proposed.
    case yes
    /// n: not on that goal (it stays unassigned, and heed learns `never`).
    case no
    /// m: on this other goal instead (heed learns `never` for the one it proposed).
    case move(String)
    /// i: leave things like this alone (heed learns `ignore`).
    case ignore
}

/// Attachment through `GoalOps`, the one API: acting on decisions, undo, your answers, the rules file, and goals made
/// from suggestions. Every correction writes a rule line, with a comment saying why.
public extension GoalOps {
    // MARK: Rules

    /// `attach.rules` as it is (empty when there is none yet).
    func rulesText() throws -> String {
        guard files.writes else { return memoryRules }
        guard FileManager.default.fileExists(atPath: files.rules.path) else { return "" }
        return try String(contentsOf: files.rules, encoding: .utf8)
    }

    /// The rules, read; a file that cannot be read is no rules (and says so as a problem), never a stop.
    func rules() -> AttachRules {
        do {
            return try AttachRules(text: rulesText())
        } catch {
            return AttachRules(problems: [AttachRuleProblem(line: 0, message: "could not read the file: \(error)")])
        }
    }

    /// Replaces the rules (fixtures; you edit the file itself).
    func setRules(_ text: String) throws {
        guard files.writes else {
            memoryRules = text
            return
        }
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        try text.write(to: files.rules, atomically: true, encoding: .utf8)
    }

    /// Appends a learnt rule under a comment saying why; nothing when the same line is there already.
    @discardableResult
    internal func learn(_ rule: AttachRule, why: String, now: Date) throws -> Bool {
        var text = try rulesText()
        let line = rule.text
        if text.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == line
        }) { return false }
        if text.isEmpty {
            text = Self.rulesHeader
        } else if !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "# \(Self.day(now)): \(why)\n\(line)\n"
        try setRules(text)
        return true
    }

    static let rulesHeader = """
    # How heed puts sessions and chats on goals. heed adds a line when you correct it; edit or delete any line.
    # always|never|ignore field:glob … [-> goal]; fields: worktree, branch, repo, chat, session, title, prompt.

    """

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Decisions

    /// Decisions newest first.
    func decisions(since: Date? = nil, limit: Int = 500) throws -> [AttachDecision] {
        try store.decisions(since: since, limit: limit)
    }

    /// Whether a thing is on a goal, and the newest decision about it.
    func attachState(kind: GoalLink.Kind, target: String) throws -> (linked: Bool, latest: AttachDecision?) {
        let linked = try store.links().contains { $0.kind == kind && $0.target == target }
        return try (linked, store.latestDecision(kind: kind, target: target))
    }

    /// Acts on a decision heed made: attaches when it says so (origin `auto`, with its confidence and reason), then
    /// stores it. An earlier ask about the same thing still open is superseded.
    @discardableResult
    func act(
        _ subject: AttachSubject, trigger: AttachTrigger, outcome: GoalAttacher.Outcome, tokens: Int = 0, now: Date
    ) throws -> AttachDecision {
        if var previous = try store.latestDecision(kind: subject.kind, target: subject.id), previous.state == .open {
            previous.state = .superseded
            previous.resolvedAt = now
            try store.update(previous)
        }
        let verdict = outcome.verdict
        if verdict.action == .attach, let goal = verdict.goal {
            try attach(
                subject,
                to: goal,
                origin: .auto,
                confidence: verdict.confidence,
                reason: verdict.reason,
                now: now
            )
        }
        return try store.insert(AttachDecision(
            subject: subject, trigger: trigger, verdict: verdict, candidates: outcome.candidates, tokens: tokens,
            modelError: outcome.modelError, at: now
        ))
    }

    /// Undoes heed's attachment: `id`'s, or the newest heed made on its own that is still in place. The thing comes
    /// off the goal and heed learns `never` for things like it.
    @discardableResult
    func undo(_ id: Int64? = nil, now: Date) throws -> AttachDecision {
        var decision: AttachDecision
        if let id {
            guard let found = try store.decision(id) else { throw AttachOpError.unknownDecision }
            decision = found
        } else {
            let links = try store.links()
            guard let found = try store.decisions(limit: 200).first(where: { candidate in
                candidate.state == .settled && candidate.verdict.action == .attach && links.contains {
                    $0.kind == candidate.subject.kind && $0.target == candidate.subject.id
                        && $0.goal == candidate.goal && $0.origin == .auto
                }
            }) else { throw AttachOpError.nothingToUndo }
            decision = found
        }
        guard decision.verdict.action == .attach, decision.state == .settled, let goal = decision.goal else {
            throw AttachOpError.nothingToUndo
        }
        let link = try store.links().first { $0.kind == decision.subject.kind && $0.target == decision.subject.id }
        guard link?.goal == goal else { throw AttachOpError.movedSince(decision.subject.title) }
        try detach(kind: decision.subject.kind, target: decision.subject.id)
        try learn(
            AttachRules.never(decision.subject, goal: goal), why: "you undid \(decision.subject.title) on \(goal)",
            now: now
        )
        decision.state = .undone
        decision.goal = nil
        decision.resolvedAt = now
        try store.update(decision)
        return decision
    }

    /// Your answer to an ask, or a move of anything in the feed (`m`).
    @discardableResult
    func answer(_ id: Int64, _ answer: AttachAnswer, now: Date) throws -> AttachDecision {
        guard var decision = try store.decision(id) else { throw AttachOpError.unknownDecision }
        let subject = decision.subject
        let proposed = decision.verdict.goal
        switch answer {
        case .yes:
            guard decision.state == .open, let goal = proposed else { throw AttachOpError.notAProposal }
            try attach(
                subject, to: goal, origin: .asked, confidence: decision.verdict.confidence,
                reason: decision.verdict.reason, now: now
            )
            decision.state = .accepted
            decision.goal = goal
        case .no:
            guard decision.state == .open, let goal = proposed else { throw AttachOpError.notAProposal }
            try learn(
                AttachRules.never(subject, goal: goal),
                why: "you said no to \(subject.title) on \(goal)",
                now: now
            )
            decision.state = .declined
        case let .move(goal):
            try attach(subject, to: goal, origin: .manual, now: now)
            let wrong = decision.verdict.action == .ask || decision.verdict.action == .attach ? proposed : nil
            if let wrong, wrong != goal {
                try learn(
                    AttachRules.never(subject, goal: wrong), why: "you moved \(subject.title) to \(goal)", now: now
                )
            }
            decision.state = .moved
            decision.goal = goal
        case .ignore:
            if decision.verdict.action == .attach, decision.state == .settled, let goal = decision.goal,
               try store.links().contains(where: {
                   $0.kind == subject.kind && $0.target == subject.id && $0.goal == goal && $0.origin == .auto
               })
            {
                try detach(kind: subject.kind, target: subject.id)
            }
            try learn(AttachRules.ignore(subject), why: "you said to ignore things like \(subject.title)", now: now)
            decision.state = .ignored
            decision.goal = nil
        }
        decision.resolvedAt = now
        try store.update(decision)
        return decision
    }

    /// Puts a thing on a goal, and on the goal's item it works on when that is clear (`AttachItems`): the link names
    /// the item, and the item links the session or chat.
    func attach(
        _ subject: AttachSubject, to goal: String, origin: GoalLink.Origin, confidence: Double? = nil,
        reason: String? = nil, now: Date
    ) throws {
        let item = try AttachItems.match(subject, items: store.items().filter { $0.goal == goal })
        try attach(GoalLink(
            goal: goal, kind: subject.kind, target: subject.id, origin: origin, item: item?.id, confidence: confidence,
            reason: reason, at: now
        ))
        if let item { try link(item: item.id, GoalItem.Link(subject.kind == .chat ? .chat : .session, subject.id)) }
    }

    /// A goal from a suggestion: its drafted `GOAL.md` (v1 from its title and statement, v2 the draft when it says
    /// more), and every thing in it attached (origin `asked`: you pressed the key).
    @discardableResult
    func create(suggestion: GoalSuggestion, draft: String, now: Date) throws -> HeedGoal {
        let doc = GoalDoc.parse(draft)
        let title = doc.title.isEmpty ? suggestion.title : doc.title
        let goal = try create(title: title, statement: doc.goal, now: now)
        var full = doc
        full.title = title
        try save(goal: goal.id, doc: full, note: "drafted by heed", author: .heed, now: now)
        for subject in suggestion.subjects {
            try attach(GoalLink(
                goal: goal.id, kind: subject.kind, target: subject.id, origin: .asked,
                reason: "suggested goal: " + suggestion.terms.prefix(3).joined(separator: ", "), at: now
            ))
            if var latest = try store.latestDecision(kind: subject.kind, target: subject.id) {
                latest.state = .clustered
                latest.goal = goal.id
                latest.resolvedAt = now
                try store.update(latest)
            }
        }
        return goal
    }

    /// Stores decisions as they are (fixtures).
    func adopt(decisions: [AttachDecision]) throws {
        for decision in decisions.sorted(by: { $0.at < $1.at }) {
            _ = try store.insert(decision)
        }
    }
}
