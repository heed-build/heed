import Foundation
import HeedCore
import Observation

/// Settings › Personas: the filter, the cursor, the file being edited, trials on PRs, and the two sheets over the page:
/// Add a persona (repos, reads, proposals) and defining the picked with an agent. The library itself is the files in
/// `GoalsBrowser.personas.library`, merged with the built-ins (`PersonaLibrary`); this holds no copy of it.
@MainActor
@Observable
final class PersonaLibraryBrowser {
    /// Add a persona, while open.
    struct Adding: Equatable {
        /// The repos heed can read, and the ones picked.
        var repos: [String]
        var looking: Set<String>
        var done: Set<PersonaDigest.Step> = []
        var reading = false
        var digest: PersonaDigest?
        var proposals: [PersonaProposal] = []
        var picked: Set<String> = []
        var cursor = 0
        /// The describe-one field, while it has the keyboard.
        var describing: String?
        var cost: PersonaCalls.Cost?
        var problem: String?

        var pickedProposals: [PersonaProposal] { proposals.filter { picked.contains($0.id) } }

        /// The first proposal that overlaps a library persona, for the callout.
        var overlapping: PersonaProposal? { proposals.first { $0.overlaps != nil } }
    }

    var filter: PersonaSource?
    /// The page shows when personas look at sessions (Settings › Personas › In sessions), and the milestone under
    /// its cursor.
    var inSessions = false
    var signal = 0
    private(set) var cursor = 0
    /// The persona file under the cursor, as it is being edited, while it is.
    var draft: String?
    var drafting: String?
    /// Each persona's last trial on a PR, by id; the ones trying now.
    var trials: [String: PersonaTrial] = [:]
    var tried: [String: Set<Int>] = [:]
    var trying: Set<String> = []
    var adding: Adding?
    /// The picked being defined, in order, and which shows.
    var defining: [PersonaDefinition] = []
    var defineIndex = 0
    /// The answer field, while it has the keyboard.
    var answering: String?
    /// Verdict history drawn instead of the wizards' (the fake world's).
    var fixtureVerdicts: [String: [PanelVerdict.Kind]]?
    /// The conversation with the agent defining the persona that shows (one at a time).
    @ObservationIgnored var defineConversation: AgentConversation?

    /// The key scope the Settings window reads: the sheet on top, else the list.
    var scope: String {
        if !defining.isEmpty { return "personadefine" }
        if adding != nil { return "personaadd" }
        if inSessions { return "personasessions" }
        return "personas"
    }

    var current: PersonaDefinition? { defining.indices.contains(defineIndex) ? defining[defineIndex] : nil }

    func editCurrent(_ change: (inout PersonaDefinition) -> Void) {
        guard defining.indices.contains(defineIndex) else { return }
        change(&defining[defineIndex])
    }

    func edit(id: String, _ change: (inout PersonaDefinition) -> Void) {
        guard let index = defining.firstIndex(where: { $0.id == id }) else { return }
        change(&defining[index])
    }

    func setCursor(_ index: Int, count: Int) {
        guard count > 0 else { return cursor = 0 }
        let clamped = min(max(index, 0), count - 1)
        if clamped != cursor { draft = nil }
        cursor = clamped
    }
}
