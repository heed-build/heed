import Foundation

/// What a form says about one of its fields, drawn next to that field (`FieldNoteView` in the app), never in the status
/// bar: a problem that stops the form's ⌘↩, a check still running (which stops it too), or a word that the value is
/// fine. A form's validator returns these, each naming its field, so the form can put it in the right place.
public struct FieldNote: Error, Equatable, Hashable, Sendable {
    public enum Tone: String, Sendable {
        /// Wrong as it is: ⌘↩ waits until it is fixed.
        case problem
        /// Being checked (gh, a path on disk): ⌘↩ waits for the answer.
        case checking
        /// Fine, and why: shown quietly.
        case fine
    }

    /// The field it is about, as the form names its fields (`title`, `repos`, `where`, ...).
    public var field: String
    public var text: String
    public var tone: Tone
    /// Something missing rather than wrong (an empty title): shown once ⌘↩ was tried, so a form does not open in red.
    /// It still stops ⌘↩, and the confirm button's tooltip says why from the start.
    public var untilTried: Bool

    public init(_ field: String, _ text: String, tone: Tone = .problem, untilTried: Bool = false) {
        self.field = field
        self.text = text
        self.tone = tone
        self.untilTried = untilTried
    }

    /// It stops the form from being submitted.
    public var blocks: Bool { tone != .fine }
}

public extension [FieldNote] {
    /// The note for a field: its problem first, then a check running, then a fine word.
    /// Only `tried` shows what is missing.
    func note(for field: String, tried: Bool = true) -> FieldNote? {
        let mine = filter { $0.field == field && (tried || !$0.untilTried) }
        return mine.first { $0.tone == .problem } ?? mine.first { $0.tone == .checking } ?? mine.first
    }

    /// Why the form's ⌘↩ does nothing yet, for the confirm button's tooltip: the first blocking note; nil when it may
    /// go.
    var blocking: FieldNote? { first { $0.tone == .problem } ?? first { $0.tone == .checking } }
}

/// The validators of the forms that do not have a model of their own in HeedCore. Each returns field-scoped notes;
/// the app draws them under their fields and disables ⌘↩ while any blocks.
public enum FormChecks {
    /// The new goal dialog (`goal.new`): a title, and a tracker that is `org/name` when one is typed.
    public static func goal(title: String, tracker: String) -> [FieldNote] {
        var notes: [FieldNote] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append(FieldNote("title", "a goal needs a title", untilTried: true))
        }
        let typed = tracker.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, TrackerCheck.slug(typed) == nil {
            notes.append(FieldNote("tracker", "\(typed) is not org/name: clear it for no tracker"))
        }
        return notes
    }

    /// The new swarm form (`swarm.new`, `swarm.start`, or a goal started as a swarm). `newGoal`: it makes its goal,
    /// so it needs a title. `repos`: what is picked; `needsRepo`: the lead needs one to start in (not in the fake
    /// world). `entry`: the note on what is typed in the repo field, which must be settled before ⌘↩ (a typed repo is
    /// added on ⌘↩ when it is fine). `place`: why the swarm cannot run where it is set to.
    public static func swarm(
        newGoal: Bool, title: String, repos: [String], needsRepo: Bool, entry: FieldNote?, place: String?
    ) -> [FieldNote] {
        var notes: [FieldNote] = []
        if newGoal, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append(FieldNote("title", "a swarm's goal needs a title", untilTried: true))
        }
        if let entry {
            notes.append(entry)
        } else if repos.isEmpty, needsRepo {
            notes.append(FieldNote(
                "repos", "pick a repo for the lead to start in: one above, or type owner/name or a path",
                untilTried: true
            ))
        }
        if let place { notes.append(FieldNote("where", "the swarm cannot run there: \(place)")) }
        return notes
    }

    /// The plan pane's text editors: feedback for a re-plan, an answer to the lead.
    public static func steering(_ text: String, answer: Bool) -> [FieldNote] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [FieldNote("text", answer ? "type the answer" : "say what the lead should change", untilTried: true)]
    }
}
