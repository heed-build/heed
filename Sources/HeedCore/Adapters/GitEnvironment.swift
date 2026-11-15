import Foundation
import Synchronization

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

    private static let overrides = Mutex<[String: String]>([:])

    /// From now on, every command reads no system or global git config and commits as a fixed author: for tests'
    /// throwaway repos, so neither your config nor your signing setup reaches them. Idempotent.
    public static func isolate() {
        overrides.withLock { overrides in
            guard overrides.isEmpty else { return }
            let global = FileManager.default.temporaryDirectory
                .appendingPathComponent("heed-gitconfig-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: global.path, contents: Data())
            overrides = [
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": global.path,
                "GIT_AUTHOR_NAME": "heed test", "GIT_AUTHOR_EMAIL": "test@heed.invalid",
                "GIT_COMMITTER_NAME": "heed test", "GIT_COMMITTER_EMAIL": "test@heed.invalid",
            ]
        }
    }

    /// What a command runs with: this process's environment scrubbed, the isolation when on, then `variables`.
    public static func environment(
        _ parent: [String: String] = ProcessInfo.processInfo.environment, _ variables: [String: String] = [:]
    ) -> [String: String] {
        scrubbed(parent).merging(overrides.withLock { $0 }) { _, new in new }.merging(variables) { _, new in new }
    }
}
