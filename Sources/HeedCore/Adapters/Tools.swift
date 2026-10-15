import Foundation

/// `[tools]` in config.toml: where git and gh live when detection gets it wrong. Empty means detect.
public struct ToolSettings: Equatable, Sendable {
    /// A path (`/opt/homebrew/bin/git`, `~/bin/git`) or a name looked up on the search path.
    public var git = ""
    public var gh = ""
    /// zmx, for persistent panes; empty: found on the search path.
    public var zmx = ""
    /// Directories searched before anything detected, for git, gh and agent commands alike.
    public var path: [String] = []

    public init(git: String = "", gh: String = "", path: [String] = []) {
        self.git = git
        self.gh = gh
        self.path = path
    }

    public func configured(_ tool: String) -> String {
        switch tool {
        case "git": git
        case "gh": gh
        default: ""
        }
    }
}

/// Where a directory on the search path came from, in the order they are searched.
public enum ToolSource: String, Equatable, Sendable {
    case config = "config.toml"
    case loginShell = "login shell"
    case known = "usual location"
    case inherited = "app PATH"
}

public struct ResolvedTool: Equatable, Sendable {
    public let name: String
    /// The executable that answered `--version`; nil when none did.
    public let path: String?
    public let version: String?
    public let source: ToolSource?
    /// What went wrong on the way, even when a fallback was found (a configured path that does not work).
    public let problem: String?

    public init(name: String, path: String?, version: String?, source: ToolSource?, problem: String?) {
        self.name = name
        self.path = path
        self.version = version
        self.source = source
        self.problem = problem
    }
}

/// What tool detection found: the search path every command runs with, and git and gh.
public struct ToolReport: Equatable, Sendable {
    public var shell: String
    /// The login shell's PATH; nil when the shell did not answer.
    public var shellPath: [String]?
    public var searchPath: [String]
    public var tools: [ResolvedTool]

    public init(shell: String, shellPath: [String]?, searchPath: [String], tools: [ResolvedTool]) {
        self.shell = shell
        self.shellPath = shellPath
        self.searchPath = searchPath
        self.tools = tools
    }

    public func tool(_ name: String) -> ResolvedTool? { tools.first { $0.name == name } }

    public var problems: [String] { tools.compactMap(\.problem) }

    /// `PATH` for child processes and panes.
    public var pathVariable: String { searchPath.joined(separator: ":") }
}

/// Finds git, gh and agent commands. An app opened from Finder gets `/usr/bin:/bin:/usr/sbin:/sbin` as its PATH, so
/// nothing installed by Homebrew, mise or nix is on it. The search path is, in order: `[tools] path`, the login
/// shell's PATH (fish, zsh, bash, nu), the usual install locations, then whatever PATH the app was given.
public enum ToolDetection {
    public static let tools = ["git", "gh"]

    /// Install locations worth trying when the login shell does not answer. `~` is expanded.
    public static let knownDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin",
        "~/.local/bin", "~/bin", "~/.local/share/mise/shims", "~/.asdf/shims",
        "~/.nix-profile/bin", "/etc/profiles/per-user/\(NSUserName())/bin", "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin", "~/.cargo/bin", "~/.bun/bin", "~/.volta/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// Commands in /usr/bin that are only stubs for the Xcode Command Line Tools: running one without them installed
    /// pops up an install dialog, so they are checked for before being run.
    static let developerStubs: Set<String> = ["git"]

    public static func detect(_ settings: ToolSettings) async -> ToolReport {
        let shell = loginShell()
        let shellPath = await loginShellPath(shell)
        var directories: [(String, ToolSource)] = settings.path.map { (Paths.expand($0), .config) }
        directories += (shellPath ?? []).map { ($0, .loginShell) }
        directories += knownDirectories.map { (Paths.expand($0), .known) }
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { (String($0), .inherited) }
        let search = searchPath(directories)
        let developerDirectory = await developerDirectory()
        var resolved: [ResolvedTool] = []
        for tool in tools {
            await resolved.append(resolve(
                tool, configured: settings.configured(tool), directories: search,
                check: { path in await version(of: path, developerDirectory: developerDirectory) }
            ))
        }
        return ToolReport(shell: shell, shellPath: shellPath, searchPath: search.map(\.0), tools: resolved)
    }

