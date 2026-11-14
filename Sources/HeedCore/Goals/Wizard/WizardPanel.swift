import Foundation

/// A persona on step 2's panel, and why it was invited.
public struct PanelSeat: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// What it stands for, in a few words ("argues not to do it").
    public var role: String
    /// Why it is on this panel: `always`, or what the goal touches ("public package", "changes behaviour").
    public var why: String
    /// How it reads a plan, for its prompt.
    public var brief: String

    public init(id: String, name: String, role: String, why: String, brief: String) {
        self.id = id
        self.name = name
        self.role = role
        self.why = why
        self.brief = brief
    }

    /// The letter on its tile.
    public var initial: String { String(name.first.map { $0.uppercased() } ?? "?") }

    /// A persona from heed's library (`Persona`), invited by hand with `+`.
    public static func from(_ persona: Persona, why: String = "you invited") -> PanelSeat {
        PanelSeat(
            id: persona.id, name: persona.name,
            role: persona.knows.first ?? persona.skepticalAbout.first.map { "skeptical about \($0)" } ?? "your persona",
            why: why, brief: persona.brief
        )
    }
}

/// Who sits on the panel: four always, more by what the goal touches, read from the plan's words and the repos.
public enum PanelInvites {
    /// What a goal can touch that invites someone.
    public enum Signal: String, Hashable, Sendable, CaseIterable {
        case publicPackage, behaviourChange, service, ui, authNet, hotPath

        public var why: String {
            switch self {
            case .publicPackage: "public package"
            case .behaviourChange: "changes behaviour"
            case .service: "runs as a service"
            case .ui: "has a UI"
            case .authNet: "auth or network"
            case .hotPath: "hot path"
            }
        }

        /// Words that show it, matched as whole words (a trailing `*` matches a prefix).
        var words: [String] {
            switch self {
            case .publicPackage:
                [
                    "package",
                    "packages",
                    "library",
                    "sdk",
                    "public api",
                    "npm",
                    "crate",
                    "nuget",
                    "pypi",
                    "toolkit",
                    "plugin",
                    "cli",
                    "semver",
                    "breaking change",
                ]
            case .behaviourChange:
                [
                    "pars*",
                    "behaviour",
                    "behavior",
                    "migrat*",
                    "format",
                    "fail the build",
                    "fails",
                    "warn*",
                    "default",
                    "redirect*",
                    "breaking",
                    "schema",
                    "validat*",
                ]
            case .service:
                [
                    "service",
                    "services",
                    "server",
                    "deploy*",
                    "daemon",
                    "endpoint*",
                    "queue",
                    "database",
                    "backfill",
                    "rollout",
                    "downtime",
                    "cluster",
                ]
            case .ui:
                [
                    "ui",
                    "screen*",
                    "view",
                    "views",
                    "button*",
                    "css",
                    "frontend",
                    "swiftui",
                    "dialog",
                    "layout",
                    "keyboard",
                ]
            case .authNet:
                [
                    "auth*",
                    "login",
                    "token*",
                    "oauth",
                    "network",
                    "http",
                    "https",
                    "tls",
                    "permission*",
                    "secret*",
                    "credential*",
                    "sso",
                ]
            case .hotPath:
                [
                    "perf*",
                    "fast",
                    "faster",
                    "latency",
                    "hot path",
                    "p95",
                    "p99",
                    "throughput",
                    "slow",
                    "cache",
                    "memory",
                    "ms",
                ]
            }
        }
    }

    public static let skeptic = PanelSeat(
        id: "skeptic", name: "Skeptic", role: "argues not to do it", why: "always",
        brief: "You argue that this should NOT be done, or should be much smaller: name the cheaper thing that gets most "
            + "of the value. Say happy only when there truly is no cheaper way."
    )
    public static let purist = PanelSeat(
        id: "purist", name: "Purist", role: "simplest correct design", why: "always",
        brief: "You want the simplest design that is correct: one way to do each thing, no duplicates, no special cases."
    )
    public static let scopeKeeper = PanelSeat(
        id: "scope-keeper", name: "Scope keeper", role: "cuts what isn't needed", why: "always",
        brief: "You cut every step the outcome does not need, and hold the line on what was agreed to be out of scope."
    )
    public static let ux = PanelSeat(
        id: "ux", name: "UX", role: "the person using it", why: "always",
        brief: "You are the person who uses the result: is it clear what happened, what to do next, and is the error "
            + "message enough?"
    )

