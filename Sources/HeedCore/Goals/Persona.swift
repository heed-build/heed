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
public struct Persona: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var knows: [String]
    public var skepticalAbout: [String]
    public var asksFirst: [String]
    public var may: [String]
    public var mayNot: [String]
    /// Anything else in the file, kept as written.
    public var notes: String

    public init(
        name: String, knows: [String] = [], skepticalAbout: [String] = [], asksFirst: [String] = [],
        may: [String] = Persona.readOnly, mayNot: [String] = Persona.noEdits, notes: String = ""
    ) {
        self.name = name
        self.knows = knows
        self.skepticalAbout = skepticalAbout
        self.asksFirst = asksFirst
        self.may = may
        self.mayNot = mayNot
        self.notes = notes
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
            let inline = values[section].map { section == .asksFirst ? questions($0) : items($0) } ?? []
            return inline + (lists[section] ?? []).filter { !$0.isEmpty }
        }
        // Blank lines around the notes say nothing.
        while notes.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            notes.removeFirst()
        }
        while notes.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            notes.removeLast()
        }
        return Persona(
            name: name, knows: list(.knows), skepticalAbout: list(.skepticalAbout), asksFirst: list(.asksFirst),
            may: list(.may), mayNot: list(.mayNot), notes: notes.joined(separator: "\n")
        )
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
        if !notes.isEmpty { lines += ["", notes] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What an agent is told to be: the persona in sentences, for a reviewer's instructions or a chat's first message.
    public var brief: String {
        var lines = ["You are \(name)."]
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
