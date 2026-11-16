import Foundation

/// The environment the commands heed runs get. Variables that point git at a repository (`GIT_DIR` and its kin) are
/// never passed on: heed always names the repo it means (`git -C`), and one inherited from whatever started heed (a
/// hook, `git rebase --exec`) would send its commands to another repo.
public enum GitEnvironment {
    /// What git reads to decide which repository, index and object store it works on.
    public static let repositoryVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR", "GIT_PREFIX",
    ]

    /// `environment` without the repository variables.
    public static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !repositoryVariables.contains($0.key) }
    }

    /// The environment commands inherit: this process's, or for one task and the tasks it starts the one a test
    /// hands in (as `git rebase --exec` would leave it), so the test never changes the process's own.
    @TaskLocal static var inheritedOverride: [String: String]?

    public static var inherited: [String: String] { inheritedOverride ?? ProcessInfo.processInfo.environment }

    /// What a command runs with: the inherited environment scrubbed, then `variables`.
    public static func environment(
        _ parent: [String: String] = inherited, _ variables: [String: String] = [:]
    ) -> [String: String] {
        scrubbed(parent).merging(variables) { _, new in new }
    }
}
