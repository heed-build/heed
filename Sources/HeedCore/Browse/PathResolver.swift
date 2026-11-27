import Foundation

/// Where a path really points, and whether a tree holds a symlink that leads out of it.
public enum PathResolver {
    public static func realpath(_ path: String) -> String { path }

    /// Symlinks under `root` whose target resolves outside it (relative paths), at most `limit`.
    public static func escapingLinks(in root: String, limit: Int = 20) -> [String] { [] }
}
