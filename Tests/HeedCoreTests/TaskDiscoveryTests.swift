import Foundation
@testable import HeedCore
import Testing

struct TaskDiscoveryTests {
    /// `mise tasks ls --json`, trimmed to the fields that matter.
    private let miseJSON = """
    [
      {"name": "build", "aliases": [], "description": "Debug build", "source": "/code/x/mise.toml",
       "dir": "/code/x", "hide": false, "global": false, "run": ["swift build"], "file": null},
      {"name": "docs:serve", "aliases": [], "description": "", "hide": false, "global": false},
      {"name": "secret", "description": "hidden", "hide": true, "global": false},
      {"name": "update-all", "description": "from ~/.config/mise", "hide": false, "global": true}
    ]
    """

    @Test func miseTasksAreTheRepoOwnVisibleOnes() {
        let tasks = TaskDiscovery.parseMise(miseJSON)
        #expect(tasks.map(\.name) == ["build", "docs:serve"])
        #expect(tasks[0] == TaskSpec(name: "build", command: "mise run build", source: .mise, detail: "Debug build"))
        #expect(tasks[1].command == "mise run docs:serve")
        #expect(tasks[1].detail == nil)
        #expect(TaskDiscovery.parseMise("mise ERROR not trusted").isEmpty)
    }

    /// The files section of `LC_ALL=C make -pRrq -f Makefile :` (GNU Make 3.81) for `makefile` below.
    private let database = """
    # GNU Make 3.81
    # Variables
    VERSION := 1
    # Files

    # Not a target:
    ::
    #  Command-line target.
    #  File does not exist.

    .PHONY: build test
    #  Implicit rule search has not been done.

    # Not a target:
    Makefile:
    #  Implicit rule search has been done.

    test: build
    #  Phony target (prerequisite of .PHONY).
    #  commands to execute (from `Makefile', line 8):
    \t@echo test
    \t

    build:
    #  Phony target (prerequisite of .PHONY).
    #  commands to execute (from `Makefile', line 5):
    \t@echo build
    \t

    _private:
    #  commands to execute (from `Makefile', line 17):
    \ttrue
    \t

    lint:
    #  commands to execute (from `Makefile', line 11):
    \t@echo lint
    \t

    # files hash-table stats:
    # Load=9/1024=1%, Rehash=0, Collisions=0/24=0%
    # Finished Make data base on Thu Oct 15 21:57:13 2026

    after: not-in-files
    """

    private let makefile = """
    .PHONY: build test
    VERSION := $(shell echo 1) ## not a target

    build: ## Build it
    \t@echo build ## not this

    test: build ## Run the tests
    \t@echo test

    lint:
    \t@echo lint
    """

    @Test func makeTargetsWithTheirDescriptions() {
        let tasks = TaskDiscovery.parseMake(database: database, makefile: makefile)
        #expect(tasks.map(\.name) == ["build", "lint", "test"])
        #expect(tasks.map(\.detail) == ["Build it", nil, "Run the tests"])
        #expect(tasks[0].command == "make build")
        #expect(tasks.allSatisfy { $0.source == .make })
        #expect(TaskDiscovery.parseMake(database: "", makefile: makefile).isEmpty)
    }

    @Test func makeTargetsFromARealMake() async throws {
        let repo = try TempRepo()
        try repo.write("Makefile", makefile.replacingOccurrences(of: "\n    ", with: "\n"))
        let result = await TaskDiscovery.discover(at: repo.path)
        #expect(result.tasks.map(\.name) == ["build", "lint", "test"])
    }

    private let packageJSON = """
    {
      "name": "site",
      "scripts": {
        "dev": "vite",
        "preinstall": "npx only-allow pnpm",
        "postinstall": "husky",
        "prepare": "husky",
        "build": "vite build",
        "prebuild": "rimraf dist",
        "test": "vitest",
        "posttest": "echo done",
        "prepublishOnly": "pnpm build",
        "lint": "eslint ."
      },
      "devDependencies": {"vite": "7"}
    }
    """

    @Test func packageScriptsWithoutLifecycleHooks() {
        let tasks = TaskDiscovery.parsePackageScripts(packageJSON, runner: "pnpm run")
        #expect(tasks.map(\.name) == ["dev", "build", "test", "lint"])
        #expect(tasks[0] == TaskSpec(name: "dev", command: "pnpm run dev", source: .packageJSON, detail: "vite"))
        #expect(TaskDiscovery.parsePackageScripts("{\"name\": \"x\"}").isEmpty)
    }

    @Test func theLockfilePicksTheRunner() {
        #expect(TaskDiscovery.packageRunner(files: ["package.json", "pnpm-lock.yaml"]) == "pnpm run")
        #expect(TaskDiscovery.packageRunner(files: ["bun.lockb"]) == "bun run")
        #expect(TaskDiscovery.packageRunner(files: ["bun.lock"]) == "bun run")
        #expect(TaskDiscovery.packageRunner(files: ["yarn.lock"]) == "yarn")
        #expect(TaskDiscovery.packageRunner(files: ["package-lock.json"]) == "npm run")
        #expect(TaskDiscovery.packageRunner(files: []) == "npm run")
    }

    @Test func discoversInAWorktreeAfterThePinnedOnes() async throws {
        let repo = try TempRepo()
        try repo.write("package.json", packageJSON)
        try repo.write("yarn.lock", "")
        let pinned = [TaskSpec(name: "tests", command: "dotnet test")]
        let result = await TaskDiscovery.discover(at: repo.path, pinned: pinned)
        #expect(result.tasks.first == pinned[0])
        #expect(result.tasks.dropFirst().map(\.command) == ["yarn dev", "yarn build", "yarn test", "yarn lint"])
        #expect(result.notes.isEmpty)
    }

    @Test func aTaskPaneReportsItsExit() {
        let pane = TaskSpec(name: "dev", command: "pnpm run dev", source: .packageJSON).pane(directory: "/code/x")
        #expect(pane.role == .task)
        #expect(pane.title == "dev")
        #expect(pane.command == "pnpm run dev; \"${HEED_BIN:-true}\" task-exit $?")
    }

    @Test func pinnedTasksDecodeWithoutASource() throws {
        let data = Data(#"{"name": "test", "command": "dotnet test"}"#.utf8)
        #expect(try JSONDecoder().decode(TaskSpec.self, from: data) == TaskSpec(name: "test", command: "dotnet test"))
    }
}
