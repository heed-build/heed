import Foundation

public extension GoalFiles {
    /// `<goal>/personas/`.
    func personas(_ goal: String) -> URL { folder(goal).appendingPathComponent("personas", isDirectory: true) }

    /// `<goal>/personas/<id>.md`.
    func persona(_ id: String, goal: String) -> URL { personas(goal).appendingPathComponent("\(id).md") }

    /// The shared library beside the goals: `Application Support/Heed/personas/`.
    var library: URL { root.deletingLastPathComponent().appendingPathComponent("personas", isDirectory: true) }

    /// `personas/<id>.md` in the library.
    func libraryPersona(_ id: String) -> URL { library.appendingPathComponent("\(id).md") }
}

/// Why a persona operation did nothing.
public enum PersonaError: Error, Equatable, CustomStringConvertible {
    case noName
    case unknown(String)

    public var description: String {
        switch self {
        case .noName: "a persona file needs a name: line"
        case let .unknown(id): "no persona \(id)"
        }
    }
}

/// Personas: the derivations and spawns in the goal's record, and the files (the goal's and the library's). Files are
/// read and written here only; with `files.writes` off (fixtures, shots, the tutor) they live in memory.
public extension GoalOps {
    /// A goal's personas as the record has them.
    func personaBoard(of goal: String) throws -> PersonaBoard {
        try PersonaBoard.fold(store.quality(of: goal))
    }

    /// Every goal's persona board, by goal id.
    func personaBoards() throws -> [String: PersonaBoard] {
        var result: [String: PersonaBoard] = [:]
        for goal in try store.goals() {
            result[goal.id] = try personaBoard(of: goal.id)
        }
        return result
    }

    /// A new derivation: recorded, and a file for each persona the goal has none of yet: the library's when it has
    /// one of that name (copied), else the model's draft. Files you have are never written over.
    func derived(_ derivation: PersonaDerivation, goal: String, now: Date) throws {
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        try store.addQuality(QualityRecord(goal: goal, at: now, entry: .personas(derivation)))
        let have = try personaTexts(goal: goal)
        for need in derivation.needs where have[need.id] == nil {
            let text = try libraryTexts()[need.id] ?? need.persona.render()
            try writePersona(text, id: need.id, goal: goal)
        }
    }

    /// A persona put to work on the goal.
    func personaSpawned(_ spawn: PersonaSpawn, goal: String, now: Date) throws {
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        try store.addQuality(QualityRecord(goal: goal, at: now, entry: .personaSpawn(spawn)))
    }

    /// The goal's persona files, by id (files that do not parse are left out).
    func personas(of goal: String) throws -> [String: Persona] {
        try personaTexts(goal: goal).compactMapValues(Persona.parse)
    }

    /// Every goal's persona files.
    func personaFiles() throws -> [String: [String: Persona]] {
        var result: [String: [String: Persona]] = [:]
        for goal in try store.goals() {
            result[goal.id] = try personas(of: goal.id)
        }
        return result
    }

    /// A persona file's text as it is on disk.
    func personaText(_ id: String, goal: String) throws -> String {
        guard let text = try personaTexts(goal: goal)[id] else { throw PersonaError.unknown(id) }
        return text
    }

    /// Saves your edit of a persona's file. A file that renames it moves to the new name's file.
    @discardableResult
    func savePersona(_ text: String, id: String, goal: String) throws -> Persona {
        guard let persona = Persona.parse(text) else { throw PersonaError.noName }
        let normalized = text.hasSuffix("\n") ? text : text + "\n"
        if persona.id != id { try removePersona(id, goal: goal) }
        try writePersona(normalized, id: persona.id, goal: goal)
        return persona
    }

    /// The library's personas, by id.
    func library() throws -> [String: Persona] { try libraryTexts().compactMapValues(Persona.parse) }

    /// Copies a goal's persona into the library, for other goals.
    func share(persona id: String, goal: String) throws {
        let text = try personaText(id, goal: goal)
        if files.writes {
            try FileManager.default.createDirectory(at: files.library, withIntermediateDirectories: true)
            try text.write(to: files.libraryPersona(id), atomically: true, encoding: .utf8)
        } else {
            memoryLibrary[id] = text
        }
    }

    /// Copies a library persona onto the goal (over the goal's file of that name, if any).
    @discardableResult
    func use(library id: String, goal: String) throws -> Persona {
        guard let text = try libraryTexts()[id], let persona = Persona.parse(text) else {
            throw PersonaError.unknown(id)
        }
        try writePersona(text, id: id, goal: goal)
        return persona
    }

    // MARK: Files

    private func personaTexts(goal: String) throws -> [String: String] {
        guard files.writes else { return memoryPersonas[goal] ?? [:] }
        return Self.texts(in: files.personas(goal))
    }

    private func libraryTexts() throws -> [String: String] {
        guard files.writes else { return memoryLibrary }
        return Self.texts(in: files.library)
    }

    private static func texts(in folder: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [String: String] = [:]
        for name in names where name.hasSuffix(".md") {
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result[String(name.dropLast(3))] = text
        }
        return result
    }

    private func writePersona(_ text: String, id: String, goal: String) throws {
        guard files.writes else {
            memoryPersonas[goal, default: [:]][id] = text
            return
        }
        try FileManager.default.createDirectory(at: files.personas(goal), withIntermediateDirectories: true)
        try text.write(to: files.persona(id, goal: goal), atomically: true, encoding: .utf8)
    }

    private func removePersona(_ id: String, goal: String) throws {
        guard files.writes else {
            memoryPersonas[goal]?[id] = nil
            return
        }
        let url = files.persona(id, goal: goal)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Lays down fixture personas: their files, their derivations and spawns.
    func adopt(personas files: [String: [String: String]], records: [QualityRecord]) throws {
        for (goal, texts) in files {
            for (id, text) in texts {
                try writePersona(text, id: id, goal: goal)
            }
        }
        for record in records {
            try store.addQuality(record)
        }
    }
}
