import Foundation

/// Where a swarm's lead and workers run: this Mac, or a host heed reaches over ssh (`[hosts.<name>]`). A swarm has one
/// place (`SwarmSettings.host`, picked in the form); a task may name its own (`SwarmTask.host`: a host, or `local` for
/// this Mac), which wins for its worker. On a host a worker runs as a session there does: its worktree under the
/// host's `worktree_root`, its agent in zmx with heed's hooks writing to the host's event log.
public enum SwarmPlace {
    /// What a task's `host` says for this Mac.
    public static let local = "local"

    /// Where a task's worker runs: the task's own host (or this Mac for `local`), else where the swarm runs.
    public static func location(of task: SwarmTask?, swarm settings: SwarmSettings) -> Location {
        guard let host = task?.host else { return settings.location }
        return host == local ? .local : .host(host)
    }

    /// Where a task's next worker runs: where its last one did when it carries on in that worker's worktree (a task
    /// handed to another agent, or taken back to its PR for a conflict or a rebase), else where the task says now.
    public static func location(
        of task: SwarmTask?, swarm settings: SwarmSettings, previous: SwarmWorker?, carriesOn: Bool
    ) -> Location {
        if carriesOn, let previous { return previous.location }
        return location(of: task, swarm: settings)
    }

    /// Whether a worker's kept worktree can take its task back: on this Mac, it is there (`exists`); on a host, the
    /// host answers (`problem` nil); whether it is still there is looked at over ssh before the worker starts.
    public static func keptWorktree(
        _ worker: SwarmWorker, exists: (String) -> Bool, problem: (Location) -> String?
    ) -> Bool {
        guard !worker.worktree.isEmpty else { return false }
        return worker.location.isLocal ? exists(worker.worktree) : problem(worker.location) == nil
    }

    /// A place as typed (in the plan pane, `:swarm.task.host`, the lead's JSON): what a task's `host` holds. `local`,
    /// `mac`, `this mac` or `here` is this Mac; `@devbox` or `devbox` a host; empty, `-` or `swarm` is where the swarm
    /// runs (nil). With `hosts` (config's), a host it does not have is refused, saying which it has.
    public static func parse(_ word: String, hosts: [String]? = nil) -> Result<String?, Problem> {
        var text = word.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") { text.removeFirst() }
        switch text.lowercased() {
        case "", "-", "swarm", "default": return .success(nil)
        case "local", "mac", "this mac", "here": return .success(local)
        default: break
        }
        if let hosts, !hosts.contains(text) {
            let known = hosts.isEmpty ? "no hosts yet: gH adds one" : hosts.sorted().map { "@\($0)" }
                .joined(separator: ", ")
            return .failure(Problem("no host @\(text) (\(known))"))
        }
        return .success(text)
    }

    /// Where an agent at `location` reads the goal's GOAL.md (`path`, on this Mac): there, or through `heed goal show`
    /// on a host, which cannot read this Mac's files.
    public static func doc(_ path: String, at location: Location) -> String {
        location.isLocal ? path : "on the owner's Mac, which heed goal show prints"
    }

    /// `@devbox`, `this Mac`.
    public static func label(_ location: Location) -> String { location.hostName.map { "@\($0)" } ?? "this Mac" }

    /// Why nothing can start at `location` now, or nil when it can: a host config does not have, or one that does not
    /// answer (its check also says where its home is, which its hook paths need).
    public static func problem(
        _ location: Location, hosts: [String: HostConfig], statuses: [String: HostStatus]
    ) -> String? {
        guard let host = location.hostName else { return nil }
        guard hosts[host] != nil else { return "no host @\(host) in config.toml" }
        guard case let .connected(info) = statuses[host] ?? .unknown else {
            return "@\(host) does not answer: gH shows why"
        }
        return info.home == nil ? "@\(host) has not said where its home is: gH checks it again" : nil
    }

    /// Where the lead runs, and the hosts the swarm's workers may run on (the swarm's, and any its tasks name).
    public static func hosts(_ settings: SwarmSettings, tasks: [SwarmTask]) -> [String] {
        var names: [String] = []
        for location in [settings.location] + tasks.map({ location(of: $0, swarm: settings) }) {
            if let host = location.hostName, !names.contains(host) { names.append(host) }
        }
        return names
    }

    public struct Problem: Error, Equatable, Sendable {
        public var text: String
        public init(_ text: String) { self.text = text }
    }
}

/// A worker's worktree where it runs. On this Mac as before; on a host every step goes over the host's shared ssh
/// connection (`ProcessRunner.run(on:)`): heed's hook files first (`HostSetup.install`, as a session there gets),
/// then the worktree under the host's worktree root from the host's clone, then its `.worktreeinclude` files. Nothing
/// is cloned to this Mac, and the worktree stays on the host when the worker ends.
public enum SwarmWorktree {
    /// Whether a worker's worktree is still there, and its real path: a task resumed or handed over carries on in it.
    public static func existing(_ path: String, on location: Location) async -> String? {
        guard !location.isLocal else { return FileManager.default.fileExists(atPath: path) ? path : nil }
        // `~/…` on a host: its real path, which is what the pane's `cd` and the agent's hooks see.
        guard let top = try? await ProcessRunner.output(
            on: location, "git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: .seconds(10),
            caller: "swarm.worktree"
        ) else { return nil }
        let real = top.trimmingCharacters(in: .whitespacesAndNewlines)
        return real.isEmpty ? nil : real
    }

    /// The worktree for a worker on `branch`, at `path` in `record`'s clone (on its machine): the one an earlier worker
    /// left there (which carries on from `keptBase`, what it was made from), else a new one from `base`. `hostFiles`
    /// go on a host first (`HostSetup.integration`), so its agent's hooks are there. Returns its real path, whether it
    /// was there already, and the base it is on.
    public static func make(
        _ record: RepoRecord, path: String, branch: String, base: String, keptBase: String? = nil,
        hostFiles: [String: String] = [:]
    ) async throws -> (path: String, reused: Bool, base: String) {
        if let host = record.location.hostName {
            try await HostSetup.install(on: host, files: hostFiles)
        }
        if let kept = await existing(path, on: record.location) { return (kept, true, keptBase ?? base) }
        let made = try await Git.addRunWorktree(record, path: path, branch: base, runBranch: branch)
        await WorktreeInclude.copy(from: record.path, to: made, on: record.location)
        return (made, false, base)
    }
}

public extension FileActivityPolling {
    /// How often a worker's worktree on a host is read: less often than one here, since each read is three git calls
    /// over ssh.
    static let hostInterval: TimeInterval = 180

    /// The interval for a worktree at `location`.
    static func interval(for location: Location) -> TimeInterval { location.isLocal ? interval : hostInterval }
}
