import Foundation

/// A searchable list of values with counts, one or many of which are ticked: the value picker of the add-filter
/// popover and the org view's. Pure: it takes strokes and says what happened.
public struct BrowsePicker: Equatable, Sendable {
    public struct Option: Hashable, Sendable {
        /// What the token carries.
        public var value: String
        /// What the row says (the value, or a phrase like "no activity in 30 days").
        public var label: String
        public var count: Int?

        public init(_ value: String, label: String? = nil, count: Int? = nil) {
            self.value = value
            self.label = label ?? value
            self.count = count
        }
    }

    public enum Action: Equatable, Sendable { case none, changed, done, cancel }

    public var options: [Option]
    public var multiple: Bool
    public var input = EditableText()
    public private(set) var cursor = 0
    /// What is ticked, in the order it was ticked.
    public private(set) var selected: [String]

    public init(options: [Option], multiple: Bool, selected: [String] = []) {
        self.options = options
        self.multiple = multiple
        self.selected = selected
    }

    public var visible: [Option] {
        let words = input.text.lowercased().split(separator: " ").map(String.init)
        return words.isEmpty ? options : options.filter { option in
            words.allSatisfy { option.label.lowercased().contains($0) || option.value.lowercased().contains($0) }
        }
    }

    public var highlighted: Option? { visible[safe: cursor] }

    public mutating func toggle(_ value: String) {
        if let index = selected.firstIndex(of: value) {
            selected.remove(at: index)
        } else if multiple {
            selected.append(value)
        } else {
            selected = [value]
        }
    }

    public mutating func handle(_ stroke: KeyStroke) -> Action {
        let count = visible.count
        switch stroke {
        case .escape: return .cancel
        case KeyStroke("CR"):
            // Enter on a picker with nothing ticked ticks the row under the cursor, then is done; a single choice
            // is the row under the cursor.
            if let option = highlighted, selected.isEmpty || !multiple { selected = [option.value] }
            return .done
        case KeyStroke("Space"):
            // Space ticks the row. A search is one word, since a space ticks.
            if let option = highlighted { toggle(option.value) }
            return .changed
        case KeyStroke("Down"), KeyStroke("n", .control), KeyStroke("j", .control):
            cursor = count == 0 ? 0 : min(cursor + 1, count - 1)
        case KeyStroke("Up"), KeyStroke("p", .control), KeyStroke("k", .control):
            cursor = max(cursor - 1, 0)
        default:
            let before = input.text
            guard input.handle(stroke) else { return .none }
            if input.text != before { cursor = 0 }
            return .changed
        }
        return .none
    }
}
