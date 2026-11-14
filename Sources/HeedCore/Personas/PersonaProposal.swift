import Foundation

/// A person your repos serve, as a cheap model proposed it from the digest: the persona drafted, how strongly the
/// evidence points at it (0–100), the evidence in one line, and the library persona it overlaps, if any.
public struct PersonaProposal: Hashable, Sendable, Identifiable {
    public var persona: Persona
    public var strength: Int
    /// `CODEOWNERS · 38 link comments · required check`.
    public var summary: String
    /// The library persona it overlaps (`newcomer`), when it does.
    public var overlaps: String?
    /// You described it (`i`), rather than heed finding it.
    public var described: Bool

    public init(persona: Persona, strength: Int, summary: String, overlaps: String? = nil, described: Bool = false) {
        self.persona = persona
        self.strength = strength
        self.summary = summary
        self.overlaps = overlaps
        self.described = described
    }

    public var id: String { persona.id }
}

/// What to do about a proposal that overlaps a library persona.
public enum PersonaOverlapChoice: String, Hashable, Sendable {
    /// The proposal becomes a sharper version of the library persona, in the proposal's scope.
    case sharpen
    /// Both stay.
    case keep
}

/// Reading the model's proposals: at most `limit`, one per name, each with evidence (unless you described it), the
/// strongest first; scoped inside the repos read; overlaps with the library named.
public enum PersonaProposals {
    public static let limit = 6

    /// The model's `{"personas": [{"name", "who", "asksFirst", "skepticalAbout", "evidence", "summary", "strength",
    /// "scope", "overlaps"}]}`.
    public static func parse(
        _ text: String, repos: [String], library: [Persona], described: Bool = false, now: Date
    ) -> [PersonaProposal] {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let rows = (object["personas"] ?? object["people"]) as? [[String: Any]] ?? []
        var proposals: [PersonaProposal] = []
        for row in rows {
            func string(_ keys: String...) -> String {
                keys.lazy.compactMap { row[$0] as? String }.first.map(GoalDoc.oneLine) ?? ""
            }
            func strings(_ keys: String...) -> [String] {
                for key in keys {
                    let values = SwarmPlanInput.strings(row[key]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
                    if !values.isEmpty { return values }
                }
                return []
            }
            let name = string("name")
            guard !name.isEmpty else { continue }
            let evidence = strings("evidence")
            guard described || !evidence.isEmpty else { continue }
            let strength: Int = if let number = row["strength"] as? Double {
                Int(number.rounded())
            } else if let text = row["strength"] as? String, let number = Int(text) {
                number
            } else {
                described ? 70 : 50
            }
            let scope = Self.scope(PersonaScope(text: string("scope")), repos: repos)
            let persona = Persona(
                name: name, skepticalAbout: strings("skepticalAbout", "skeptical_about"),
                asksFirst: strings("asksFirst", "asks_first").prefix(2).map { $0 }, mayNot: ["edit code"],
                who: string("who"), about: string("about"), scope: scope, joins: [.goalPanels], source: .repos,
                evidence: Array(evidence.prefix(6)), added: now
            )
            let named = string("overlaps").lowercased()
            let overlap = library
                .first { $0.id == named || $0.name.lowercased() == named || $0.id == Persona.slug(named) }
                ?? Self.overlap(persona, in: library)
            let summary = string("summary")
            proposals.append(PersonaProposal(
                persona: persona, strength: min(max(strength, 0), 100),
                summary: summary.isEmpty ? evidence.prefix(3).joined(separator: " · ") : summary,
                overlaps: overlap?.id,
                described: described
            ))
        }
        return rank(proposals)
    }

    /// Strongest first (ties by name), one per name, at most `limit`.
    public static func rank(_ proposals: [PersonaProposal]) -> [PersonaProposal] {
        var seen = Set<String>()
        return proposals.sorted {
            $0.strength == $1.strength ? $0.persona.name < $1.persona.name : $0.strength > $1.strength
        }
        .filter { seen.insert($0.id).inserted }
        .prefix(limit).map { $0 }
    }

    /// A scope inside what was read: the model's when it applies to the repos read, else the one repo, else their
    /// one org; repos across orgs give the first repo, never everywhere (no persona crosses the org wall).
    public static func scope(_ proposed: PersonaScope?, repos: [String]) -> PersonaScope {
        if let proposed, proposed != .everywhere, proposed.applies(to: repos) { return proposed }
        guard let first = repos.first else { return .everywhere }
        if repos.count == 1 { return .repo(first) }
        let orgs = Set(repos.compactMap { $0.split(separator: "/").first.map { String($0).lowercased() } })
        if orgs.count == 1, let org = first.split(separator: "/").first { return .org(String(org)) }
        return .repo(first)
    }

    /// The library persona a proposal says the same as: the same name, or most of the same words in who it is and
    /// what it asks first.
    public static func overlap(_ persona: Persona, in library: [Persona]) -> Persona? {
        let words = Self.words(persona)
        guard !words.isEmpty else { return nil }
        var best: (Persona, Double)?
        for other in library {
            if other.id == persona.id { return other }
            let theirs = Self.words(other)
            guard !theirs.isEmpty else { continue }
            // The share of the shorter one's words the two have in common.
            let share = Double(words.intersection(theirs).count) / Double(min(words.count, theirs.count))
            if share >= 0.5, share > best?.1 ?? 0 { best = (other, share) }
        }
        return best?.0
    }

    private static let stop: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "it", "is", "in", "on", "for", "this", "that", "with", "from",
        "what", "who", "how", "does", "do", "can", "could", "will", "would", "i", "we", "they", "be", "at", "all",
        "only", "still", "use", "uses", "using",
    ]

    static func words(_ persona: Persona) -> Set<String> {
        let text = ([persona.name, persona.who] + persona.asksFirst).joined(separator: " ").lowercased()
        return Set(text.split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// A proposal resolved against the persona it overlaps: sharpened, it becomes that persona made for its scope
    /// ("Newcomer for acme", in the built-in's seat there); kept, it stands as it is.
    public static func resolve(
        _ proposal: PersonaProposal, _ choice: PersonaOverlapChoice, library: PersonaLibrary
    ) -> PersonaProposal {
        guard choice == .sharpen, let id = proposal.overlaps, let base = library.entry(id)?.persona else {
            var kept = proposal
            kept.overlaps = nil
            return kept
        }
        var persona = proposal.persona
        let place = switch persona.scope {
        case .everywhere: "you"
        case let .org(org): org
        case let .repo(repo): repo.split(separator: "/").last.map(String.init) ?? repo
        }
        persona.name = "\(base.name) for \(place)"
        persona.sharpens = base.sharpens ?? base.id
        persona.skepticalAbout = Self.merged(base.skepticalAbout, persona.skepticalAbout)
        persona.asksFirst = Self.merged(persona.asksFirst, base.asksFirst).prefix(2).map { $0 }
        persona.knows = Self.merged(base.knows, persona.knows)
        if persona.who.isEmpty { persona.who = base.who }
        var sharpened = proposal
        sharpened.persona = persona
        sharpened.overlaps = nil
        return sharpened
    }

    private static func merged(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.lowercased()).inserted }
    }
}
