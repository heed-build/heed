import Foundation

/// `[personas]`: when the library's personas look at a session's work. Quiet by default: nothing while the agent
/// works; heed offers a look only when one of these milestones happens, once per milestone.
public struct SessionPanelSettings: Hashable, Sendable {
    /// What heed does at a milestone: offer a look (the line at the session's foot), look without asking, or nothing.
    public enum Offers: String, Hashable, Sendable, CaseIterable {
        case ask, look, never

        public var label: String {
            switch self {
            case .ask: "ask me"
            case .look: "look without asking"
            case .never: "never"
            }
        }
    }

    /// A lot got built: `builtFiles` files or `builtLines` lines changed since the last look.
    public var built = true
    public var builtFiles = 10
    public var builtLines = 300
    /// The agent says it's done, in its turn's last words.
    public var saysDone = true
    /// Before a PR opens: the agent's `gh pr create` held up to `holdSeconds` while the panel looks.
    public var beforePR = true
    public var holdSeconds = 120
    /// The session starts changing a repo it had not.
    public var secondRepo = false
    /// Hours of work since the panel last looked.
    public var long = false
    public var longHours = 4
    public var offers: Offers = .ask

    public init() {}

    /// The most `hold_seconds` can say: the hook's own ceiling leaves room for the approvals' wait after it.
    public static let maxHold = 180

    public func isOn(_ kind: SessionMilestone.Kind) -> Bool {
        switch kind {
        case .built: built
        case .saysDone: saysDone
        case .beforePR: beforePR
        case .secondRepo: secondRepo
        case .long: long
        case .asked: true
        }
    }
}

/// Something that happened in a session worth a look: what the offer line says.
public struct SessionMilestone: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case built, saysDone, beforePR, secondRepo, long
        /// You asked (`gL`, the menu's Ask the panel…), with no milestone.
        case asked

        /// The line's lead.
        public var title: String {
            switch self {
            case .built: "A lot got built"
            case .saysDone: "The agent says it's done"
            case .beforePR: "Before this PR opens"
            case .secondRepo: "A second repo"
            case .long: "Long without a look"
            case .asked: "You asked"
            }
        }
    }

    public var kind: Kind
    /// What makes it this milestone and no other: one offer per key.
    public var key: String
    public var at: Date
    /// Changed since the last look, when measured.
    public var files: Int?
    public var added: Int?
    public var removed: Int?
    /// The agent's words that say it's done ("I think this part is done").
    public var quote: String?
    /// The repo it started changing.
    public var repo: String?
    /// Hours since the last look.
    public var hours: Int?

    public init(
        kind: Kind, key: String, at: Date, files: Int? = nil, added: Int? = nil, removed: Int? = nil,
        quote: String? = nil, repo: String? = nil, hours: Int? = nil
    ) {
        self.kind = kind
        self.key = key
        self.at = at
        self.files = files
        self.added = added
        self.removed = removed
        self.quote = quote
        self.repo = repo
        self.hours = hours
    }

    /// `14 files`, `+612 −88`, `"I think this part is done"`: what happened, in pieces.
    public var details: [String] {
        var parts: [String] = []
        if let files, files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if let added, let removed, added + removed > 0 { parts.append("+\(added) −\(removed)") }
        if let repo { parts.append(repo) }
        if let hours { parts.append("\(hours) h since the last look") }
        if let quote { parts.append("\u{201C}\(quote)\u{201D}") }
        return parts
    }
}

/// What heed knows about a session's work now, for its milestones.
public struct SessionWork: Hashable, Sendable {
    /// Files and lines that differ from the base, over its worktrees; nil before they were measured.
    public var files: Int?
    public var added: Int?
    public var removed: Int?
    /// Every repo it changes (`org/name`).
    public var repos: [String]
    /// What its agent said last.
    public var lastMessage: String?
    /// Its turn just ended (the last message is new).
    public var turnEnded: Bool

    public init(
        files: Int? = nil, added: Int? = nil, removed: Int? = nil, repos: [String] = [], lastMessage: String? = nil,
        turnEnded: Bool = false
    ) {
        self.files = files
        self.added = added
        self.removed = removed
        self.repos = repos
        self.lastMessage = lastMessage
        self.turnEnded = turnEnded
    }

