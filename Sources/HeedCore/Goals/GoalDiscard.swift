import Foundation

/// What discarding a goal does: a goal that nothing was ever attached to is deleted for good, any other is archived
/// (`a` in the Goals list brings it back). Pure, so the confirmation can say what will happen before it does.
public struct GoalDiscard: Hashable, Sendable {
    public enum Outcome: String, Hashable, Sendable { case delete, archive }

    /// Sessions, chats, PRs, runs and reviews on the goal.
    public var links = 0
    /// Swarm runs the goal has had.
    public var swarms = 0
    /// The wizard's Go was pressed: the goal started something.
    public var wentGo = false
    /// The goal is mirrored to a GitHub issue.
    public var mirrored = false

    public init(links: Int = 0, swarms: Int = 0, wentGo: Bool = false, mirrored: Bool = false) {
        self.links = links
        self.swarms = swarms
        self.wentGo = wentGo
        self.mirrored = mirrored
    }

    /// The goal's facts as the snapshot and its wizard show them.
    public init(goal id: String, in snapshot: GoalSnapshot, wizard: GoalWizard?) {
        self.init(
            links: snapshot.links.count(where: { $0.goal == id }), swarms: snapshot.swarms(of: id).count,
            wentGo: wizard.map { $0.swarm != nil || $0.completed.contains(.go) } ?? false,
            mirrored: snapshot.goal(id)?.tracker != nil
        )
    }

    /// Nothing attached: no sessions, chats or PRs, no swarm, Go never pressed, no GitHub issue.
    public var outcome: Outcome {
        links == 0 && swarms == 0 && !wentGo && !mirrored ? .delete : .archive
    }

    /// What is attached, in words: "2 sessions and a PR", empty when nothing is.
    public var attached: String {
        var parts: [String] = []
        if links > 0 { parts.append(links == 1 ? "1 session, chat or PR" : "\(links) sessions, chats or PRs") }
        if swarms > 0 { parts.append(swarms == 1 ? "a swarm" : "\(swarms) swarms") }
        if wentGo, swarms == 0 { parts.append("a started plan") }
        if mirrored { parts.append("a GitHub issue") }
        return parts.joined(separator: ", ")
    }
}

public extension GoalOps {
    /// `wizard.discard`: deletes the goal when nothing is attached, else archives it; what it did. Checks the store,
    /// not what the caller saw: `expecting` (what the confirmation said it would do) refuses, changing nothing, when
    /// the store says otherwise, so a dialog that said Archive never deletes.
    @discardableResult
    func discard(goal id: String, expecting: GoalDiscard.Outcome? = nil, now: Date) throws -> GoalDiscard.Outcome {
        let snapshot = try store.snapshot()
        guard snapshot.goal(id) != nil else { throw GoalOpError.unknownGoal(id) }
        let facts = try GoalDiscard(goal: id, in: snapshot, wizard: store.wizards()[id])
        if let expecting, facts.outcome != expecting { throw GoalOpError.discardChanged(facts.outcome) }
        switch facts.outcome {
        case .delete:
            try store.delete(goal: id)
            if files.writes { try? FileManager.default.removeItem(at: files.folder(id)) }
        case .archive:
            try setStatus(goal: id, .archived, now: now)
        }
        return facts.outcome
    }
}

extension GoalStore {
    /// The goal and everything kept about it, in one transaction. Swarm runs are never deleted (their plan versions are
    /// append-only), so a goal that had one is archived instead; this refuses it.
    func delete(goal id: String) throws {
        try database.transaction {
            let swarms = try database.scalar("SELECT COUNT(*) FROM goal_swarms WHERE goal = ?", [.text(id)])?.int ?? 0
            guard swarms == 0 else { throw GoalOpError.source("\(id) had a swarm: it is archived, never deleted") }
            let key = [SQLiteValue.text(id)]
            for table in [
                "goal_versions", "goal_links", "goal_items", "goal_evidence", "goal_edits", "goal_reviews",
                "goal_evaluations", "goal_attach_decisions", "goal_mirrors", "goal_sources", "goal_wizards",
            ] {
                try database.run("DELETE FROM \(table) WHERE goal = ?", key)
            }
            try database.run("DELETE FROM goals WHERE id = ?", key)
        }
    }
}
