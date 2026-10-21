import Foundation

/// Claude Code's folder trust, in `~/.claude.json`: `projects["<git root>"].hasTrustDialogAccepted`. Claude keys it on
/// the repository's main checkout, so trusting that covers every worktree heed makes from it; without it, Claude asks
/// in each new worktree. Claude's docs say to set the key by hand to trust a folder ahead of time; heed does only that,
/// leaving everything else in the file as it was.
public enum ClaudeTrust {
    public static func defaultFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Whether `root` is trusted in `file`. A missing or unreadable file trusts nothing.
    public static func isTrusted(_ root: String, file: URL = defaultFile()) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any], let entry = projects[root] as? [String: Any]
        else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool ?? false
    }

    public enum TrustError: Error, CustomStringConvertible {
        case home
        case unreadable(String)

        public var description: String {
            switch self {
            case .home: "heed never trusts the home folder"
            case let .unreadable(reason): "~/.claude.json: \(reason)"
            }
        }
    }

    /// Trusts `root` in `file`: the one key set, the rest of the file untouched. The first time heed changes the file
    /// it keeps a copy beside it (`.heed-backup`); the write is atomic. Never the home folder.
    public static func trust(_ root: String, file: URL = defaultFile(), home: String = NSHomeDirectory()) throws {
        let normalized = URL(fileURLWithPath: root).standardizedFileURL.path
        guard normalized != URL(fileURLWithPath: home).standardizedFileURL.path else { throw TrustError.home }
        let manager = FileManager.default
        let source: String
        if manager.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { throw TrustError.unreadable("could not read it") }
            source = String(decoding: data, as: UTF8.self)
            let backup = file.appendingPathExtension("heed-backup")
            if !manager.fileExists(atPath: backup.path) { try data.write(to: backup) }
        } else {
            source = "{}\n"
        }
        let edited = try trusting(root, in: source)
        try Data(edited.utf8).write(to: file, options: .atomic)
    }

    /// `source` with `projects[root].hasTrustDialogAccepted` set to true, changed in place: an existing value replaced,
    /// a missing key, entry or `projects` added at the top of its object in the file's own indentation. Falls back to
    /// rewriting the whole document only when the text cannot be edited in place.
    public static func trusting(_ root: String, in source: String) throws -> String {
        guard let data = source.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw TrustError.unreadable("not a JSON object") }
        if let edited = JSONText.setting(["projects", root, "hasTrustDialogAccepted"], to: "true", in: source),
           isTrusted(root, json: edited)
        {
            return edited
        }
        // Rewritten whole: keys in sorted order, but still valid and with everything in it.
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustError.unreadable("not a JSON object")
        }
        var projects = object["projects"] as? [String: Any] ?? [:]
        var entry = projects[root] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[root] = entry
        object["projects"] = projects
        let out = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: out, as: UTF8.self) + "\n"
    }

    static func isTrusted(_ root: String, json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any], let entry = projects[root] as? [String: Any]
        else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool == true
    }
}

