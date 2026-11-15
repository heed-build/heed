import Foundation

/// Claude Code's allow rules in a project's `.claude/settings.local.json` (`permissions.allow`): read for the grants
/// heed lists, and one taken out when you revoke it.
public enum AlwaysRules {
    /// `<root>/.claude/settings.local.json`.
    public static func file(root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".claude/settings.local.json")
    }

    /// The rules in `file`, as written; none when it is missing or unreadable.
    public static func rules(in file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any]
        else { return [] }
        return (permissions["allow"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unreadable(String)

        public var description: String {
            switch self {
            case let .unreadable(path): "\(path) is not JSON heed can read; it is left as it is"
            }
        }
    }

    /// Takes `rule` out of `file`'s `permissions.allow`, leaving everything else as it was. False when it was not
    /// there (nothing is written). The write is atomic.
    @discardableResult
    public static func remove(_ rule: String, from file: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadable(file.path)
        }
        guard var permissions = json["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [Any],
              allow.contains(where: { $0 as? String == rule })
        else { return false }
        permissions["allow"] = allow.filter { $0 as? String != rule }
        json["permissions"] = permissions
        let out = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (out + Data("\n".utf8)).write(to: file, options: .atomic)
        return true
    }

    /// The rules already in the settings of `roots` (repos' main checkouts and worktrees heed knows), as grants made
    /// before Audit recorded any. One per file and rule; ids are stable, so the list reads the same each time.
    public static func beforeAudit(roots: [String], known: Set<String>) -> [AuditGrant] {
        var seen: Set<String> = []
        var grants: [AuditGrant] = []
        for root in roots {
            let file = file(root: root)
            let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            for rule in rules(in: file) {
                let grant = AuditGrant(
                    id: "before:" + file.path + ":" + rule, at: date ?? .distantPast, kind: .alwaysRule,
                    subject: rule, scope: file.path, why: "in settings.local.json before Audit", beforeAudit: true
                )
                guard !known.contains(grant.identity), seen.insert(grant.identity).inserted else { continue }
                grants.append(grant)
            }
        }
        return grants
    }
}

/// A repo's `trusted_reviewers` or `trusted_authors` without one login (compared as `HeedMerge.listed` does).
public enum TrustedLogins {
    public static func removing(_ login: String, from list: [String]) -> [String] {
        let wanted = normalize(login)
        return list.filter { normalize($0) != wanted }
    }

    static func normalize(_ login: String) -> String {
        var name = login.lowercased()
        if name.hasPrefix("@") { name.removeFirst() }
        if name.hasSuffix("[bot]") { name.removeLast(5) }
        return name
    }
}
