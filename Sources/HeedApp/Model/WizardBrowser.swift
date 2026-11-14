import Foundation
import HeedCore
import Observation

/// The new-goal wizard's state in the Goals view: every goal's walk (`GoalWizard`, from `goals.sqlite`), the goal whose
/// wizard shows, the cursors of its steps, what is being typed, what is running, and the TL;DR. The domain is
/// `GoalWizard`; this holds only what the screen needs beside it. `AppModel+GoalWizard` acts on it.
@MainActor
@Observable
final class WizardBrowser {
    /// What is being typed, while it is.
    struct Typing: Equatable {
        enum Kind: Equatable {
            /// An answer to heed's question (Plan).
            case answer
            /// A message to the persona you talk to (Panel).
            case chat
            /// Why not (Panel's Don't do it).
            case dropReason
        }

        var kind: Kind
        var text = ""
    }

    /// Each goal's wizard, by goal id.
    private(set) var wizards: [String: GoalWizard] = [:]
    /// The goal whose wizard shows; nil: Goals as it is.
    var open: String?
    /// The persona (Panel) or criterion (Done looks like) under the cursor.
    var row = 0
    /// The replacement highlighted for the criterion under the cursor (0-based).
    var pick = 0
    var typing: Typing?
    /// Talking to one persona.
    var chat: PersonaChat?
    /// The `+` picker: the personas it offers and its cursor.
    var inviting: [PanelSeat]?
    var inviteRow = 0
    /// What runs now, by goal ("heed is thinking", "the panel reads the plan").
    var busy: [String: String] = [:]
    /// The last thing that went wrong, by goal.
    var problem: [String: String] = [:]
    /// The goal whose TL;DR shows.
    var tldr: String?
    /// TL;DRs of goals that never went through the wizard, by goal (not kept across launches).
    var looseTLDRs: [String: WizardTLDR] = [:]
    /// The TL;DR being written now, by goal.
    var writing: Set<String> = []

    /// The wizard that shows.
    var current: GoalWizard? { open.flatMap { wizards[$0] } }

    func wizard(of goal: String) -> GoalWizard? { wizards[goal] }

    /// A goal with a wizard not finished: `goal.open` resumes it.
    func unfinished(_ goal: String) -> Bool { wizards[goal].map { !$0.finished } ?? false }

    func set(_ wizard: GoalWizard) {
        if wizards[wizard.goal] != wizard { wizards[wizard.goal] = wizard }
    }

    func replace(all fresh: [String: GoalWizard]) {
        if fresh != wizards { wizards = fresh }
    }

    /// The key scope while the wizard or the TL;DR shows; nil otherwise.
    var scope: String? {
        if tldr != nil { return "tldr" }
        guard let wizard = current else { return nil }
        if inviting != nil { return "wizardinvite" }
        if chat != nil { return "wizardchat" }
        return switch wizard.step {
        case .plan: "wizardplan"
        case .panel: "wizardpanel"
        case .done: "wizarddone"
        case .split, .careful, .go: "wizardlater"
        }
    }

    /// How many rows j and k move through on the step that shows.
    var rowCount: Int {
        if let inviting { return inviting.count }
        guard let wizard = current else { return 0 }
        return switch wizard.step {
        case .panel: wizard.panel.seats.count
        case .done: wizard.criteria.criteria.count
        default: 0
        }
    }

    func moveRow(_ delta: Int) {
        if inviting != nil {
            inviteRow = min(max(inviteRow + delta, 0), max(rowCount - 1, 0))
            return
        }
        let next = min(max(row + delta, 0), max(rowCount - 1, 0))
        if next != row {
            row = next
            pick = 0
        }
    }

    /// The cursors back to the top, as a step shows.
    func resetCursors() {
        row = 0
        pick = 0
        chat = nil
        inviting = nil
        typing = nil
    }
}
