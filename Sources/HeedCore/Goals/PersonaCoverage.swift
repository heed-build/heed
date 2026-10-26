import Foundation

/// Where a persona stands on its goal.
public enum PersonaState: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// Needed now and nothing it is about has been looked at by it.
    case gap
    /// A session, chat or reviewer run with it is open or running now.
    case active
    /// Something it is about was looked at by it.
    case consulted
    /// Needed soon or later, and not looked at yet.
    case notYet = "not-yet"

    public var text: String { self == .notYet ? "not yet" : rawValue }

    /// Gaps first, then what is going on, then what was, then what can wait.
    public static func < (lhs: PersonaState, rhs: PersonaState) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How much of what a persona is about it has looked at.
public struct PersonaCoverage: Hashable, Sendable {
    /// Its items that a session, chat or review run with it (or a reviewer of its kind) touched.
    public var touched: Int
    /// Its items.
    public var total: Int
    public var state: PersonaState
    /// Sessions and chats with it, and its reviewers.
    public var sessions: Int
    public var chats: Int
    public var reviewers: Int
    /// Any of them open or running now.
    public var live: Bool

    public var share: Double { total == 0 ? 0 : Double(touched) / Double(total) }

    /// `2 of 5 items`.
    public var text: String { total == 0 ? "no items yet" : "\(touched) of \(total) item\(total == 1 ? "" : "s")" }

    /// What the spawn column says: `2 sess.`, `running`, `chat`, empty when nothing ran with it.
    public var spawned: String {
        if reviewers > 0, live, sessions == 0, chats == 0 { return "running" }
        if sessions > 0 { return "\(sessions) sess." }
        if chats > 0 { return chats == 1 ? "chat" : "\(chats) chats" }
        if reviewers > 0 { return reviewers == 1 ? "reviewer" : "\(reviewers) reviewers" }
        return ""
    }

    /// Who counts as the persona: the sessions, chats and reviewers spawned with it, and reviewers of its kind.
    static func touchers(need: PersonaNeed, spawns: [PersonaSpawn], reviewers: [ReviewerState])
        -> (sessions: Set<String>, chats: Set<String>, reviewers: Set<String>)
    {
        let mine = spawns.filter { $0.persona == need.id }
        var reviewerIDs = Set(mine.filter { $0.mode == .reviewer }.map(\.target))
        for reviewer in reviewers {
            if reviewer.config.persona.map(Persona.slug) == need.id { reviewerIDs.insert(reviewer.id) }
            if let kind = need.reviewer, reviewer.config.kind == kind, !reviewer.config.removed {
                reviewerIDs.insert(reviewer.id)
            }
        }
        return (
            Set(mine.filter { $0.mode == .session }.map(\.target)),
            Set(mine.filter { $0.mode == .chat }.map(\.target)),
            reviewerIDs
        )
    }

    /// A persona's coverage: the share of its items that its sessions, chats or reviewers touched (linked to the item,
    /// put the session on it, or left evidence on it), and its state. `live` holds the open sessions and chats and the
    /// running reviewers.
    public static func of(
        _ need: PersonaNeed, items: [GoalItem], evidence: [GoalEvidence], links: [GoalLink], spawns: [PersonaSpawn],
        reviewers: [ReviewerState], live: Set<String>
    ) -> PersonaCoverage {
        let who = touchers(need: need, spawns: spawns, reviewers: reviewers)
        let people = who.sessions.union(who.chats)
        let refs = Set(people).union(who.reviewers.map { "review:" + $0 })
        let mine = Set(need.items)
        let related = items.filter { mine.contains($0.id) }
        let touched = related.count { item in
            item.links.contains { link in
                link.kind == .review ? who.reviewers.contains(link.target) : people.contains(link.target)
            }
                || evidence.contains { $0.item == item.id && $0.ref.map(refs.contains) == true }
                || links.contains { $0.item == item.id && people.contains($0.target) }
        }
        let running = !people.union(who.reviewers).isDisjoint(with: live)
        let state: PersonaState = if running {
            .active
        } else if touched > 0 {
            .consulted
        } else if need.when == .now {
            .gap
        } else {
            .notYet
        }
        return PersonaCoverage(
            touched: touched, total: related.count, state: state, sessions: who.sessions.count,
            chats: who.chats.count, reviewers: who.reviewers.count, live: running
        )
    }
}

/// A row of the Personas pane: the need, its persona as its file says now, and its coverage.
public struct PersonaRow: Hashable, Sendable, Identifiable {
    public var need: PersonaNeed
    /// The goal's file for it (your edits), else the model's draft.
    public var persona: Persona
    public var coverage: PersonaCoverage