    /// Existing directories, first occurrence wins.
    static func searchPath(_ directories: [(String, ToolSource)]) -> [(String, ToolSource)] {
        var seen: Set<String> = []
        return directories.filter { directory, _ in
            var isDirectory: ObjCBool = false
            guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return false }
            return seen.insert(directory).inserted
        }
    }

    /// The configured value first (a path, or a name searched for), then every executable named `tool` on the search
    /// path, until one answers `check` (its version). A configured value that does not work is reported, and
    /// detection carries on so the app still works.
    public static func resolve(
        _ tool: String, configured: String, directories: [(String, ToolSource)],
        check: (String) async -> String?
    ) async -> ResolvedTool {
        var problem: String?
        let wanted = configured.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            let candidates = wanted.contains("/")
                ? [Paths.expand(wanted)]
                : directories.map { "\($0.0)/\(wanted)" }.filter(isExecutable)
            for path in candidates where isExecutable(path) {
                if let version = await check(path) {
                    return ResolvedTool(name: tool, path: path, version: version, source: .config, problem: nil)
                }
            }
            problem = candidates.first.map { path in
                isExecutable(path)
                    ? "tools.\(tool) = \"\(wanted)\" does not run"
                    : "tools.\(tool) = \"\(wanted)\": no executable at \(path)"
            } ?? "tools.\(tool) = \"\(wanted)\" is not on the search path"
        }
        var skipped: String?
        for (directory, source) in directories {
            let path = "\(directory)/\(tool)"
            guard isExecutable(path) else { continue }
            if let version = await check(path) {
                return ResolvedTool(
                    name: tool, path: path, version: version, source: source,
                    problem: problem.map { "\($0); using \(path)" }
                )
            }
            skipped = skipped ?? path
        }
        let hint = tool == "gh" ? "brew install gh" : "brew install git, or xcode-select --install"
        let reason = skipped.map { "\(tool) at \($0) does not run" } ?? "\(tool) not found"
        return ResolvedTool(
            name: tool, path: nil, version: nil, source: nil,
            problem: (problem.map { "\($0); " } ?? "") + "\(reason): \(hint), or set [tools] \(tool) in config.toml"
        )
    }

    /// An executable called `name` on the search path (agent commands, which need no version check).
    public static func find(_ name: String, in searchPath: [String]) -> String? {
        if name.contains("/") { return isExecutable(Paths.expand(name)) ? Paths.expand(name) : nil }
        return searchPath.map { "\($0)/\(name)" }.first(where: isExecutable)
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: The login shell

    /// `$SHELL`, else the account's shell, else zsh.
    static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    static let marker = "__HEED_PATH__"

    /// Ways to ask a shell for its PATH, tried in order. zsh and bash read their rc files only when interactive, which
    /// is where PATH is often set, so the interactive form goes first; fish reads config.fish either way.
    static func pathQueries(for shell: String) -> [[String]] {
        let print = "printf '\\n\(marker)%s\\n'"
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "fish": return [["-l", "-c", "\(print) (string join : $PATH)"]]
        case "nu": return [["-l", "-c", "print $\"\\n\(marker)($env.PATH | str join ':')\""]]
        case "zsh", "bash": return [["-l", "-i", "-c", "\(print) \"$PATH\""], ["-l", "-c", "\(print) \"$PATH\""]]
        default: return [["-l", "-c", "\(print) \"$PATH\""]]
        }
    }

    /// The PATH line out of whatever else a shell prints while starting (greetings, rc file noise).
    static func parsePath(_ output: String) -> [String]? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        let entries = line.dropFirst(marker.count).split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return entries.isEmpty ? nil : entries
    }

    static func loginShellPath(_ shell: String) async -> [String]? {
        guard isExecutable(shell) else { return nil }
        for arguments in pathQueries(for: shell) {
            if let result = try? await ProcessRunner.run(shell, arguments, in: NSHomeDirectory(), timeout: .seconds(8)),
               let path = parsePath(result.stdout)
            {
                return path
            }
        }
        return nil
    }

    // MARK: Checking a candidate

    /// The active Xcode or Command Line Tools directory; nil when neither is installed.
    static func developerDirectory() async -> String? {
        guard let output = try? await ProcessRunner.output("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5))
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The first line of `<path> --version`, or nil when it does not run.
    static func version(of path: String, developerDirectory: String?) async -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if path.hasPrefix("/usr/bin/"), developerStubs.contains(name) {
            guard let developerDirectory,
                  FileManager.default.fileExists(atPath: "\(developerDirectory)/usr/bin/\(name)")
            else { return nil }
        }
        guard let result = try? await ProcessRunner.run(path, ["--version"], timeout: .seconds(10)),
              result.succeeded
        else { return nil }
        return result.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The detected tools, shared by every process Heed starts. Detection runs once (and again when `[tools]` changes or
/// on `tools.detect`); commands started meanwhile wait for it rather than guessing.
public actor ToolLocator {
    public static let shared = ToolLocator()

    private var settings: ToolSettings?
    private var detection: Task<ToolReport, Never>?

    /// Detects again when the settings changed, or always with `force`. Returns the new report.
    @discardableResult
    public func configure(_ settings: ToolSettings, force: Bool = false) async -> ToolReport {
        if force || detection == nil || settings != self.settings {
            self.settings = settings
            detection = Task.detached { await ToolDetection.detect(settings) }
        }
        return await detection!.value
    }

    public func report() async -> ToolReport {
        if let detection { return await detection.value }
        return await configure(ToolSettings())
    }

    /// The executable to run for a bare command name, and the PATH to run it with.
    func executable(_ name: String) async -> (path: String?, pathVariable: String) {
        let report = await report()
        let path = report.tool(name)?.path ?? ToolDetection.find(name, in: report.searchPath)
        return (path, report.pathVariable)
    }
}
