import Foundation

/// Where a path really points, and whether a tree holds a symlink that leads out of it.
public enum PathResolver {
    /// `path` with every symlink followed and every `..` applied to what is really there, as `realpath(3)` does, but
    /// for a path that does not (all) exist too: the part that does not exist is taken as written, since nothing there
    /// can be a link. A relative path is returned as it is. `..` is never folded before the links in front of it are
    /// resolved: `evil/../x` is the parent of where `evil` points, not `x`.
    public static func realpath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var resolved: [String] = []
        var pending: [String] = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed()
        var exists = true
        var hops = 0
        while let part = pending.popLast() {
            if part == "." { continue }
            if part == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if exists {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                    hops += 1
                    // A loop of links, or a chain too long to be real: nowhere inside any folder.
                    if hops > 40 { return "/.heed-unresolvable-link" }
                    if target.hasPrefix("/") { resolved = [] }
                    let more: [String] = target.split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init).reversed()
                    pending.append(contentsOf: more)
                    continue
                }
                var info = stat()
                if lstat(candidate, &info) != 0 { exists = false }
            }
            resolved.append(part)
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Symlinks under `root` whose target resolves outside it, as paths relative to it (at most `limit`). A link
    /// that stays inside is fine. Does not descend into `.git`. An untrusted pull request head can commit
    /// `../../../../.ssh/id_rsa` as a file, and `cat` follows it.
    public static func escapingLinks(in root: String, limit: Int = 20) -> [String] {
        let fm = FileManager.default
        let real = realpath(root)
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        while let relative = walker.nextObject() as? String {
            if relative == ".git" || relative.hasPrefix(".git/") {
                walker.skipDescendants()
                continue
            }
            let full = root + "/" + relative
            guard let kind = try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType,
                  kind == .typeSymbolicLink
            else { continue }
            let target = realpath(full)
            if target != real, !target.hasPrefix(real + "/") {
                found.append(relative)
                if found.count >= limit { break }
            }
        }
        return found
    }
}