    public var lines: Int? { added.flatMap { added in removed.map { added + $0 } } }
}

/// Where a session stood at the panel's last look (or when heed first saw it): milestones count from here.
public struct SessionPanelBaseline: Hashable, Sendable, Codable {
    public var files: Int
    public var added: Int
    public var removed: Int
    public var repos: [String]
    public var at: Date

    public init(files: Int = 0, added: Int = 0, removed: Int = 0, repos: [String] = [], at: Date) {
        self.files = files
        self.added = added
        self.removed = removed
        self.repos = repos
        self.at = at
    }

    public init(_ work: SessionWork, at: Date) {
        self.init(
            files: work.files ?? 0, added: work.added ?? 0, removed: work.removed ?? 0, repos: work.repos, at: at
        )
    }

    public var lines: Int { added + removed }
}

/// The panel's state for one session: where it counts from, what was offered, the offer showing, the last look, and
/// whether you said never here.
public struct SessionPanelRecord: Hashable, Sendable, Codable {
    public var since: SessionPanelBaseline
    /// Milestones offered or looked at: one offer each.
    public var offered: Set<String>
    /// The offer at the session's foot.
    public var offer: SessionMilestone?
    /// The panel's last look, until dismissed.
    public var look: SessionLook?
    /// "Never here": no offer in this session again (you can still ask).
    public var neverHere: Bool

    public init(
        since: SessionPanelBaseline, offered: Set<String> = [], offer: SessionMilestone? = nil,
        look: SessionLook? = nil, neverHere: Bool = false
    ) {
        self.since = since
        self.offered = offered
        self.offer = offer
        self.look = look
        self.neverHere = neverHere
    }

    /// A session heed sees for the first time: it counts from where it is, so work done before is not a milestone.
    public static func start(_ work: SessionWork, at: Date) -> SessionPanelRecord {
        SessionPanelRecord(since: SessionPanelBaseline(work, at: at))
    }

    /// The offer goes on the line; its milestone is not offered again.
    public mutating func offering(_ milestone: SessionMilestone) {
        offer = milestone
        offered.insert(milestone.key)
    }

    /// "Not now": the offer goes, and milestones count again from here, so the next one is a new one.
    public mutating func notNow(_ work: SessionWork, at: Date) {
        offer = nil
        since = SessionPanelBaseline(work, at: at)
    }

    /// "Never here": no more offers in this session.
    public mutating func never() {
        offer = nil
        neverHere = true
    }

    /// The panel looked: its verdict replaces the offer, and milestones count from here.
    public mutating func looked(_ look: SessionLook, work: SessionWork) {
        offered.insert(look.milestone.key)
        offer = nil
        self.look = look
        since = SessionPanelBaseline(work, at: look.at)
    }
}

/// Finding a session's milestones: what changed since the panel's last look, against the settings.
public enum SessionMilestones {
    /// The milestone a session reached, if any not offered yet: a lot got built first (carrying the agent's words
    /// when it also says it's done), then says it's done, a second repo, long without a look.
    public static func detect(
        _ work: SessionWork, record: SessionPanelRecord, settings: SessionPanelSettings, now: Date
    ) -> SessionMilestone? {
        let since = record.since
        let quote = settings.saysDone && work.turnEnded ? work.lastMessage.flatMap(SaysDone.quote) : nil
        var candidates: [SessionMilestone] = []
        if settings.built, let files = work.files, let added = work.added, let removed = work.removed {
            let moreFiles = files - since.files
            let moreLines = added + removed - since.lines
            if moreFiles >= settings.builtFiles || moreLines >= settings.builtLines {
                candidates.append(SessionMilestone(
                    kind: .built, key: "built@\(Int(since.at.timeIntervalSince1970))", at: now,
                    files: max(files - since.files, 0), added: max(added - since.added, 0),
                    removed: max(removed - since.removed, 0), quote: quote
                ))
            }
        }
        if let quote, let message = work.lastMessage {
            candidates.append(SessionMilestone(
                kind: .saysDone, key: "done@\(stableHash(message))", at: now, quote: quote
            ))
        }
        if settings.secondRepo, !since.repos.isEmpty,
           let repo = work.repos.first(where: { !since.repos.contains($0) })
        {
            candidates.append(SessionMilestone(kind: .secondRepo, key: "repo@\(repo)", at: now, repo: repo))
        }
        if settings.long, settings.longHours > 0 {
            let hours = Int(now.timeIntervalSince(since.at) / 3600)
            let grew = (work.lines ?? 0) > since.lines
            if hours >= settings.longHours, grew {
                candidates.append(SessionMilestone(
                    kind: .long, key: "long@\(Int(since.at.timeIntervalSince1970))", at: now, hours: hours
                ))
            }
        }
        return candidates.first { !record.offered.contains($0.key) }
    }

