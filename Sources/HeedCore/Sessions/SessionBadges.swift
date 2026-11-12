import Foundation

/// How big a piece of work is, from the lines and files it changed against its base: small under 100 lines, large
/// past 800 lines or 20 files, medium between. Nothing changed yet is no size at all.
public enum WorkSize: String, Codable, Hashable, Sendable, CaseIterable {
    case small, medium, large

    public static func of(lines: Int?, files: Int?) -> WorkSize? {
        guard let lines, lines > 0 else { return nil }
        if lines > 800 || (files ?? 0) > 20 { return .large }
        return lines < 100 ? .small : .medium
    }

    /// How many of the three bars are lit.
    public var bars: Int {
        switch self {
        case .small: 1
        case .medium: 2
        case .large: 3
        }
    }

    public var letter: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }
}

public enum SessionBadges {
    /// What a session's work is: the kind it was given (Start work, you, or heed's name for it), else what its first
    /// PR's title says in conventional-commit style (`fix(nav): …`), else its branch's prefix.
    public static func kind(of session: Session, pullTitles: [String] = []) -> WorkKind? {
        guard !session.isChat else { return nil }
        if let kind = session.kind { return kind }
        if let kind = pullTitles.lazy.compactMap(conventionalKind).first { return kind }
        let prefix = session.branch.split(separator: "/").first.map(String.init)
        return session.branch.contains("/") ? prefix.flatMap(WorkKind.init(prefix:)) : nil
    }

    /// The kind a conventional commit title gives: `feat:`, `fix(scope):`, `docs!:`; perf reads as refactor, test,
    /// build and ci as chore.
    public static func conventionalKind(_ title: String) -> WorkKind? {
        guard let colon = title.firstIndex(of: ":") else { return nil }
        var head = String(title[..<colon]).lowercased()
        if head.hasSuffix("!") { head.removeLast() }
        if let paren = head.firstIndex(of: "(") { head = String(head[..<paren]) }
        guard !head.isEmpty, head.allSatisfy(\.isLetter) else { return nil }
        return WorkKind(rawValue: head) ?? WorkKind(prefix: head)
    }

    /// The kind after `kind`, for `session.kind` (wrapping).
    public static func next(after kind: WorkKind?) -> WorkKind {
        let all = WorkKind.allCases
        guard let kind, let index = all.firstIndex(of: kind) else { return all[0] }
        return all[(index + 1) % all.count]
    }
}
