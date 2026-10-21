import Foundation

/// The tasks a worktree can run besides its pinned ones: its mise tasks, its make targets, and its package.json
/// scripts.
/// Read from the worktree itself (here or on a host), so a branch that adds a task offers it.
public enum TaskDiscovery {
    /// What a worktree offers, and why a source offered nothing when it should have (an untrusted mise config).
    public struct Result: Equatable, Sendable {
        public var tasks: [TaskSpec]
        public var notes: [String]

        public init(tasks: [TaskSpec] = [], notes: [String] = []) {
            self.tasks = tasks
            self.notes = notes
        }
    }

    /// The pinned tasks first, then what the worktree at `path` offers: mise, make, package.json.
    public static func discover(
        at path: String, on location: Location = .local, pinned: [TaskSpec] = []
    ) async -> Result {
        let files = await Set(SetupDetection.files(at: path, on: location))
        async let mise = miseTasks(at: path, on: location, files: files)
        async let make = makeTargets(at: path, on: location, files: files)
        async let scripts = packageScripts(at: path, on: location, files: files)
        let found = await [mise, make, scripts]
        return Result(tasks: pinned + found.flatMap(\.tasks), notes: found.flatMap(\.notes))
    }

    // MARK: mise

    /// Where mise finds tasks: its config files, and the directories of file tasks.
    static let miseTaskDirectories = ["mise-tasks", ".mise-tasks", "mise/tasks", ".mise/tasks", ".config/mise/tasks"]

    static func miseTasks(at path: String, on location: Location, files: Set<String>) async -> Result {
        guard (SetupDetection.miseFiles + miseTaskDirectories).contains(where: files.contains) else { return Result() }
        guard let result = try? await ProcessRunner.run(
            on: location, "mise", ["-C", path, "tasks", "ls", "--json"], timeout: .seconds(15), caller: "tasks.mise"
        ) else { return Result() }
        guard result.succeeded else {
            return Result(notes: result.stderr.contains("not trusted")
                ? ["mise: the repo's config is not trusted (mise trust)"] : [])
        }
        return Result(tasks: parseMise(result.stdout))
    }