    /// The same text hashes the same in every launch (Swift's own hash does not).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}

/// Reading an agent's turn end for "it's done": a done marker in its last words, and not a question to you.
public enum SaysDone {
    /// Words that say the work (or a part of it) is done, matched in the last few sentences.
    static let markers = [
        #"\b(i think |i believe )?(this|that|it|the (task|work|change|feature|fix|part))( part)? is (now )?(done|complete|finished|ready)\b"#,
        #"\bready for (review|a review|your review|a look)\b"#,
        #"\b(all|everything) (is )?(done|implemented|complete|finished)\b"#,
        #"\b(i'm|i am|we're|we are) done\b"#,
        #"\bthat'?s (it|everything)\b"#,
        #"\bimplementation is complete\b"#,
        #"^done[.!]?$"#,
    ]

    /// The sentence that says it is done (at most twelve words), or nil when the last words do not say so, or ask you
    /// something instead.
    public static func quote(_ text: String) -> String? {
        guard !TurnEnd.asksYou(text) else { return nil }
        let tail = TurnEnd.withoutTrailingCode(text)
        let sentences = tail.replacingOccurrences(of: "\n", with: ". ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for sentence in sentences.suffix(3).reversed() {
            let lowered = TurnEnd.normalized(sentence)
            if markers.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) {
                let words = sentence.split(separator: " ")
                return words.count > 12 ? words.prefix(12).joined(separator: " ") + "…" : sentence
            }
        }
        return nil
    }
}

/// What heed does at a milestone, by the settings and the session.
public enum SessionPanelPolicy {
    public enum Action: Equatable, Sendable {
        case nothing
        /// The offer line: Ask N personas for a look?
        case offer
        /// Look at once ("look without asking").
        case look
    }

    public static func action(
        _ milestone: SessionMilestone, settings: SessionPanelSettings, record: SessionPanelRecord, relevant: Int
    ) -> Action {
        guard milestone.kind != .asked else { return relevant > 0 ? .look : .nothing }
        guard settings.isOn(milestone.kind), !record.neverHere, relevant > 0 else { return .nothing }
        switch settings.offers {
        case .ask: return .offer
        case .look: return .look
        case .never: return .nothing
        }
    }
}

/// Who looks at a session: the library's personas that join sessions ("before a PR", "every session's plan"), on and
/// in scope for its repos, at most three, most relevant first.
public enum SessionPanelInvites {
    public static let limit = 3

    /// It joins sessions on its own.
    public static func joinsSessions(_ persona: Persona) -> Bool {
        persona.joins.contains(.beforePR) || persona.joins.contains(.everyPlan)
    }

