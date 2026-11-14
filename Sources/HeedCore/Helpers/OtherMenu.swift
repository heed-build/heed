import Foundation

/// What the proposal's **Other** (`.`) lists for an Attention item: the other steps heed could propose instead (and
/// heed's own again, once you moved off it), then what you can do with the item, each with its key. The reader has
/// no row of buttons beside the proposal: they are here, and their keys work as ever.
public enum OtherMenu {
    /// Something you can do with the item, by its command: `Done x`.
    public struct Action: Hashable, Sendable {
        public let command: String
        public let label: String
        /// The key scope its key is looked up in (nil: anywhere).
        public let scope: String?

        public init(_ command: String, _ label: String, scope: String? = "attention") {
            self.command = command
            self.label = label
            self.scope = scope
        }
    }

    public enum Entry: Hashable, Sendable {
        /// Propose this step instead.
        case step(NextStep)
        /// Back to heed's own step.
        case own(NextStep)
        case action(Action)

        public var label: String {
            switch self {
            case let .step(step): "Instead: \(step.title)"
            case let .own(step): "Back to heed's own: \(step.title)"
            case let .action(action): action.label
            }
        }
    }

    /// What you can do with an issue or PR, in the order the reader's buttons had: read or review it, reply, its
    /// session (or start one), done, snooze, mute (a notification only) and GitHub (when it has a URL).
    public static func actions(_ item: AttentionItem) -> [Action] {
        var actions = [
            Action("open.reader", item.kind == .pr ? "Review" : "Read"),
            Action("attention.reply", "Reply"),
            item.session != nil ? Action("attention.session", "Go to its session")
                : Action("items.start", "Start a session"),
            Action("attention.done", "Done"),
            Action("attention.snooze", "Snooze"),
        ]
        if item.notificationID != nil { actions.append(Action("attention.mute", "Mute")) }
        if item.url != nil { actions.append(Action("open.browser", "GitHub", scope: nil)) }
        return actions
    }

    /// The menu: heed's own step again when the proposal moved off it, the other steps (less the one proposed, and
    /// those an action does already: a reply is `R`, Start work `s`), then the actions.
    public static func entries(_ item: AttentionItem, own: NextStep?, proposed: NextStep?) -> [Entry] {
        let actions = actions(item)
        let commands = Set(actions.map(\.command))
        var entries: [Entry] = []
        if let own, proposed != own { entries.append(.own(own)) }
        entries += NextStep.others(item, proposed: own)
            .filter { $0 != proposed }
            .filter { step in
                switch step {
                case .draftReply: !commands.contains("attention.reply")
                case .startWork: !commands.contains("items.start")
                default: true
                }
            }
            .map(Entry.step)
        return entries + actions.map(Entry.action)
    }
}
