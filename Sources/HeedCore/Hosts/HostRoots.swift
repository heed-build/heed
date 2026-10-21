import Foundation

/// A folder under a host's home that may hold projects, with how many main checkouts a scan of it would find.
public struct ProjectFolder: Hashable, Sendable {
    /// `~/Projects`: under the host's home, as `repo_roots` takes it.
    public var path: String
    /// Main checkouts two levels down (as `RemoteScan` finds them); nil for a folder you typed, not counted.
    public var repos: Int?

    public init(path: String, repos: Int?) {
        self.path = path
        self.repos = repos
    }
}

/// Where a host keeps its projects: one ssh call that looks in the usual folders under its home, and in any top-level
/// folder that directly holds a git checkout, and counts the checkouts in each.
public enum ProjectFolders {
    /// The usual places, under the host's home.
    public static let candidates = [
        "Projects", "projects", "code", "src", "dev", "repos", "git", "work", "Developer", "workspace", "go/src",
    ]

    /// Never looked in: big, and never where projects are.
    public static let skipped = ["Library", "node_modules", ".cache"]

    /// A POSIX sh script printing `folder=<checkouts> <path under $HOME>` for each folder that exists. It runs as
    /// `sh -c '<script>'` from whatever login shell the host has (fish too), so it holds no backslash, which fish would
    /// read inside single quotes. Only the real names in $HOME are tried (`*/`), so a case-insensitive disk (a Mac)
    /// lists `Projects` once, not again as `projects`; dot folders are never tried. Each count is `RemoteScan`'s find,
    /// three levels at most, skipping node_modules and .cache.
    public static let script = """
    cd "$HOME" 2>/dev/null || exit 0
    for d in */ go/src/; do
      d="${d%/}"
      [ -d "$d" ] || continue
      case " \(skipped.joined(separator: " ")) " in *" $d "*) continue ;; esac
      case " \(candidates.joined(separator: " ")) " in
        *" $d "*) ;;
        *) found=; for g in "$d"/*/.git; do [ -d "$g" ] && found=1 && break; done; [ -n "$found" ] || continue ;;
      esac
      n=$(find "$d" -maxdepth 3 -name node_modules -prune -o -name .cache -prune -o -name .git -type d -prune -print 2>/dev/null | wc -l | tr -d ' ')
      echo "folder=${n:-0} $d"
    done
    true
    """

    /// The folders in the script's output, as `~/<path>`: the ones with most checkouts first, then by name.
    public static func folders(fromOutput output: String) -> [ProjectFolder] {
        var folders: [ProjectFolder] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("folder=") else { continue }
            let rest = line.dropFirst("folder=".count)
            guard let space = rest.firstIndex(of: " "), let count = Int(rest[..<space]) else { continue }
            let path = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let folder = ProjectFolder(path: "~/" + path, repos: count)
            if !folders.contains(where: { $0.path == folder.path }) { folders.append(folder) }
        }
        return folders.sorted { ($0.repos ?? 0, $1.path) > ($1.repos ?? 0, $0.path) }
    }

    /// Looks on `host`; nil when it did not answer.
    public static func find(on host: String) async -> [ProjectFolder]? {
        guard let result = try? await ProcessRunner.run(on: .host(host), "sh", ["-c", script], timeout: .seconds(20)),
              result.succeeded
        else { return nil }
        return folders(fromOutput: result.stdout)
    }
}

/// Asking you where a host's projects are, and writing the answer as `[hosts.<name>] repo_roots` and `worktree_root`.
public enum HostRoots {
    /// Whether to ask after a check: the host answers, config does not say where its repos are, and you were not
    /// asked before (skipping counts as an answer; `host.roots` asks again).
    public static func shouldAsk(_ host: HostConfig, status: HostStatus, asked: Set<String>) -> Bool {
        status.isConnected && !host.explicitRepoRoots && !asked.contains(host.name)
    }

    /// What the dialog proposes for worktrees: what config says, else `~/code/wt`.
    public static func proposedWorktreeRoot(_ host: HostConfig) -> String {
        host.explicitWorktreeRoot ? host.worktreeRoot : HostConfig.defaultWorktreeRoot
    }

    /// The values to write for the answer, each a config.toml path and its value.
    public static func settings(host: String, roots: [String], worktreeRoot: String) -> [([String], TOMLValue)] {
        [
            (["hosts", host, "repo_roots"], .array(roots.map { .string($0) })),
            (["hosts", host, "worktree_root"], .string(worktreeRoot)),
        ]
    }

