import Foundation

/// An expert a goal needs, as a plain file you can edit and share: `personas/<slug>.md` in the goal's folder, or in the
/// shared library (`Application Support/Heed/personas/`) for reuse across goals. One `key: value` line per section;
/// a value may go on over indented lines. Lists are comma separated; questions end at their `?`.
///
/// ```
/// name: Release engineer
/// knows: signed builds, notarization, update feeds
/// skeptical about: hand-made release notes, unsigned artifacts
/// asks first: what does a user download? who can publish it?
/// may: read, run, write notes
/// may not: edit code, publish
/// ```
///
/// Lines that are not a section are kept, in order, as `notes` below the sections.
///
/// A library persona (Settings › Personas) may say more, each line written only when it differs from the default so
/// a file without them reads as it always did:
///
/// ```
/// who: owns docs-website
/// about: Owns the site's build and hosting. Cares that public URLs never break.
/// scope: repo acme/docs-website
/// joins: goal panels, before a PR
/// source: repos
/// added: 2026-11-11
/// evidence:
/// - CODEOWNERS: @docs-infra owns /config, /redirects
/// ```
///
/// `on: no` turns it off; `sharpens: newcomer` makes it a built-in's sharper version within its scope.
public struct Persona: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var knows: [String]
    public var skepticalAbout: [String]
    public var asksFirst: [String]
    public var may: [String]
    public var mayNot: [String]
    /// Anything else in the file, kept as written.
    public var notes: String
    /// Who they are, in a few words ("argues not to do it", "owns docs-website").
    public var who: String
    /// Who they are, in a sentence or two.
    public var about: String
    /// Where it applies: everywhere, one org, one repo.
    public var scope: PersonaScope
    /// What it joins on its own.
    public var joins: Set<PersonaJoin>
    /// Where it came from.
    public var source: PersonaSource
    /// Why this persona: what in the repos pointed at it.
    public var evidence: [String]
    /// Off: in the library, but asked by nothing.
    public var on: Bool
    /// The day it joined the library.
    public var added: Date?
    /// The built-in it sharpens within its scope (`newcomer`): there it sits in the built-in's place.
    public var sharpens: String?

    public init(
        name: String, knows: [String] = [], skepticalAbout: [String] = [], asksFirst: [String] = [],
        may: [String] = Persona.readOnly, mayNot: [String] = Persona.noEdits, notes: String = "", who: String = "",
        about: String = "", scope: PersonaScope = .everywhere, joins: Set<PersonaJoin> = [],
        source: PersonaSource = .yours, evidence: [String] = [], on: Bool = true, added: Date? = nil,
        sharpens: String? = nil
    ) {
        self.name = name
        self.knows = knows
        self.skepticalAbout = skepticalAbout
        self.asksFirst = asksFirst
        self.may = may
        self.mayNot = mayNot
        self.notes = notes
        self.who = who
        self.about = about
        self.scope = scope
        self.joins = joins
        self.source = source
        self.evidence = evidence
        self.on = on
        self.added = added
        self.sharpens = sharpens
    }

    enum CodingKeys: String, CodingKey {
        case name, knows, skepticalAbout, asksFirst, may, mayNot, notes, who, about, scope, joins, source, evidence
        case on, added, sharpens
    }

    /// Records written before the library said more decode with its defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        knows = try container.decodeIfPresent([String].self, forKey: .knows) ?? []
        skepticalAbout = try container.decodeIfPresent([String].self, forKey: .skepticalAbout) ?? []
        asksFirst = try container.decodeIfPresent([String].self, forKey: .asksFirst) ?? []
        may = try container.decodeIfPresent([String].self, forKey: .may) ?? []
        mayNot = try container.decodeIfPresent([String].self, forKey: .mayNot) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        who = try container.decodeIfPresent(String.self, forKey: .who) ?? ""
        about = try container.decodeIfPresent(String.self, forKey: .about) ?? ""
        scope = try container.decodeIfPresent(PersonaScope.self, forKey: .scope) ?? .everywhere
        joins = try container.decodeIfPresent(Set<PersonaJoin>.self, forKey: .joins) ?? []
        source = try container.decodeIfPresent(PersonaSource.self, forKey: .source) ?? .yours
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        on = try container.decodeIfPresent(Bool.self, forKey: .on) ?? true
        added = try container.decodeIfPresent(Date.self, forKey: .added)
        sharpens = try container.decodeIfPresent(String.self, forKey: .sharpens)
    }

    /// What a persona may do unless its file says otherwise: it reads and runs, and never changes the work.
    public static let readOnly = ["read", "run", "write notes"]
    public static let noEdits = ["edit code"]

    /// Its file's name without `.md`: the name as a slug.
    public var id: String { Persona.slug(name) }

    public static func slug(_ name: String) -> String { GoalSlug.make(name, taken: []) }

    /// The file's sections, in the order they are written.
    enum Section: String, CaseIterable {
        case name
        case knows
        case skepticalAbout = "skeptical about"
        case asksFirst = "asks first"
        case may
        case mayNot = "may not"
        // The library's: written only when not the default.
        case who, about, scope, joins, source, evidence, on, added, sharpens
    }

    /// Reads a persona file leniently: keys in any case, `skeptical_about` or `skeptical-about`, `- ` list lines under
    /// a key. Nil when it has no name.
    public static func parse(_ text: String) -> Persona? {
        var values: [Section: String] = [:]
        var lists: [Section: [String]] = [:]
        var notes: [String] = []
        var current: Section?
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let (section, value) = Self.keyed(trimmed), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                current = section
                values[section] = (values[section].map { $0 + " " } ?? "") + value
                continue
            }
            if let section = current, !trimmed.isEmpty, line.first?.isWhitespace == true || trimmed.hasPrefix("- ") {
                if trimmed.hasPrefix("- ") {
                    lists[section, default: []]
                        .append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                } else {
                    values[section] = (values[section].map { $0 + " " } ?? "") + trimmed
                }
                continue
            }
            current = nil
            notes.append(line)
        }
        let name = GoalDoc.oneLine(values[.name] ?? "")
        guard !name.isEmpty else { return nil }
        func list(_ section: Section) -> [String] {
            let inline: [String] = values[section].map { value -> [String] in
                switch section {
                case .asksFirst: questions(value)
                // Evidence reads like sentences, commas and all: `;` parts it on one line.
                case .evidence: value.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                default: items(value)
                }
            } ?? []
            return inline + (lists[section] ?? []).filter { !$0.isEmpty }
        }
        func line(_ section: Section) -> String { GoalDoc.oneLine(values[section] ?? "") }
        // Blank lines around the notes say nothing.
        while notes.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            notes.removeFirst()
        }
        while notes.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            notes.removeLast()
        }
        return Persona(
            name: name, knows: list(.knows), skepticalAbout: list(.skepticalAbout), asksFirst: list(.asksFirst),
            may: list(.may), mayNot: list(.mayNot), notes: notes.joined(separator: "\n"), who: line(.who),
            about: line(.about), scope: PersonaScope(text: line(.scope)) ?? .everywhere,
            joins: Set(list(.joins).compactMap(PersonaJoin.init(text:))),
            source: PersonaSource(text: line(.source)) ?? .yours, evidence: list(.evidence),
            on: !["no", "off", "false"].contains(line(.on).lowercased()), added: Self.day(line(.added)),
            sharpens: line(.sharpens).isEmpty ? nil : Persona.slug(line(.sharpens))
        )
    }

    /// `2026-11-11`.
    static func day(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The file: one line per section (none left out, so the file shows what can be said), then the notes.
    public func render() -> String {
        var lines = [
            "name: \(name)",
            "knows: \(knows.joined(separator: ", "))",
            "skeptical about: \(skepticalAbout.joined(separator: ", "))",
            "asks first: \(asksFirst.joined(separator: " "))",
            "may: \(may.joined(separator: ", "))",
            "may not: \(mayNot.joined(separator: ", "))",
        ]
        .map { $0.hasSuffix(": ") ? String($0.dropLast()) : $0 }
        lines += libraryLines
        if !notes.isEmpty { lines += ["", notes] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The library's lines, each only when it is not the default: an older file renders as it was.
    private var libraryLines: [String] {
        var lines: [String] = []
        if !who.isEmpty { lines.append("who: \(who)") }
        if !about.isEmpty { lines.append("about: \(about)") }
        if scope != .everywhere { lines.append("scope: \(scope.text)") }
        if !joins.isEmpty {
            lines.append("joins: " + PersonaJoin.allCases.filter(joins.contains).map(\.text).joined(separator: ", "))
        }
        if source != .yours { lines.append("source: \(source.text)") }
        if !on { lines.append("on: no") }
        if let added { lines.append("added: \(Self.dayText(added))") }
        if let sharpens { lines.append("sharpens: \(sharpens)") }
        if !evidence.isEmpty { lines += ["evidence:"] + evidence.map { "- \($0)" } }
        return lines
    }

    /// What an agent is told to be: the persona in sentences, for a reviewer's instructions or a chat's first message.
    public var brief: String {
        var lines = ["You are \(name)" + (who.isEmpty ? "." : ": \(who).")]
        if !about.isEmpty { lines.append(about) }
        if !knows.isEmpty { lines.append("You know \(knows.joined(separator: ", ")).") }
        if !skepticalAbout
            .isEmpty { lines.append("You are skeptical about \(skepticalAbout.joined(separator: ", ")).") }
        if !asksFirst.isEmpty { lines.append("You ask first: \(asksFirst.joined(separator: " "))") }
        if !may.isEmpty { lines.append("You may \(may.joined(separator: ", ")).") }
        if !mayNot.isEmpty { lines.append("You may not \(mayNot.joined(separator: ", ")).") }
        if !notes.isEmpty { lines += ["", notes] }
        return lines.joined(separator: "\n")
    }

    static func keyed(_ line: String) -> (Section, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard let section = Section(rawValue: key) else { return nil }
        return (section, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// `a, b, c` → three; empty parts dropped.
    static func items(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `what is the key? who clears it?` → two questions; a last part without `?` is one too.
    static func questions(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "?" {
                let question = current.trimmingCharacters(in: .whitespaces)
                if question.count > 1 { result.append(question) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}
