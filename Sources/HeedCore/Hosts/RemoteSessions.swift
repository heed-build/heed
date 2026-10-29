import Foundation

/// What heed puts on a host so sessions can run there: in `~/.heed`, never anywhere else, no root.
public enum HostSetup {
    public static let directory = "~/.heed"
    public static let bin = "~/.heed/bin"
    /// zmx's sockets on the host, apart from any zmx sessions of your own.
    public static let zmxDirectory = "~/.heed/zmx"
    /// One line per hook call; heed reads it over ssh (`tail -F`).
    public static let eventLog = "~/.heed/events.log"

    /// The hook every agent on the host calls (`$HEED_BIN`), with heed's own arguments (`hook claude Stop`,
    /// `state working`, ...) and the agent's payload on stdin. It writes one line to the event log: the time, the
    /// session and pane, then the arguments and the payload, base64, so nothing in them can break the line. POSIX sh
    /// and coreutils only: there is nothing to compile for the host.
    public static let hookScript = #"""
    #!/bin/sh
    # heed's hook on this host: one line per call in ~/.heed/events.log, which heed reads over ssh.
    log="$HOME/.heed/events.log"
    payload=""
    if [ "$1" = hook ] && [ "$2" != pi ] && [ "$2" != opencode ] && [ ! -t 0 ]; then
      payload=$(base64 | tr -d '\n')
    fi
    args=""
    for a in "$@"; do args="$args$(printf '%s' "$a" | base64 | tr -d '\n') "; done
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${HEED_SESSION_ID:-}" "${HEED_PANE_ID:-}" "$args" "$payload" >>"$log"
    """#

    /// `heed` on the host (`~/.heed/bin/heed`, first on the PATH of heed's panes there): `heed goal …` and `heed swarm
    /// …` for the agents heed runs there, a lead or a worker of a swarm above all. There is no control socket to reach
    /// on a host, so it goes the way hooks do: one line in the event log (through `heed-hook call`, with the file a
    /// `--file` names, or stdin for `-`), which heed reads over ssh and answers like the `heed goal` on your Mac
    /// (`HostCall`); the answer comes back as `~/.heed/replies/<id>` (exit code, stdout and stderr, base64), which this
    /// waits for, prints and removes. `heed goal ask` waits as long as the question can; anything else a minute.
    /// POSIX sh and coreutils, as the hook.
    public static let heedScript = #"""
    #!/bin/sh
    # heed on this host: heed goal and heed swarm, answered by the heed app on your Mac through ~/.heed/events.log.
    case "$1" in
      goal|swarm) ;;
      *) echo "heed on a host runs heed goal and heed swarm only" >&2; exit 2 ;;
    esac
    id="$(date +%s)-$$"
    replies="$HOME/.heed/replies"
    mkdir -p "$replies"
    file=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--file" ] && file="$a"
      prev="$a"
    done
    input=""
    if [ "$file" = "-" ]; then
      input=$(base64 | tr -d '\n')
    elif [ -n "$file" ]; then
      [ -r "$file" ] || { echo "heed $1: cannot read $file" >&2; exit 2; }
      input=$(base64 < "$file" | tr -d '\n')
    fi
    "$HOME/.heed/bin/heed-hook" call "$id" "$input" "$@" </dev/null
    limit=${HEED_CALL_TIMEOUT:-60}
    [ "$2" = ask ] && limit=${HEED_CALL_TIMEOUT:-1800}
    waited=0
    while [ ! -f "$replies/$id" ]; do
      if [ "$waited" -ge "$limit" ]; then
        echo "heed $1: heed on your Mac did not answer (is it running, and connected to this host?)" >&2
        exit 3
      fi
      sleep 1
      waited=$((waited + 1))
    done
    decode() { base64 -d 2>/dev/null || base64 -D; }
    code=$(sed -n 1p "$replies/$id")
    sed -n 2p "$replies/$id" | decode
    sed -n 3p "$replies/$id" | decode >&2
    rm -f "$replies/$id"
    exit "${code:-1}"
    """#

    /// What heed puts on a host for its agents' hooks (path under `~/.heed` to content), with the paths agents there
    /// are given (`home` is the host's `$HOME`, from its check). Every agent heed starts on a host, in a session, a run
    /// or a swarm, is launched with these.
    public static func integration(home: String) -> (files: [String: String], integration: IntegrationFiles) {
        let integration = IntegrationFiles(
            directory: URL(fileURLWithPath: home).appendingPathComponent(".heed"),
            heedBinary: "\(home)/.heed/bin/heed-hook"
        )
        let files = [
            "~/.heed/claude-hooks.json": AgentIntegration.claudeSettingsJSON(),
            "~/.heed/heed-pi.js": AgentIntegration.piExtensionSource,
            "~/.heed/heed-opencode.js": AgentIntegration.opencodePluginSource,
        ]
        return (files, integration)
    }

    /// The shell line that writes stdin to a file under `~/.heed` (the hook, hook settings, plugins).
    public static func write(_ path: String, executable: Bool = false) -> String {
        let target = path.hasPrefix("~/") ? "\"$HOME\"/" + ShellQuote.quote(String(path.dropFirst(2))) : ShellQuote
            .quote(path)
        return "mkdir -p \"$HOME/.heed/bin\" && cat > \(target).tmp && mv \(target).tmp \(target)"
            + (executable ? " && chmod +x \(target)" : "")
    }
}

/// The event log's lines, back into heed's hook messages.
public enum HostEvents {
    /// One line of `~/.heed/events.log`; nil for a line that is not one (a partial write, something else).
    public static func messages(fromLine line: String) -> [HookMessage] {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let seconds = TimeInterval(fields[0]), !fields[1].isEmpty else { return [] }
        let args = fields[3].split(separator: " ").compactMap { Data(base64Encoded: String($0)) }
            .map { String(decoding: $0, as: UTF8.self) }
        let payload = Data(base64Encoded: fields[4]) ?? Data()
        guard let kinds = try? HookCommandLine.parse(args, readInput: { payload }) else { return [] }
        let pane = fields[2].isEmpty ? nil : fields[2]
        let at = Date(timeIntervalSince1970: seconds)
        return kinds.map {
            HookMessage(session: fields[1], pane: pane, kind: $0, sentAt: at, agent: HookCommandLine.agent(args))
        }
    }
}

/// A `heed goal …` or `heed swarm …` from a host (`HostSetup.heedScript`): its line in the event log, read back, and
/// the answer heed writes for it there.
public struct HostCall: Hashable, Sendable {
    /// `<seconds>-<pid>` on the host: the reply file's name.
    public var id: String
    /// The session and pane it came from (heed's pane environment there); empty from a shell heed did not start.
    public var session: String
    public var pane: String?
    /// The command line after `heed` (`goal plan propose --file plan.json`).
    public var arguments: [String]
    /// The file `--file` named, read on the host (or stdin for `-`).
    public var input: String?

    /// The call a line of `~/.heed/events.log` holds, if it holds one: `heed-hook call <id> <input> <arguments…>`.
    public init?(line: String) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return nil }
        // An empty argument is written as nothing between two spaces: kept, so the input keeps its place.
        let args = fields[3].split(separator: " ", omittingEmptySubsequences: false).dropLast()
            .map { Data(base64Encoded: String($0)).map { String(decoding: $0, as: UTF8.self) } }
        guard args.count >= 4, args[0] == "call", let id = args[1], Self.valid(id),
              let first = args[3], first == "goal" || first == "swarm"
        else { return nil }
        let rest = args.dropFirst(3).compactMap(\.self)
        guard rest.count == args.count - 3 else { return nil }
        self.id = id
        session = fields[1]
        pane = fields[2].isEmpty ? nil : fields[2]
        arguments = Array(rest)
        input = args[2]
            .flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) } }
    }

    public init(id: String, session: String, pane: String?, arguments: [String], input: String? = nil) {
        self.id = id
        self.session = session
        self.pane = pane
        self.arguments = arguments
        self.input = input
    }

    /// Only digits and a dash: it names a file on the host.
    static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count < 40 && id.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") }
    }

    /// How long the host's `heed` waits for its answer (`HostSetup.heedScript`): `ask` as long as a question can.
    public var patience: TimeInterval { arguments.count > 1 && arguments[1] == "ask" ? 1800 : 60 }

    /// Made longer ago than its `heed` waits (by the seconds in its id): nobody reads an answer now.
    public func isStale(now: Date) -> Bool {
        guard let seconds = id.split(separator: "-").first.flatMap({ TimeInterval(String($0)) }) else { return true }
        return now.timeIntervalSince1970 - seconds > patience
    }

    /// Where the answer goes on the host.
    public var replyPath: String { "~/.heed/replies/\(id)" }

    /// The answer to it, as the host's `heed` reads it: what `heed goal` on this Mac would print and exit with. `call`
    /// asks heed (its control method `goal`, in the app; nil when it did not answer); an `ask` is waited for here, as
    /// the CLI waits, with `sleep` and `clock`. Only heed's own panes there may ask: a shell heed did not start has no
    /// session, and what needs none (approving a plan) is the owner's, from a terminal on this Mac.
    public func answer(
        call: @Sendable (ControlRequest) async -> ControlReply?, sleep: @Sendable (TimeInterval) async -> Void,
        clock: @Sendable () -> Date
    ) async -> String {
        let verb = arguments.first ?? "goal"
        if GoalCommandLine.wantsHelp(arguments) {
            return Self.reply(code: 0, out: verb == "swarm" ? SwarmCommandLine.usage : GoalCommandLine.usage, err: nil)
        }
        guard !session.isEmpty else {
            return Self.reply(
                code: GoalExit.refused.rawValue, out: nil,
                err: "heed \(verb) on a host works in the panes heed starts there (a session, a swarm's lead or worker)"
            )
        }
        var environment = [HeedEnvironment.sessionID: session]
        if let pane { environment[HeedEnvironment.pane] = pane }
        let request: ControlRequest
        do {
            request = try GoalCommandLine.request(arguments, environment: environment, read: { _ in input ?? "" })
        } catch {
            return Self.reply(code: GoalExit.usage.rawValue, out: nil, err: "\(error)")
        }
        guard let first = await call(request) else {
            return Self.reply(code: GoalExit.unreachable.rawValue, out: nil, err: "heed \(verb): Heed did not answer")
        }
        let reply = await GoalAskWait.wait(first: first, request: request, call: call, sleep: sleep, clock: clock)
        let result = GoalCommandLine.finish(reply, json: request.goal?.json == true)
        return Self.reply(code: result.code, out: result.out, err: result.err)
    }

    /// Writes the answer where the host's `heed` waits for it (`replyPath`), over the host's shared connection.
    public static func send(_ text: String, for call: HostCall, to host: String) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-reply-\(UUID().uuidString)")
        guard (try? Data(text.utf8).write(to: file)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        let target = "\"$HOME\"/" + ShellQuote.quote(String(call.replyPath.dropFirst(2)))
        _ = try? await ProcessRunner.run(
            on: .host(host), "sh", [
                "-c",
                "mkdir -p \"$HOME/.heed/replies\" && cat > \(target).tmp && mv \(target).tmp \(target)",
            ],
            timeout: .seconds(20), input: file, caller: "hosts.call"
        )
    }

    /// The answer as the host's `heed` reads it: the exit code, then stdout and stderr, each base64 on a line.
    public static func reply(code: Int32, out: String?, err: String?) -> String {
        func encoded(_ text: String?) -> String { text.map { Data(($0 + "\n").utf8).base64EncodedString() } ?? "" }
        return "\(code)\n\(encoded(out))\n\(encoded(err))\n"
    }
}

/// A pane on a host: the command its terminal runs here.
public enum RemotePane {
    /// What the pane's terminal runs: ssh to the host and attach to the pane's zmx session there (`zmx`, its path on
    /// the
    /// host), in its worktree, with the hook environment set. When the link drops (ssh exits 255) it says so and
    /// reconnects; zmx kept the session, so the screen and scrollback come back as they were. Any other exit (the
    /// session ended) closes the pane. Without zmx on the host it is a plain login shell over ssh, which ends with the
    /// link.
    ///
    /// `command` (a new pane's agent) is the session's process, run by the host's login shell as `PaneLaunch` says
    /// and never typed into it; `shell` is that shell's syntax, which the host check found, and the part after `--` is
    /// written in it, since the host's login shell reads it. The prompt rides in the environment (`HEED_PROMPT`); the
    /// line puts `~/.heed/bin` first on the agent's PATH, for heed's `heed` there (`HostSetup.heedScript`).
    public static func command(
        host: String, pane: String, directory: String, sessionID: String, zmx: String?,
        command: ShellCommand? = nil, shell: PaneShell = .posix,
        controlDirectory: String = Remote.controlDirectory()
    ) -> String {
        let launch = command.map { command in
            var launch = PaneLaunch(command: command, shell: .login, kind: shell)
            launch.homePath = ".heed/bin"
            return launch
        }
        let environment = [
            "HEED_SESSION_ID=\(ShellQuote.quote(sessionID))", "HEED_PANE_ID=\(ShellQuote.quote(pane))",
            "HEED_BIN=\"$HOME/.heed/bin/heed-hook\"",
        ] + (launch?.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\(shell.quote($0.value))" }
        let process = launch?.commandLine(quotedFor: shell)
        let run = zmx.map { path in
            "ZMX_DIR=\"$HOME/.heed/zmx\" ZMX_NO_DETACH_KEY=1 \(Remote.word(path)) attach \(Zmx.sessionName(pane: pane))"
                + (process.map { " " + $0 } ?? "")
        } ?? process ?? "\"$SHELL\" -l"
        let remote = "cd \(Remote.word(directory)) 2>/dev/null || cd; exec env \(environment.joined(separator: " ")) \(run)"
        let ssh = (["ssh", "-t"] + Remote.options(host: host, controlDirectory: controlDirectory) + [
            Remote.target(for: host),
            "--",
            remote,
        ])
        .map(ShellQuote.quote).joined(separator: " ")
        guard zmx != nil else {
            // Nothing to come back to: when the link drops, the shell went with it.
            return "sh -c " + ShellQuote.quote("""
            \(ssh); code=$?; [ "$code" -eq 255 ] && \
            printf '\\r\\n\\033[2mheed: link to @\(
                host
            ) dropped · this session was not persistent (no zmx on the host)\\033[0m\\r\\n' && sleep 5; \
            exit "$code"
            """)
        }
        // The loop runs here: ssh's 255 means the link, not the session.
        return "sh -c " + ShellQuote.quote("""
        while :; do \(ssh); code=$?; [ "$code" -ne 255 ] && exit "$code"; \
        printf '\\r\\n\\033[2mheed: link to @\(host) dropped · reconnecting in 3s\\033[0m\\r\\n'; sleep 3; done
        """)
    }

    /// Lists the host's live heed sessions (zmx in heed's directory there).
    public static func livePanes(host: String, zmx: String) async -> Set<String> {
        guard let result = try? await ProcessRunner.run(
            on: .host(host), "sh", [
                "-c",
                "ZMX_DIR=\"$HOME/.heed/zmx\" \(Remote.word(zmx)) list --short 2>/dev/null",
            ],
            timeout: .seconds(10), caller: "hosts.zmx.list"
        ), result.succeeded else { return [] }
        return Zmx.livePanes(fromList: result.stdout)
    }

    public static func kill(panes: [String], host: String, zmx: String) async {
        guard !panes.isEmpty else { return }
        let names = panes.map(Zmx.sessionName(pane:)).joined(separator: " ")
        _ = try? await ProcessRunner.run(
            on: .host(host), "sh", [
                "-c",
                "ZMX_DIR=\"$HOME/.heed/zmx\" \(Remote.word(zmx)) kill \(names) 2>/dev/null",
            ],
            timeout: .seconds(10), caller: "hosts.zmx.kill"
        )
    }
}

public extension HostSetup {
    enum Failure: Error, CustomStringConvertible {
        case step(String, String)

        public var description: String {
            if case let .step(what, why) = self { return "\(what): \(why)" }
            return ""
        }
    }

    /// Puts what sessions need on a host: the hook, and the agents' hook files (`files`, path under ~/.heed to
    /// content). zmx is yours to install there (heed says how); heed copies nothing else. Safe to run again.
    static func install(on host: String, files: [String: String]) async throws {
        let location = Location.host(host)
        var all = files
        all["~/.heed/bin/heed-hook"] = hookScript
        all["~/.heed/bin/heed"] = heedScript
        for (path, content) in all.sorted(by: { $0.key < $1.key }) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-upload-\(UUID().uuidString)")
            try Data(content.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await ProcessRunner.run(
                on: location, "sh", ["-c", write(path, executable: path.hasPrefix(bin + "/"))], timeout: .seconds(30),
                input: file, caller: "hosts.install"
            )
            guard result.succeeded else { throw Failure.step("writing \(path)", result.stderr) }
        }
    }
}