    public init(need: PersonaNeed, persona: Persona, coverage: PersonaCoverage) {
        self.need = need
        self.persona = persona
        self.coverage = coverage
    }

    public var id: String { need.id }

    /// A gap worth spawning for on its own: needed now, nothing looked at, and evidence asked for it.
    public var strongGap: Bool { coverage.state == .gap && need.when == .now && !need.evidence.isEmpty }
}

/// A goal's personas, folded from its record: the latest derivation, every spawn, and the rows in the pane's order.
public struct PersonaBoard: Hashable, Sendable {
    public var derivation: PersonaDerivation?
    public var derivedAt: Date?
    public var spawns: [PersonaSpawn]
    /// When each spawn was recorded, in the same order.
    public var spawnedAt: [Date]

    public static let empty = PersonaBoard(derivation: nil, derivedAt: nil, spawns: [], spawnedAt: [])

    public init(derivation: PersonaDerivation?, derivedAt: Date?, spawns: [PersonaSpawn], spawnedAt: [Date]) {
        self.derivation = derivation
        self.derivedAt = derivedAt
        self.spawns = spawns
        self.spawnedAt = spawnedAt
    }

    public static func fold(_ records: [QualityRecord]) -> PersonaBoard {
        var board = PersonaBoard.empty
        for record in records.sorted(by: { $0.at < $1.at }) {
            switch record.entry {
            case let .personas(derivation):
                board.derivation = derivation
                board.derivedAt = record.at
            case let .personaSpawn(spawn):
                board.spawns.append(spawn)
                board.spawnedAt.append(record.at)
            default: continue
            }
        }
        return board
    }

    /// The rows, gaps first: by state, then needed sooner, then the least covered, then by name. `files` are the
    /// goal's persona files by id.
    public func rows(
        files: [String: Persona], items: [GoalItem], evidence: [GoalEvidence], links: [GoalLink],
        reviewers: [ReviewerState], live: Set<String>
    ) -> [PersonaRow] {
        (derivation?.needs ?? []).map { need in
            PersonaRow(
                need: need, persona: files[need.id] ?? need.persona,
                coverage: PersonaCoverage.of(
                    need, items: items, evidence: evidence, links: links, spawns: spawns, reviewers: reviewers,
                    live: live
                )
            )
        }
        .sorted(by: Self.order)
    }

    static func order(_ lhs: PersonaRow, _ rhs: PersonaRow) -> Bool {
        if lhs.coverage.state != rhs.coverage.state { return lhs.coverage.state < rhs.coverage.state }
        if lhs.need.when != rhs.need.when { return lhs.need.when < rhs.need.when }
        if lhs.coverage.share != rhs.coverage.share { return lhs.coverage.share < rhs.coverage.share }
        return lhs.need.name.localizedStandardCompare(rhs.need.name) == .orderedAscending
    }
}

/// What heed does about gaps on its own: a strong gap (needed now, evidence-backed, nothing looked) is spawned as a
/// reviewer while the goal's day's reviewer budget lasts, once per persona; every other gap, and strong ones past the
/// budget, are suggested.
public enum PersonaAutoSpawn {
    public static func pick(rows: [PersonaRow], spawns: [PersonaSpawn], used: Int, limit: Int)
        -> (spawn: [String], suggest: [String])
    {
        var left = max(limit - used, 0)
        var spawn: [String] = []
        var suggest: [String] = []
        let reviewed = Set(spawns.filter { $0.mode == .reviewer }.map(\.persona))
        for row in rows where row.coverage.state == .gap {
            if row.strongGap, !reviewed.contains(row.id), left > 0 {
                spawn.append(row.id)
                left -= 1
            } else {
                suggest.append(row.id)
            }
        }
        return (spawn, suggest)
    }
}

public extension GoalAttention {
    /// One Attention item per active goal with gaps heed suggests (not spawned on its own): `gaps` maps a goal to the
    /// personas' names.
    static func personaGaps(goals: [HeedGoal], gaps: [String: [String]], at: [String: Date], now: Date)
        -> [AttentionItem]
    {
        goals.filter { $0.status == .active }.compactMap { goal in
            guard let names = gaps[goal.id], !names.isEmpty else { return nil }
            return AttentionItem(
                id: "goal:\(goal.id):personas", kind: .goal, repo: nil, number: nil,
                title: "\(goal.title): nobody has looked as \(names.joined(separator: ", ")) yet", url: nil,
                reasons: [.goalPersonaGap], updatedAt: at[goal.id] ?? now
            )
        }
    }
}