    /// Who each signal brings.
    public static func seats(for signal: Signal) -> [PanelSeat] {
        switch signal {
        case .publicPackage:
            [
                PanelSeat(
                    id: "dx", name: "DX", role: "whoever builds on it", why: signal.why,
                    brief: "You build on this as a dependency: is the API, the setting and the upgrade path clear?"
                ),
                PanelSeat(
                    id: "newcomer", name: "Newcomer", role: "reads only the docs", why: signal.why,
                    brief: "You know only the docs and the messages: can you succeed without asking anyone?"
                ),
            ]
        case .behaviourChange:
            [PanelSeat(
                id: "adversary", name: "Adversary", role: "what breaks it", why: signal.why,
                brief: "You hunt the inputs and orders that break it: odd characters, duplicates, empty, huge, concurrent."
            )]
        case .service:
            [PanelSeat(
                id: "operator", name: "Operator", role: "runs it at 3 am", why: signal.why,
                brief: "You run this in production: rollout, rollback, what it logs, what pages someone, what it costs."
            )]
        case .ui:
            [PanelSeat(
                id: "accessibility", name: "Accessibility", role: "keyboard, contrast, screen readers",
                why: signal.why,
                brief: "You use it by keyboard and screen reader: focus order, labels, contrast, nothing only in colour."
            )]
        case .authNet:
            [PanelSeat(
                id: "security", name: "Security", role: "who can abuse it", why: signal.why,
                brief: "You ask who can abuse it: secrets, tokens, permissions, input from the network, what leaks."
            )]
        case .hotPath:
            [PanelSeat(
                id: "performance", name: "Performance", role: "what it costs per call", why: signal.why,
                brief: "You measure: what it costs on the hot path, what grows with input, what needs a benchmark."
            )]
        }
    }

    /// The signals in a plan's text (and the repos' names).
    public static func signals(in text: String) -> Set<Signal> {
        let lowered = " " + text.lowercased().map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " } + " "
        let words = Set(lowered.split(separator: " ").map(String.init))
        var found: Set<Signal> = []
        for signal in Signal.allCases {
            for word in signal.words {
                if word.hasSuffix("*") {
                    let prefix = String(word.dropLast())
                    if words.contains(where: { $0.hasPrefix(prefix) }) { found.insert(signal) }
                } else if word.contains(" ") {
                    if lowered.contains(" \(word) ") { found.insert(signal) }
                } else if words.contains(word) {
                    found.insert(signal)
                }
                if found.contains(signal) { break }
            }
        }
        return found
    }

    /// The panel: the four who always sit, then each signal's in a fixed order, then your team's style when heed has
    /// learned one (a library persona). No one sits twice.
    public static func invite(signals: Set<Signal>, teamStyle: Persona? = nil) -> [PanelSeat] {
        var panel = [skeptic, purist, scopeKeeper, ux]
        for signal in Signal.allCases where signals.contains(signal) {
            for seat in seats(for: signal) where !panel.contains(where: { $0.id == seat.id }) {
                panel.append(seat)
            }
        }
        if let teamStyle, !panel.contains(where: { $0.id == teamStyle.id }) {
            panel.append(PanelSeat.from(teamStyle, why: "your team's style"))
        }
        return panel
    }

    /// The panel for a plan.
    public static func invite(plan: WizardPlan, statement: String, repos: [String], teamStyle: Persona? = nil)
        -> [PanelSeat]
    {
        let text = ([statement, PlanTalk.render(plan)] + repos).joined(separator: "\n")
        return invite(signals: signals(in: text), teamStyle: teamStyle)
    }

    /// The library persona that is your team's style, if heed has one: named "team style", "our style" or "house
    /// style".
    public static func teamStyle(in library: [Persona]) -> Persona? {
        library.first { persona in
            let name = persona.name.lowercased()
            return name.contains("team style") || name.contains("our style") || name.contains("house style")
        }
    }

    /// Persona seats the `+` picker offers: the library's, and the built-in seats not on the panel yet.
    public static func candidates(library: [Persona], seated: [PanelSeat]) -> [PanelSeat] {
        let builtIn = [skeptic, purist, scopeKeeper, ux] + Signal.allCases.flatMap { seats(for: $0) }
        let all = builtIn.map { seat in
            var seat = seat
            seat.why = "you invited"
            return seat
        } + library.map { PanelSeat.from($0) }
        var seen = Set(seated.map(\.id))
        return all.filter { seen.insert($0.id).inserted }
    }
}

