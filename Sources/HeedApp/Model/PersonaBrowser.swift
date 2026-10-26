import Foundation
import HeedCore
import Observation

/// Goals › Personas: each goal's persona board (derivations and spawns, from `goal_reviews`), the goal's persona files
/// and the shared library, the cursor, the file being edited and what the next spawn runs as. Read through `GoalOps`;
/// the rows are worked out in `GoalsBrowser.personaRows`, which knows the goal's items and reviewers.
@MainActor
@Observable
final class PersonaBrowser {
    /// What a persona spawned from the pane runs as.
    struct Spawn: Equatable {
        /// nil: `[goals] reviewer_agent` for a reviewer, else the goal's sessions' agent.
        var agent: String?
        /// The model a persona reviewer runs on.
        var tier = ModelTier.best
    }

    /// A persona started as a session or chat from the pane: the session it starts is recorded as the persona's.
    struct Starting: Equatable {
        var goal: String
        var persona: String
        var mode: PersonaSpawn.Mode
        /// Words of the prompt it was started with, to tell its session.
        var marker: String
    }

    private(set) var boards: [String: PersonaBoard] = [:]
    /// Each goal's persona files, by id.
    private(set) var files: [String: [String: Persona]] = [:]
    private(set) var library: [String: Persona] = [:]
    private(set) var cursor = 0
    /// The persona file under the cursor, as it is being edited, while it is.
    var draft: String?
    /// The persona whose file is being edited.
    @ObservationIgnored var drafting: String?
    var spawn = Spawn()
    /// Gaps heed suggests (not spawned on its own), by goal: an Attention item and the pane's hint.
    private(set) var suggested: [String: [String]] = [:]
    @ObservationIgnored var starting: Starting?
    /// Each goal's board signature and when it last moved, for the debounce (`PersonaDerivation.due`).
    @ObservationIgnored var seen: [String: (signature: String, at: Date)] = [:]
    /// Goals whose personas a model is working out now.
    @ObservationIgnored var deriving: Set<String> = []

    /// The fake world's personas (shots, the tutor), drawn before the in-memory store has them.
    func loadFixture(records: [QualityRecord], files: [String: [String: String]]) {
        var boards: [String: PersonaBoard] = [:]
        for goal in Set(records.map(\.goal)) {
            boards[goal] = PersonaBoard.fold(records.filter { $0.goal == goal })
        }
        self.boards = boards
        self.files = files.mapValues { $0.compactMapValues(Persona.parse) }
    }

    /// Reads the boards, the files and the library again; only what changed is written.
    func reload(_ ops: GoalOps) async {
        if let fresh = try? await ops.personaBoards(), fresh != boards { boards = fresh }
        if let fresh = try? await ops.personaFiles(), fresh != files { files = fresh }
        if let fresh = try? await ops.library(), fresh != library { library = fresh }
    }

    func setCursor(_ index: Int, count: Int) {
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        if clamped != cursor { draft = nil }
        cursor = clamped
    }

    func clamp(_ count: Int) {
        cursor = min(cursor, max(count - 1, 0))
    }

    func setSuggested(_ goal: String, _ ids: [String]) {
        let fresh = ids.isEmpty ? nil : ids
        if suggested[goal] != fresh { suggested[goal] = fresh }
    }
}