    /// `mise tasks ls --json`: the repo's own tasks, not global or hidden ones, each run with `mise run`.
    public static func parseMise(_ json: String) -> [TaskSpec] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty,
                  item["global"] as? Bool != true, item["hide"] as? Bool != true
            else { return nil }
            let description = (item["description"] as? String)?.trimmingCharacters(in: .whitespaces)
            return TaskSpec(
                name: name, command: "mise run \(ShellQuote.quote(name))", source: .mise,
                detail: description?.nilIfEmpty
            )
        }
    }

    // MARK: make

    static let makefiles = ["GNUmakefile", "makefile", "Makefile"]

    static func makeTargets(at path: String, on location: Location, files: Set<String>) async -> Result {
        guard let makefile = makefiles.first(where: files.contains) else { return Result() }
        // make's own database lists every target, included makefiles' too; nothing is built (-q), and no built-in
        // rules or variables muddy it (-R -r).
        let database = await (try? ProcessRunner.run(
            on: location, "make", ["-C", path, "-pRrq", "-f", makefile, ":"], timeout: .seconds(15),
            caller: "tasks.make"
        ))?.stdout ?? ""
        let text = await (try? ProcessRunner.output(
            on: location,
            "cat",
            ["\(path)/\(makefile)"],
            caller: "tasks.make"
        )) ?? ""
        return Result(tasks: parseMake(database: database, makefile: text, name: makefile))
    }

    /// Targets from `make -pRrq`'s database (the files section; not special targets, not the makefile itself, nothing
    /// starting with `_` or another non-letter), with descriptions from `target: ... ## Description` comments.
    public static func parseMake(database: String, makefile: String, name: String = "Makefile") -> [TaskSpec] {
        var targets: [String] = []
        var inFiles = false
        var paragraphStart = true
        for line in database.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# Files") {
                inFiles = true
            } else if line.hasPrefix("# Finished Make data base") {
                inFiles = false
            }
            defer { paragraphStart = line.trimmingCharacters(in: .whitespaces).isEmpty }
            guard inFiles, paragraphStart, !line.hasPrefix("#"), !line.hasPrefix("."),
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let target = String(line[..<colon])
            guard let first = target.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
                  !target.contains(" "), target != name, !makefiles.contains(target), !targets.contains(target)
            else { continue }
            targets.append(target)
        }
        let descriptions = makeDescriptions(makefile)
        return targets.sorted().map {
            TaskSpec(name: $0, command: "make \(ShellQuote.quote($0))", source: .make, detail: descriptions[$0])
        }
    }

    /// `build test: deps ## Build and test` gives both targets that description.
    static func makeDescriptions(_ makefile: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in makefile.split(separator: "\n") where !line.hasPrefix("\t") {
            guard let marker = line.range(of: "##"), let colon = line[..<marker.lowerBound].firstIndex(of: ":"),
                  !line[colon...].hasPrefix(":=")
            else { continue }
            let description = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !description.isEmpty else { continue }
            for target in line[..<colon].split(separator: " ") {
                result[String(target)] = description
            }
        }
        return result
    }

    // MARK: package.json

    static func packageScripts(at path: String, on location: Location, files: Set<String>) async -> Result {
        guard files.contains("package.json"),
              let json = try? await ProcessRunner.output(
                  on: location,
                  "cat",
                  ["\(path)/package.json"],
                  caller: "tasks.npm"
              )
        else { return Result() }
        return Result(tasks: parsePackageScripts(json, runner: packageRunner(files: files)))
    }

    /// How a repo runs its scripts, by its lockfile: `pnpm run`, `bun run`, `yarn`, else `npm run`.
    public static func packageRunner(files: Set<String>) -> String {
        if files.contains("pnpm-lock.yaml") { return "pnpm run" }
        if files.contains("bun.lock") || files.contains("bun.lockb") { return "bun run" }
        if files.contains("yarn.lock") { return "yarn" }
        return "npm run"
    }

    /// npm's lifecycle scripts: run by installs and publishes, never by hand.
    static let lifecycle: Set<String> = [
        "preinstall", "install", "postinstall", "prepare", "preprepare", "postprepare", "prepublish",
        "prepublishOnly", "publish", "postpublish", "prepack", "pack", "postpack", "preuninstall", "uninstall",
        "postuninstall", "preversion", "version", "postversion", "dependencies", "preshrinkwrap", "shrinkwrap",
        "postshrinkwrap",
    ]

    /// package.json's scripts, in the file's order, without lifecycle scripts or the `pre`/`post` hooks of another
    /// script (`pretest` beside `test`).
    public static func parsePackageScripts(_ json: String, runner: String = "npm run") -> [TaskSpec] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any]
        else { return [] }
        let names = Set(scripts.keys)
        func isHook(_ name: String) -> Bool {
            for prefix in ["pre", "post"] where name.hasPrefix(prefix) {
                let base = String(name.dropFirst(prefix.count))
                if names.contains(base) || lifecycle.contains(base) { return true }
            }
            return false
        }
        return orderedKeys(of: "scripts", in: json, fallback: names.sorted()).compactMap { name in
            guard let command = scripts[name] as? String, !lifecycle.contains(name), !isHook(name) else { return nil }
            return TaskSpec(
                name: name, command: "\(runner) \(ShellQuote.quote(name))", source: .packageJSON, detail: command
            )
        }
    }

    /// The keys of a top-level object member in the order the text has them (JSONSerialization loses it).
    static func orderedKeys(of member: String, in json: String, fallback: [String]) -> [String] {
        let text = Array(json.utf8)
        let start = JSONText.skipSpace(text, 0)
        guard start < text.count, let top = JSONText.members(text, start),
              let object = top.first(where: { $0.key == member }), text[object.value.lowerBound] == UInt8(ascii: "{"),
              let members = JSONText.members(text, object.value.lowerBound)
        else { return fallback }
        return members.map(\.key)
    }
}
