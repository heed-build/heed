import Foundation

/// Where an item lands under the rules: what "try before you save" counts moves between.
public enum AttentionLevel: String, CaseIterable, Hashable, Sendable, Comparable {
    case pinned, high, normal, low, hidden

    public init(_ action: AttentionAction) {
        self = switch true {
        case action.ignore: .hidden
        case action.pin: .pinned
        case action.boost > 0: .high
        case action.lower: .low
        default: .normal
        }
    }

    public static func < (lhs: AttentionLevel, rhs: AttentionLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What edited rules would have changed over the items of the last 30 days, against the rules in use.
public struct AttentionRulePreview: Hashable, Sendable {
    public struct Move: Hashable, Sendable {
        public var from: AttentionLevel
        public var to: AttentionLevel
        public var count: Int
    }

    /// Items whose level would change.
    public var changed: Int
    /// The changes, most first: `normal → low: 26`.
    public var moves: [Move]
    /// How many items each edited line would match (it being the first match), by line number.
    public var matches: [Int: Int]
    public var items: Int

    public static func of(
        saved: AttentionRules, edited: AttentionRules, items: [AttentionItem], viewer: String?, now: Date
    ) -> AttentionRulePreview {
        var moves: [[AttentionLevel]: Int] = [:]
        var matches: [Int: Int] = [:]
        for item in items {
            let before = AttentionLevel(saved.outcome(for: item, viewer: viewer, now: now).action)
            let outcome = edited.outcome(for: item, viewer: viewer, now: now)
            if let line = outcome.rule?.line { matches[line, default: 0] += 1 }
            let after = AttentionLevel(outcome.action)
            if before != after { moves[[before, after], default: 0] += 1 }
        }
        let sorted = moves.map { Move(from: $0.key[0], to: $0.key[1], count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : ($0.from, $0.to) < ($1.from, $1.to)
        }
        return AttentionRulePreview(
            changed: sorted.reduce(0) { $0 + $1.count }, moves: sorted, matches: matches, items: items.count
        )
    }
}

/// The rules as Settings edits them: lines that can be added, removed, moved and changed, as a list or as text,
/// before they are saved to config.toml.
public struct AttentionRuleDraft: Hashable, Sendable {
    public private(set) var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    /// The text form: one rule a line.
    public var text: String {
        get { lines.joined(separator: "\n") }
        set {
            var parsed = newValue.components(separatedBy: "\n")
            while parsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                parsed.removeLast()
            }
            lines = parsed
        }
    }

    public var rules: AttentionRules { AttentionRules(lines: lines) }

    /// The problem on a line (1-based), if it has one.
    public func problem(line: Int) -> String? { rules.problems.first { $0.line == line }?.message }

    public mutating func add(_ line: String, at index: Int? = nil) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        lines.insert(text, at: min(max(index ?? lines.count, 0), lines.count))
    }

    public mutating func remove(at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines.remove(at: index)
    }

    /// Moves a line up (`-1`) or down (`1`); order is what decides, first match wins.
    public mutating func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard lines.indices.contains(index), lines.indices.contains(target) else { return }
        lines.swapAt(index, target)
    }

    public mutating func edit(_ index: Int, to line: String) {
        guard lines.indices.contains(index) else { return }
        lines[index] = line
    }

    /// The lines as written to config.toml: blank lines dropped, each trimmed.
    public var saved: [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
