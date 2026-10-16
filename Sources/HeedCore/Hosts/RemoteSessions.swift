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

/// A pane on a host: the command its terminal runs here.
public enum RemotePane {
    /// What the pane's terminal runs: ssh to the host and attach to the pane's zmx session there (`zmx`, its path on
    /// the
    /// host), in its worktree, with the hook environment set. When the link drops (ssh exits 255) it says so and
    /// reconnects; zmx kept the session, so the screen and scrollback come back as they were. Any other exit (the
    /// session ended) closes the pane. Without zmx on the host it is a plain login shell over ssh, which ends with the
    /// link.
    public static func command(
        host: String, pane: String, directory: String, sessionID: String, zmx: String?,
        controlDirectory: String = Remote.controlDirectory()
    ) -> String {
        let environment = [
            "HEED_SESSION_ID=\(ShellQuote.quote(sessionID))", "HEED_PANE_ID=\(ShellQuote.quote(pane))",
            "HEED_BIN=\"$HOME/.heed/bin/heed-hook\"",
        ]
        let run = zmx.map { path in
            "ZMX_DIR=\"$HOME/.heed/zmx\" ZMX_NO_DETACH_KEY=1 \(Remote.word(path)) attach \(Zmx.sessionName(pane: pane))"
        } ?? "\"${SHELL:-/bin/sh}\" -l"
        let remote = "cd \(Remote.word(directory)) 2>/dev/null || cd; exec env \(environment.joined(separator: " ")) \(run)"
        let ssh = (["ssh", "-t"] + Remote.options(controlDirectory: controlDirectory) + [
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
            timeout: .seconds(10)
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
            timeout: .seconds(10)
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
        for (path, content) in all.sorted(by: { $0.key < $1.key }) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-upload-\(UUID().uuidString)")
            try Data(content.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await ProcessRunner.run(
                on: location, "sh", ["-c", write(path, executable: path.hasSuffix("heed-hook"))], timeout: .seconds(30),
                input: file
            )
            guard result.succeeded else { throw Failure.step("writing \(path)", result.stderr) }
        }
    }
}
