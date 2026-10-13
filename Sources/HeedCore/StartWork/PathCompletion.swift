import Foundation

/// Directory completion for typing a path (`P` in Sessions, import a path): what the last component could become.
public enum PathCompletion {
    /// Directories that complete `query`: the children of its parent whose names start with what is typed after the
    /// last `/` (case-insensitive). Hidden ones only when that starts with `.`. At most `limit`, sorted by name.
    public static func candidates(
        for query: String, limit: Int = 12, fileManager: FileManager = .default
    ) -> [String] {
        let expanded = Paths.expand(query)
        let parent: String
        let prefix: String
        // expandingTildeInPath drops a trailing slash, so ask the query whether it ends in one.
        if query.hasSuffix("/") {
            parent = expanded
            prefix = ""
        } else {
            parent = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        guard !parent.isEmpty, let names = try? fileManager.contentsOfDirectory(atPath: parent) else { return [] }
        let base = parent.hasSuffix("/") ? parent : parent + "/"
        return names
            .filter { name in
                (prefix.hasPrefix(".") || !name.hasPrefix("."))
                    && (prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased()))
            }
            .filter { name in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: base + name, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { base + $0 }
    }

    /// The query with its last path component removed (`⌃w`): `~/code/heed/` → `~/code/`.
    public static func droppingLastComponent(_ query: String) -> String {
        var text = query
        if text.hasSuffix("/") { text.removeLast() }
        guard let slash = text.lastIndex(of: "/") else { return "" }
        return String(text[...slash])
    }
}