    /// A folder typed in the dialog, tidied (`~/x/` is `~/x`); nil unless it is under the home (`~` or `~/…`).
    public static func typedFolder(_ text: String) -> String? {
        var path = text.trimmingCharacters(in: .whitespaces)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        guard path == "~" || path.hasPrefix("~/"), !path.split(separator: "/").contains("..") else { return nil }
        return path
    }
}

/// The "Where are your projects on @host?" dialog: the folders found, each picked or not, a line to add one, and
/// where worktrees go.
public struct HostRootsChooser: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled
        /// ↩: these roots, worktrees under this folder.
        case save(roots: [String], worktreeRoot: String)
        /// ⎋: nothing written.
        case skip
        /// ↩ with nothing picked: why nothing was saved.
        case invalid(String)
    }

    /// The line being typed, if one is.
    public enum Editing: Equatable, Sendable {
        case folder(String)
        case worktreeRoot(String)
    }

    public struct Row: Equatable, Sendable {
        public var folder: ProjectFolder
        public var chosen: Bool
    }

    public let host: String
    public private(set) var rows: [Row]
    public private(set) var worktreeRoot: String
    /// The row under the cursor: a folder, then "add a folder…" (`rows.count`), then the worktrees line.
    public private(set) var cursor = 0
    public private(set) var editing: Editing?
    /// Why the last typed line was not taken.
    public private(set) var problem: String?

    /// Folders with checkouts start picked; the ones already in config are picked and listed even when not found.
    public init(host: String, found: [ProjectFolder], current: [String] = [], worktreeRoot: String) {
        self.host = host
        var rows = found.map { Row(folder: $0, chosen: ($0.repos ?? 0) > 0 || current.contains($0.path)) }
        for path in current where !rows.contains(where: { $0.folder.path == path }) {
            rows.append(Row(folder: ProjectFolder(path: path, repos: nil), chosen: true))
        }
        self.rows = rows
        self.worktreeRoot = worktreeRoot
    }

    public var addRow: Int { rows.count }
    public var worktreeRow: Int { rows.count + 1 }
    public var chosen: [String] { rows.filter(\.chosen).map(\.folder.path) }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        if let editing { return type(stroke, into: editing) }
        switch stroke {
        case .escape:
            return .skip
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"), KeyStroke("j"):
            cursor = min(cursor + 1, worktreeRow)
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"), KeyStroke("k"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("a"):
            startEditing(.folder("~/"))
        case KeyStroke("w"):
            startEditing(.worktreeRoot(worktreeRoot))
        case KeyStroke("Space"):
            if rows.indices.contains(cursor) { rows[cursor].chosen.toggle() } else { startEditingAtCursor() }
        case KeyStroke("CR"):
            if cursor >= addRow { startEditingAtCursor() } else { return save() }
        case KeyStroke("CR", .command):
            return save()
        default:
            break
        }
        return .handled
    }

    private mutating func save() -> Outcome {
        let roots = chosen
        guard !roots.isEmpty else { return .invalid("pick a folder (space), or ⎋ to skip") }
        return .save(roots: roots, worktreeRoot: worktreeRoot)
    }

    private mutating func startEditingAtCursor() {
        startEditing(cursor == addRow ? .folder("~/") : .worktreeRoot(worktreeRoot))
    }

    private mutating func startEditing(_ line: Editing) {
        editing = line
        problem = nil
    }

    private mutating func type(_ stroke: KeyStroke, into line: Editing) -> Outcome {
        var text: String = switch line {
        case let .folder(text), let .worktreeRoot(text): text
        }
        switch stroke {
        case .escape:
            editing = nil
            problem = nil
            return .handled
        case KeyStroke("CR"):
            guard let path = HostRoots.typedFolder(text) else {
                problem = "a folder under ~, like ~/Projects"
                return .handled
            }
            if case .folder = line {
                if let index = rows.firstIndex(where: { $0.folder.path == path }) {
                    rows[index].chosen = true
                    cursor = index
                } else {
                    rows.append(Row(folder: ProjectFolder(path: path, repos: nil), chosen: true))
                    cursor = rows.count - 1
                }
            } else {
                worktreeRoot = path
            }
            editing = nil
            problem = nil
            return .handled
        case KeyStroke("BS"):
            if !text.isEmpty { text.removeLast() }
        case KeyStroke("w", .control), KeyStroke("BS", .option):
            text = PathCompletion.droppingLastComponent(text)
        case KeyStroke("u", .control):
            text = ""
        case KeyStroke("Space"):
            text += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return .handled }
            text += stroke.key
        }
        editing = if case .folder = line { .folder(text) } else { .worktreeRoot(text) }
        problem = nil
        return .handled
    }
}