    /// The relevant personas for a session in `repos`: a narrower scope first (a repo's before an org's before
    /// everywhere), then what heed learned or read from your repos before yours and its own, then by name. Before a PR,
    /// the ones that join before a PR go first.
    public static func relevant(
        _ library: PersonaLibrary, repos: [String], for kind: SessionMilestone.Kind? = nil, limit: Int = limit
    ) -> [Persona] {
        let sources: [PersonaSource] = [.learned, .repos, .yours, .builtIn]
        let ranked = library.offered(for: repos).filter(joinsSessions).sorted { lhs, rhs in
            if kind == .beforePR {
                let left = lhs.joins.contains(.beforePR), right = rhs.joins.contains(.beforePR)
                if left != right { return left }
            }
            if lhs.scope.narrowness != rhs.scope.narrowness { return lhs.scope.narrowness > rhs.scope.narrowness }
            let left = sources.firstIndex(of: lhs.source) ?? 0, right = sources.firstIndex(of: rhs.source) ?? 0
            if left != right { return left < right }
            // heed's own in the panel's order: the Skeptic before the Purist.
            if lhs.source == .builtIn, rhs.source == .builtIn {
                let order = BuiltInPersonas.seats.map(\.id)
                return (order.firstIndex(of: lhs.id) ?? 0) < (order.firstIndex(of: rhs.id) ?? 0)
            }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        return Array(ranked.prefix(limit))
    }

    /// Who looks when you ask by hand: the ones you picked (by id), else the relevant ones, else the Skeptic and your
    /// team's style when heed has one, so asking always gets someone.
    public static func asked(_ library: PersonaLibrary, repos: [String], picked: [String] = []) -> [Persona] {
        let offered = library.offered(for: repos)
        if !picked.isEmpty {
            let chosen = picked.compactMap { id in offered.first { $0.id == id || $0.id == Persona.slug(id) } }
            if !chosen.isEmpty { return chosen }
        }
        let relevant = relevant(library, repos: repos)
        if !relevant.isEmpty { return relevant }
        var fallback = offered.filter { $0.id == PanelInvites.skeptic.id }
        if let style = library.teamStyle(for: repos), !fallback.contains(style) { fallback.append(style) }
        return fallback
    }

    /// Who Ask the panel… offers to pick from: the relevant ones, then your own in scope, then the panel's four who
    /// always sit; at most `limit`.
    public static func choices(_ library: PersonaLibrary, repos: [String], limit: Int = 8) -> [Persona] {
        var result = relevant(library, repos: repos, limit: limit)
        let always = Set([PanelInvites.skeptic, PanelInvites.purist, PanelInvites.scopeKeeper, PanelInvites.ux]
            .map(\.id))
        for persona in library.offered(for: repos)
            where !result.contains(persona) && (persona.source != .builtIn || always.contains(persona.id))
        {
            result.append(persona)
        }
        return Array(result.prefix(limit))
    }

    /// Their seats on the session's panel.
    public static func seats(_ personas: [Persona]) -> [PanelSeat] {
        personas.map { PanelSeat.from($0, why: $0.scope.label) }
    }
}

public extension SessionWork {
    /// A session's work now, from its own worktrees' sizes against their base (each counted once).
    static func of(_ session: Session, worktrees: [Worktree], turnEnded: Bool) -> SessionWork {
        var seen: Set<String> = []
        var files: Int?, added: Int?, removed: Int?
        for worktree in worktrees where session.owns(worktree) && seen.insert(worktree.path).inserted {
            guard let status = worktree.status, let more = status.added, let less = status.removed else { continue }
            files = (files ?? 0) + (status.files ?? 0)
            added = (added ?? 0) + more
            removed = (removed ?? 0) + less
        }
        return SessionWork(
            files: files, added: added, removed: removed, repos: session.involvedRepos.map(\.slug),
            lastMessage: session.lastMessage, turnEnded: turnEnded
        )
    }
}

/// What the panel reads of a session's diff: its worktrees' changes against where they left their base, from git,
/// off the main actor; at most three worktrees, each bounded later by the prompt.
public enum SessionDiff {
    public static let worktreeLimit = 3

    public static func read(_ worktrees: [Worktree]) async -> (diff: String, stat: DiffStat?) {
        var diffs: [String] = []
        var total: DiffStat?
        for worktree in worktrees.prefix(worktreeLimit) {
            let arguments = ["-C", worktree.path, "diff", "--merge-base", "origin/HEAD"]
            if let text = try? await ProcessRunner.output(
                on: worktree.location, "git", arguments, timeout: .seconds(15), caller: "panel.diff"
            ) {
                diffs.append(text)
            }
            if let short = try? await ProcessRunner.output(
                on: worktree.location, "git", arguments + ["--shortstat"], timeout: .seconds(15), caller: "panel.diff"
            ), let stat = DiffStat.parse(short) {
                total = DiffStat(
                    files: (total?.files ?? 0) + stat.files, added: (total?.added ?? 0) + stat.added,
                    removed: (total?.removed ?? 0) + stat.removed
                )
            }
        }
        return (diffs.joined(separator: "\n"), total)
    }
}