/// Just enough JSON text handling to change one value in place: finds where a key path's value sits, and inserts a
/// member at the top of an object, so a file someone else owns keeps its order, spacing and everything else.
enum JSONText {
    /// `source` with the value at `path` (object keys) set to `literal`, adding whatever is missing along the way.
    /// Nil when the text does not have the expected shape.
    static func setting(_ path: [String], to literal: String, in source: String) -> String? {
        let text = Array(source.utf8)
        var object = skipSpace(text, 0)
        guard object < text.count, text[object] == UInt8(ascii: "{") else { return nil }
        var depth = 0
        for (index, key) in path.enumerated() {
            guard let members = members(text, object) else { return nil }
            if let member = members.first(where: { $0.key == key }) {
                if index == path.count - 1 {
                    var bytes = text
                    bytes.replaceSubrange(member.value, with: Array(literal.utf8))
                    return String(decoding: bytes, as: UTF8.self)
                }
                guard text[member.value.lowerBound] == UInt8(ascii: "{") else { return nil }
                object = member.value.lowerBound
                depth += 1
                continue
            }
            // Missing from here on: one member holding the rest of the path, at the top of this object.
            var value = literal
            for missing in path[(index + 1)...].reversed() {
                value = "{\(quote(missing)): \(value)}"
            }
            let indent = members.first.map { indentation(text, before: $0.keyStart) }
            let member = "\(quote(key)): \(value)"
            var bytes = text
            let insertAt = object + 1
            let insertion = if let indent {
                "\n\(indent)\(member),"
            } else {
                // An empty object: the member on a line of its own, indented one step past the object's own line.
                "\n\(String(repeating: " ", count: 2 * (depth + 1)))\(member)\n\(String(repeating: " ", count: 2 * depth))"
            }
            bytes.insert(contentsOf: Array(insertion.utf8), at: insertAt)
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    struct Member {
        var key: String
        var keyStart: Int
        var value: Range<Int>
    }

    /// The members of the object starting at `start` (its `{`), each with its key and its value's range.
    static func members(_ text: [UInt8], _ start: Int) -> [Member]? {
        var index = skipSpace(text, start + 1)
        var result: [Member] = []
        if index < text.count, text[index] == UInt8(ascii: "}") { return [] }
        while index < text.count {
            guard text[index] == UInt8(ascii: "\""), let keyEnd = skipString(text, index) else { return nil }
            guard let key = try? JSONSerialization.jsonObject(
                with: Data(text[index ..< keyEnd]), options: .fragmentsAllowed
            ) as? String else { return nil }
            let keyStart = index
            index = skipSpace(text, keyEnd)
            guard index < text.count, text[index] == UInt8(ascii: ":") else { return nil }
            let valueStart = skipSpace(text, index + 1)
            guard let valueEnd = skipValue(text, valueStart) else { return nil }
            result.append(Member(key: key, keyStart: keyStart, value: valueStart ..< valueEnd))
            index = skipSpace(text, valueEnd)
            guard index < text.count else { return nil }
            if text[index] == UInt8(ascii: "}") { return result }
            guard text[index] == UInt8(ascii: ",") else { return nil }
            index = skipSpace(text, index + 1)
        }
        return nil
    }

    static func skipSpace(_ text: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < text.count, [9, 10, 13, 32].contains(text[index]) {
            index += 1
        }
        return index
    }

    /// Past the string starting at `start` (its opening quote).
    static func skipString(_ text: [UInt8], _ start: Int) -> Int? {
        var index = start + 1
        while index < text.count {
            switch text[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index + 1
            default: index += 1
            }
        }
        return nil
    }

    /// Past the value starting at `start`: a string, an object or array (brackets balanced, strings skipped), or a
    /// bare literal (number, true, false, null).
    static func skipValue(_ text: [UInt8], _ start: Int) -> Int? {
        guard start < text.count else { return nil }
        switch text[start] {
        case UInt8(ascii: "\""):
            return skipString(text, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < text.count {
                switch text[index] {
                case UInt8(ascii: "\""):
                    guard let end = skipString(text, index) else { return nil }
                    index = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default: break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < text.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 9, 10, 13, 32]
                .contains(text[index])
            {
                index += 1
            }
            return index > start ? index : nil
        }
    }

    /// The spaces or tabs before `index` on its line.
    static func indentation(_ text: [UInt8], before index: Int) -> String {
        var start = index
        while start > 0, text[start - 1] == 32 || text[start - 1] == 9 {
            start -= 1
        }
        return String(decoding: text[start ..< index], as: UTF8.self)
    }

    static func quote(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: .withoutEscapingSlashes)) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// mise's trust: a repo whose mise config sets `[env]` is not loaded until it is trusted, and an agent's shell in a
/// new worktree would hit the prompt. Trust is shared across a repo's worktrees, so trusting the main checkout is
/// enough. Local repos only.
public enum MiseTrust {
    /// Whether the repo at `root` has a mise config with `[env]` that mise does not trust yet. False when mise is not
    /// installed or the repo does not use it.
    public static func needsTrust(_ root: String) async -> Bool {
        let configs = SetupDetection.miseFiles.map { "\(root)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
        let setsEnv = configs.contains { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return setsEnvironment(text)
        }
        guard setsEnv,
              let result = try? await ProcessRunner.run(
                  "mise",
                  ["-C", root, "trust", "--show"],
                  timeout: .seconds(10),
                  caller: "trust.mise"
              )
        else { return false }
        return untrusted(result.stdout, root: root)
    }

    /// Trusts the mise config of the repo at `root`.
    public static func trust(_ root: String) async throws {
        _ = try await ProcessRunner.output(
            "mise",
            ["-C", root, "trust", "--yes"],
            timeout: .seconds(10),
            caller: "trust.mise"
        )
    }

    /// A mise config sets environment variables: an `[env]` table (or `env.` keys).
    static func setsEnvironment(_ toml: String) -> Bool {
        toml.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[env") || trimmed.hasPrefix("env.") || trimmed.hasPrefix("env =")
        }
    }

    /// `mise trust --show` (`/path: untrusted` per config directory) says `root` is untrusted.
    static func untrusted(_ output: String, root: String) -> Bool {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return output.split(separator: "\n").contains { line in
            guard let colon = line.range(of: ": ", options: .backwards) else { return false }
            let path = URL(fileURLWithPath: String(line[..<colon.lowerBound])).resolvingSymlinksInPath().path
            return path == resolved && line[colon.upperBound...].trimmingCharacters(in: .whitespaces) == "untrusted"
        }
    }
}
