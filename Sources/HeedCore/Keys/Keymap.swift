/// A mode's bindings from key sequences to command names, stored as a trie so prefixes (`g`, `<C-w>`, `'`) can wait
/// for the next key.
public struct Keymap: Sendable {
    public enum Lookup: Equatable, Sendable {
        /// The sequence is bound.
        case command(String)
        /// The sequence is the start of one or more bindings; wait for more keys.
        case prefix
        /// Nothing starts with this sequence.
        case none
    }

    private final class Node: @unchecked Sendable {
        var command: String?
        var children: [KeyStroke: Node] = [:]
    }

    private var root = Node()
    /// Bindings in insertion order, for the `?` overlay and conflict reports.
    public private(set) var bindings: [(keys: [KeyStroke], command: String)] = []

    public init() {}

    public enum BindError: Error, Equatable, CustomStringConvertible {
        /// `gg` cannot be bound while `g` is, or the other way round: one of them would never fire.
        case shadowed(keys: String, by: String)

        public var description: String {
            switch self {
            case let .shadowed(keys, other): "'\(keys)' conflicts with '\(other)': one of them could never fire"
            }
        }
    }

    /// Binds `keys` to `command`, replacing an existing binding of exactly the same keys.
    public mutating func bind(_ keys: [KeyStroke], to command: String) throws(BindError) {
        precondition(!keys.isEmpty)
        if !isKnownUniquelyReferenced(&root) { root = copy(root) }
        var node = root
        for (index, stroke) in keys.enumerated() {
            if node.command != nil {
                throw .shadowed(keys: KeyNotation.format(keys), by: KeyNotation.format(Array(keys[..<index])))
            }
            if let next = node.children[stroke] {
                node = next
            } else {
                let next = Node()
                node.children[stroke] = next
                node = next
            }
        }
        if !node.children.isEmpty {
            let longer = bindings.first { $0.keys.starts(with: keys) && $0.keys.count > keys.count }!
            throw .shadowed(keys: KeyNotation.format(keys), by: KeyNotation.format(longer.keys))
        }
        node.command = command
        bindings.removeAll { $0.keys == keys }
        bindings.append((keys, command))
    }

    /// Removes a binding (config can unbind a default with `"gs" = ""`).
    public mutating func unbind(_ keys: [KeyStroke]) {
        guard bindings.contains(where: { $0.keys == keys }) else { return }
        let remaining = bindings.filter { $0.keys != keys }
        self = Keymap()
        for binding in remaining {
            try? bind(binding.keys, to: binding.command)
        }
    }

    public func lookup(_ keys: [KeyStroke]) -> Lookup {
        var node = root
        for stroke in keys {
            guard let next = node.children[stroke] else { return .none }
            node = next
        }
        if let command = node.command { return .command(command) }
        return node.children.isEmpty ? .none : .prefix
    }

    /// Every binding that starts with `prefix` and goes further, as (rest of the keys, command): what can follow a
    /// pending `g` or `<C-w>`.
    public func continuations(of prefix: [KeyStroke]) -> [(rest: [KeyStroke], command: String)] {
        bindings.filter { $0.keys.count > prefix.count && $0.keys.starts(with: prefix) }
            .map { (Array($0.keys.dropFirst(prefix.count)), $0.command) }
    }

    public func keys(for command: String) -> [[KeyStroke]] {
        bindings.filter { $0.command == command }.map(\.keys)
    }

    private func copy(_ node: Node) -> Node {
        let clone = Node()
        clone.command = node.command
        clone.children = node.children.mapValues(copy)
        return clone
    }
}
