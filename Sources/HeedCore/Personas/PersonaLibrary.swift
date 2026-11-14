import Foundation

/// Where a library persona applies: everywhere, in one org's repos, or in one repo.
public enum PersonaScope: Hashable, Sendable, Codable {
    case everywhere
    case org(String)
    case repo(String)

    /// `everywhere`, `org acme`, `repo acme/docs-website`; read leniently (`org: acme`, a bare `acme/site` is a repo,
    /// a bare `acme` an org). Nil for nothing.
    public init?(text: String) {
        var words = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        if ["everywhere", "all", "any", "global"].contains(first) {
            self = .everywhere
            return
        }
        if first == "org" || first == "repo" { words.removeFirst() }
        guard let value = words.first, !value.isEmpty else { return nil }
        if first == "org" {
            self = .org(value)
        } else if first == "repo" || value.contains("/") {
            self = .repo(value)
        } else {
            self = .org(value)
        }
    }

    public var text: String {
        switch self {
        case .everywhere: "everywhere"
        case let .org(org): "org \(org)"
        case let .repo(repo): "repo \(repo)"
        }
    }

    /// As a row shows it: `everywhere`, `org: acme`, `acme/docs-website`.
    public var label: String {
        switch self {
        case .everywhere: "everywhere"
        case let .org(org): "org: \(org)"
        case let .repo(repo): repo
        }
    }

    /// The org it is walled into, nil for everywhere.
    public var org: String? {
        switch self {
        case .everywhere: nil
        case let .org(org): org
        case let .repo(repo): repo.split(separator: "/").first.map(String.init)
        }
    }

    /// Whether it applies to work in `repos` (`org/name` slugs). Everywhere always does; an org's or a repo's only when
    /// the work touches that org or repo, so a persona drawn from one org's repos is never offered in another's, and
    /// never to work whose repos heed does not know.
    public func applies(to repos: [String]) -> Bool {
        switch self {
        case .everywhere:
            true
        case let .org(org):
            repos.contains { $0.split(separator: "/").first.map(String.init)?.lowercased() == org.lowercased() }
        case let .repo(repo):
            repos.contains { $0.lowercased() == repo.lowercased() }
        }
    }

    /// How narrow it is: a repo's beats an org's beats everywhere, when two could sit in one seat.
    public var narrowness: Int {
        switch self {
        case .everywhere: 0
        case .org: 1
        case .repo: 2
        }
    }
}

/// What a library persona joins on its own.
public enum PersonaJoin: String, Hashable, Sendable, Codable, CaseIterable {
    /// The panel of every goal whose work is in its scope.
    case goalPanels
    /// Sessions in its scope, before they open a PR.
    case beforePR
    /// Every session's plan in its scope.
    case everyPlan

    public init?(text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        switch key {
        case "goalpanels", "goalpanel", "panels", "panel": self = .goalPanels
        case "beforeapr", "beforepr", "beforeprs", "pr": self = .beforePR
        case "everyplan", "everysessionsplan", "plans", "plan": self = .everyPlan
        default: return nil
        }
    }

    public var text: String {
        switch self {
        case .goalPanels: "goal panels"
        case .beforePR: "before a PR"
        case .everyPlan: "every plan"
        }
    }

    /// The switch's words, for a persona in `scope`.
    public func label(_ scope: PersonaScope) -> String {
        let place = switch scope {
        case .everywhere: nil as String?
        case let .org(org): org
        case let .repo(repo): repo.split(separator: "/").last.map(String.init)
        }
        switch self {
        case .goalPanels: return "goal panels" + (place.map { " touching \($0)" } ?? "")
        case .beforePR: return "sessions" + (place.map { " in \($0)" } ?? "") + ": before a PR"
        case .everyPlan: return "every session's plan"
        }
    }
}

/// Where a library persona came from.
public enum PersonaSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// One of heed's panel personas.
    case builtIn
    /// Proposed from your repos (Add a persona).
    case repos
    /// Learned from how your team works.
    case learned
    /// Written by you, or shared from a goal.
    case yours

    public init?(text: String) {
        switch text.lowercased().filter(\.isLetter) {
        case "builtin", "heed": self = .builtIn
        case "repos", "repo", "fromyourrepos": self = .repos
        case "learned": self = .learned
        case "yours", "you", "goal", "shared": self = .yours
        default: return nil
        }
    }

    public var text: String {
        switch self {
        case .builtIn: "built in"
        case .repos: "repos"
        case .learned: "learned"
        case .yours: "yours"
        }
    }

    /// The filter's and the row's words.
    public var label: String {
        switch self {
        case .builtIn: "built in"
        case .repos: "from your repos"
        case .learned: "learned"
        case .yours: "yours"
        }
    }
}

/// heed's own personas, the panel's: in the library from the start, each with the question it asks first. Turned off
/// or edited, one gets a file in the library that says so.
public enum BuiltInPersonas {
    /// Everything the built-in panel seat says, as a persona.
    public static func persona(_ seat: PanelSeat) -> Persona {
        let detail = details[seat.id]
        return Persona(
            name: seat.name, skepticalAbout: detail?.skeptical ?? [], asksFirst: detail.map { [$0.asks] } ?? [],
            notes: seat.brief, who: seat.role, scope: .everywhere, joins: [.goalPanels], source: .builtIn
        )
    }