/// A persona's read of the plan.
public struct PanelVerdict: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case happy, concern, not

        /// A model's word for a verdict, read leniently.
        public init?(word: String) {
            switch word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            case "happy", "ok", "okay", "yes", "approve", "approved", "good", "fine", "lgtm": self = .happy
            case "concern", "concerned", "?", "question", "worried", "unsure", "maybe", "caution": self = .concern
            case "not", "no", "against", "block", "blocked", "reject", "don't", "dont", "stop", "veto": self = .not
            default: return nil
            }
        }
    }

    public var seat: String
    public var kind: Kind
    public var quote: String
    /// What it would change, short ("go smaller: link checker only"); nil when it would change nothing.
    public var fix: String?

    public init(seat: String, kind: Kind, quote: String, fix: String? = nil) {
        self.seat = seat
        self.kind = kind
        self.quote = quote
        self.fix = fix
    }

    /// The panel's answer: `{"verdicts": [{"persona": "skeptic", "verdict": "not", "quote": "...", "fix": "..."}]}`.
    /// Personas are matched by id or name; one not on the panel, or a verdict heed cannot read, is left out.
    public static func parse(_ text: String, seats: [PanelSeat]) -> [PanelVerdict] {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let rows = (object["verdicts"] ?? object["panel"]) as? [[String: Any]] ?? []
        var result: [PanelVerdict] = []
        for row in rows {
            let who = ((row["persona"] ?? row["id"] ?? row["name"]) as? String ?? "").lowercased()
            guard let seat = seats.first(where: {
                $0.id == who || $0.name.lowercased() == who || $0.id == Persona.slug(who)
            }),
                !result.contains(where: { $0.seat == seat.id }),
                let kind = Kind(word: (row["verdict"] ?? row["kind"]) as? String ?? "")
            else { continue }
            let quote = GoalDoc.oneLine(row["quote"] as? String ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            let fix = (row["fix"] as? String).map(GoalDoc.oneLine).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            result.append(PanelVerdict(seat: seat.id, kind: kind, quote: quote, fix: fix))
        }
        // In the panel's order.
        return seats.compactMap { seat in result.first { $0.seat == seat.id } }
    }
}

/// Step 2: who sits, each round's verdicts, and what you decided.
public struct PanelState: Hashable, Sendable, Codable {
    /// What you decided after the last round.
    public enum Decision: String, Hashable, Sendable, Codable {
        /// Worth it: the fixes taken (or none left), on to Done looks like.
        case worthIt
        /// Don't do it: the goal archived.
        case drop
    }

    /// What "Worth it, take the fixes" does now.
    public enum Next: Equatable, Sendable {
        /// Apply these fixes to the plan, and the panel reads it again.
        case reread([String])
        /// On to step 3.
        case advance
    }

    public var seats: [PanelSeat]
    public var rounds: [[PanelVerdict]]
    public var decision: Decision?
    /// What the Skeptic said, overruled by "worth it", for the TL;DR.
    public var overruled: String?

    public init(seats: [PanelSeat] = [], rounds: [[PanelVerdict]] = [], decision: Decision? = nil) {
        self.seats = seats
        self.rounds = rounds
        self.decision = decision
    }

    public static let maxRounds = 3

    public var latest: [PanelVerdict] { rounds.last ?? [] }

    public func verdict(of seat: String) -> PanelVerdict? { latest.first { $0.seat == seat } }

    public func count(_ kind: PanelVerdict.Kind) -> Int { latest.count { $0.kind == kind } }

    /// The fixes the latest round asked for, in the panel's order.
    public var fixes: [String] { latest.compactMap(\.fix) }

    /// Another round may run.
    public var canReread: Bool { rounds.count < Self.maxRounds }

    /// "Worth it, take the fixes": while fixes are asked for and rounds are left, they go into the plan and the panel
    /// reads again; otherwise on to step 3.
    public var next: Next {
        let fixes = fixes
        return !fixes.isEmpty && canReread ? .reread(fixes) : .advance
    }

    /// Everyone happy, or no rounds left: nothing more the panel can do.
    public var settled: Bool {
        !latest.isEmpty && (latest.allSatisfy { $0.kind == .happy } || !canReread)
    }
}

/// "Talk to one": a short chat with one persona about the plan.
public struct PersonaChat: Hashable, Sendable, Codable {
    public struct Line: Hashable, Sendable, Codable {
        public var fromYou: Bool
        public var text: String

        public init(fromYou: Bool, text: String) {
            self.fromYou = fromYou
            self.text = text
        }
    }

    public var seat: PanelSeat
    public var lines: [Line]

    public init(seat: PanelSeat, lines: [Line] = []) {
        self.seat = seat
        self.lines = lines
    }

    /// The chat so far, for the persona's next reply.
    public var transcript: String {
        lines.map { ($0.fromYou ? "Developer: " : "\(seat.name): ") + $0.text }.joined(separator: "\n")
    }
}
