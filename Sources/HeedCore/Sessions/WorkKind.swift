import Foundation

/// What a piece of work is: picked in Start work, shown on the session, kept in the ledger. Its branch prefix comes
/// from `[worktrees.prefixes]`, so a kind and a prefix are two names for one choice: `feat` makes `feature/…`, and
/// a prompt whose first word picks `bump/` is a `chore`.
public enum WorkKind: String, Codable, CaseIterable, Hashable, Sendable {
    case feat, fix, refactor, docs, chore, plan

    /// The prefixes this kind is, the one its branches get first.
    public var prefixNames: [String] {
        switch self {
        case .feat: ["feature", "feat"]
        case .fix: ["fix", "bugfix", "hotfix"]
        case .refactor: ["refactor", "perf"]
        case .docs: ["docs", "doc"]
        case .chore: ["chore", "bump", "test", "ci", "build"]
        case .plan: ["plan", "spike"]
        }
    }

    /// The kind a branch prefix stands for; nil for one heed does not know (a prefix of your own).
    public init?(prefix: String) {
        let prefix = prefix.lowercased()
        guard let kind = Self.allCases.first(where: { $0.prefixNames.contains(prefix) }) else { return nil }
        self = kind
    }

    /// The branch prefix for this kind: the first of its names that is configured, else its own first name.
    public func prefix(in prefixes: BranchPrefixes) -> String {
        let configured = Set(prefixes.prefixes.keys)
            .union(prefixes.defaultPrefix.isEmpty ? [] : [prefixes.defaultPrefix])
        return prefixNames.first(where: configured.contains) ?? prefixNames[0]
    }

    /// The kind a prompt reads as: its first word's prefix (`fix the …`, `bump …`), else what the default prefix is,
    /// else a feature.
    public static func guess(for prompt: String, prefixes: BranchPrefixes) -> WorkKind {
        if let prefix = StartWork.keywordPrefix(for: prompt, prefixes: prefixes), let kind = WorkKind(prefix: prefix) {
            return kind
        }
        return WorkKind(prefix: prefixes.defaultPrefix) ?? .feat
    }
}