    /// Every seat PanelInvites knows, in its order: the four who always sit, then each signal's.
    public static var seats: [PanelSeat] {
        var seen = Set<String>()
        let all = [PanelInvites.skeptic, PanelInvites.purist, PanelInvites.scopeKeeper, PanelInvites.ux]
            + PanelInvites.Signal.allCases.flatMap { PanelInvites.seats(for: $0) }
        return all.filter { seen.insert($0.id).inserted }
    }

    public static var all: [Persona] { seats.map(persona) }

    public static var ids: Set<String> { Set(seats.map(\.id)) }

    private static let details: [String: (asks: String, skeptical: [String])] = [
        "skeptic": ("Should we do this at all?", ["work nobody asked for", "big plans for small problems"]),
        "purist": ("Is there a simpler design that's still right?", ["special cases", "two ways to do one thing"]),
        "scope-keeper": ("What can we leave out?", ["scope creep", "nice-to-haves"]),
        "ux": ("Will the person using it know what happened?", ["vague errors", "hidden state"]),
        "dx": ("Can someone build on this without reading the code?", ["breaking changes", "unclear settings"]),
        "newcomer": ("Could I use this from the docs alone?", ["jargon", "steps the docs skip"]),
        "adversary": ("What input, timing or failure breaks it?", ["happy-path tests", "unchecked input"]),
        "operator": ("How do we roll it back at 3 am?", ["silent failures", "no rollback"]),
        "accessibility": ("Can I do it all by keyboard and screen reader?", ["colour alone", "focus traps"]),
        "security": ("What does this expose, and to whom?", ["secrets in logs", "trusting the network"]),
        "performance": ("What does it cost per call?", ["work on the hot path", "unbounded growth"]),
    ]
}

/// The library, Settings › Personas: heed's built-in personas and the files in `Application Support/Heed/personas/`,
/// one list. A file with a built-in's id is that built-in, edited or turned off; every other file is a persona of
/// your own, from your repos or learned. Goals, the wizard's panel and (later) sessions read who to ask from here.
public struct PersonaLibrary: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var persona: Persona
        /// It has a file in the library (a built-in only once edited or turned off).
        public var hasFile: Bool

        public var id: String { persona.id }
        public var isBuiltIn: Bool { persona.source == .builtIn }
    }

    public var entries: [Entry]

    /// Built-ins first in the panel's order (a file standing in for one), then the files: from your repos, learned,
    /// yours, each by name.
    public init(files: [String: Persona]) {
        var entries: [Entry] = BuiltInPersonas.seats.map { seat in
            if var file = files[seat.id] {
                file.source = .builtIn
                return Entry(persona: file, hasFile: true)
            }
            return Entry(persona: BuiltInPersonas.persona(seat), hasFile: false)
        }
        let order: [PersonaSource] = [.repos, .learned, .yours, .builtIn]
        let own = files.filter { !BuiltInPersonas.ids.contains($0.key) }.values.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.source) ?? 0
            let right = order.firstIndex(of: rhs.source) ?? 0
            return left == right ? lhs.name.lowercased() < rhs.name.lowercased() : left < right
        }
        entries += own.map { Entry(persona: $0, hasFile: true) }
        self.entries = entries
    }

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    public var personas: [Persona] { entries.map(\.persona) }

    /// How many come from each source, for the filter's chips.
    public func count(_ source: PersonaSource?) -> Int {
        source.map { source in entries.count { $0.persona.source == source } } ?? entries.count
    }

    public func filtered(_ source: PersonaSource?) -> [Entry] {
        source.map { source in entries.filter { $0.persona.source == source } } ?? entries
    }

    /// On, and in scope for work in `repos`: what may be offered there.
    public func offered(for repos: [String]) -> [Persona] {
        personas.filter { $0.on && $0.scope.applies(to: repos) }
    }

    /// The library persona that sits in a built-in's seat for work in `repos`: the narrowest one on, in scope, that
    /// sharpens it (a sharper Newcomer for acme).
    public func sharpened(_ id: String, for repos: [String]) -> Persona? {
        offered(for: repos).filter { $0.sharpens == id }.max { $0.scope.narrowness < $1.scope.narrowness }
    }

    /// Your team's style, when heed has one: a learned persona, or one named so. Only what exists; nothing is made up.
    public func teamStyle(for repos: [String]) -> Persona? {
        let offered = offered(for: repos)
        return offered.first { $0.source == .learned } ?? PanelInvites.teamStyle(in: offered)
    }

    /// The file a change writes: the persona as the library has it, toggled.
    public func toggled(_ id: String) -> Persona? {
        guard var persona = entry(id)?.persona else { return nil }
        persona.on.toggle()
        return persona
    }
}

/// A persona's last verdicts, from the panels that read a plan with it in a seat: the newest last, at most `limit`.
public enum PersonaVerdicts {
    public static let limit = 7

    public static func history(_ wizards: [GoalWizard], limit: Int = limit) -> [String: [PanelVerdict.Kind]] {
        var result: [String: [PanelVerdict.Kind]] = [:]
        for wizard in wizards.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            for round in wizard.panel.rounds {
                for verdict in round {
                    result[verdict.seat, default: []].append(verdict.kind)
                }
            }
        }
        return result.mapValues { Array($0.suffix(limit)) }
    }
}
