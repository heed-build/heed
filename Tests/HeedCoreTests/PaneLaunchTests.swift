import Foundation
@testable import HeedCore
import Testing

/// The login shells a pane could run here; one that is not installed is left out.
private let shells: [(path: String, kind: PaneShell)] = [
    ("/bin/zsh", .posix), ("/bin/bash", .posix),
    ("/opt/homebrew/bin/fish", .fish), ("/usr/local/bin/fish", .fish), ("/usr/bin/fish", .fish),
].filter { FileManager.default.isExecutableFile(atPath: $0.path) }

private let python = "/usr/bin/python3"

/// A terminal for a process: runs `argv` with exactly `env` in a pseudo-terminal, answers the queries a shell sends at
/// startup as Ghostty does (fish 4 asks for the keyboard protocol, the version, colours, capabilities, then the device
/// attributes it waits on), and types `type` the moment the process starts, as libghostty's `initial_input` did. Once
/// `wait` exists it types `probe` every second until `probed` exists, then hangs up. Prints what the screen got, as
/// JSON.
private let terminal = #"""
import json, os, pty, select, signal, sys, time
spec = json.loads(sys.argv[1])
replies = [
    (b"\x1b[?u", b"\x1b[?0u"),
    (b"\x1b[>0q", b"\x1bP>|ghostty 1.3.2\x1b\\"),
    (b"\x1b]11;?\x1b\\", b"\x1b]11;rgb:0c0c/0d0d/0f0f\x1b\\"),
    (b"\x1b]10;?\x1b\\", b"\x1b]10;rgb:cfcf/d3d3/d8d8\x1b\\"),
    (b"\x1bP+q696e646e\x1b\\", b"\x1bP1+r696e646e=1b5b25703153\x1b\\"),
    (b"\x1bP+q71756572792d6f732d6e616d65\x1b\\", b"\x1bP1+r71756572792d6f732d6e616d65=6d61636f73\x1b\\"),
    (b"\x1b[6n", b"\x1b[1;1R"),
    (b"\x1b[0c", b"\x1b[?62;22c"),
    (b"\x1b[c", b"\x1b[?62;22c"),
]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(spec["cwd"])
    os.execve(spec["argv"][0], spec["argv"], spec["env"])
os.set_blocking(fd, False)
pending = spec.get("type", "").encode()
def push():
    global pending
    while pending:
        try:
            pending = pending[os.write(fd, pending[:1024]):]
        except BlockingIOError:
            return
out, scanned, next_probe = b"", 0, 0
end = time.time() + spec["timeout"]
push()
while time.time() < end:
    ready, _, _ = select.select([fd], [], [], 0.05)
    push()
    if ready:
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            continue
        except OSError:
            break
        if not data:
            break
        scanned = max(scanned, len(out) - 64)
        out += data
        while True:
            hits = [(out.find(q, scanned), q, a) for q, a in replies if out.find(q, scanned) >= 0]
            if not hits:
                break
            at, query, answer = min(hits)
            pending += answer
            scanned = at + len(query)
            push()
    if os.path.exists(spec["wait"]):
        if os.path.exists(spec["probed"]):
            break
        if time.time() >= next_probe:
            pending += spec["probe"].encode()
            next_probe = time.time() + 1
            push()
for sig in (signal.SIGHUP, signal.SIGKILL):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass
sys.stdout.write(json.dumps({"output": out.decode("utf-8", "replace")}))
"""#

/// A prompt with everything that quotes differently between shells, over several lines.
private let prompt = """
Fix Bob's "anchors" in $HOME and `pwd` $(id)
second line \\ back\\\\slash \\' %self {a,b} ~ * ; exec false
  indented 'third' line
"""
private let path = "/Users/you/Library/Application Support/Heed/claude-hooks.json"

private let stub = AgentProfile(name: "stub", command: "stubagent")

/// A home for one shell: your config defines `stubagent` as a function, for interactive shells only (as an alias or
/// wrapper in your config would be); `bin/stubagent` is a program of the same name on PATH. Each records who ran
/// (`function` or `bin`), then its arguments, NUL-separated, in `$HEED_TEST_OUT`, then with `--stdin` what it read.
private struct Home {
    let dir: String
    var bin: String { dir + "/bin" }
    var out: String { dir + "/out" }
    var probed: String { dir + "/probed" }

    init(for _: (path: String, kind: PaneShell)) throws {
        // Short: zmx keeps its sockets under it, and a socket path has a small limit.
        dir = "/tmp/heed-launch-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for sub in ["bin", ".config/fish", ".heed/zmx", "work"] {
            try fm.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true)
        }
        let program = """
        #!/bin/sh
        printf '%s\\0' bin "$@" > "$HEED_TEST_OUT"
        if [ "$1" = --stdin ]; then cat >> "$HEED_TEST_OUT"; fi
        """
        try program.write(toFile: "\(bin)/stubagent", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(bin)/stubagent")
        let fish = """
        if status is-interactive
            function stubagent
                printf '%s\\0' function $argv > $HEED_TEST_OUT
                if test "$argv[1]" = --stdin; cat >> $HEED_TEST_OUT; end
            end
        end
        """
        let posix = """
        stubagent() {
            printf '%s\\0' function "$@" > "$HEED_TEST_OUT"
            if [ "$1" = --stdin ]; then cat >> "$HEED_TEST_OUT"; fi
        }
        """
        try fish.write(toFile: "\(dir)/.config/fish/config.fish", atomically: true, encoding: .utf8)
        try posix.write(toFile: "\(dir)/.zshrc", atomically: true, encoding: .utf8)
        // bash reads .bash_profile as a login shell, interactive or not: the function only when interactive.
        try "case $- in *i*) \(posix) ;; esac\n".write(
            toFile: "\(dir)/.bash_profile", atomically: true, encoding: .utf8
        )
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }

    /// Nothing of yours: this home, this PATH, and `extra`.
    func environment(shell: String, _ extra: [String: String] = [:]) -> [String: String] {
        [
            "HOME": dir, "PATH": "\(bin):/usr/bin:/bin", "TERM": "xterm-256color", "SHELL": shell, "USER": "you",
            "XDG_CONFIG_HOME": dir + "/.config", "XDG_DATA_HOME": dir + "/.local/share", "ZDOTDIR": dir,
            "HEED_TEST_OUT": out, "HEED_TEST_PROBE": probed, "LANG": "en_US.UTF-8",
        ].merging(extra) { _, new in new }
    }

    /// What the agent recorded: who ran, then each argument (and what it read).
    var recorded: [String]? {
        guard let data = FileManager.default.contents(atPath: out) else { return nil }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
    }

    /// True once a login shell answered the probe.
    var shellRemained: Bool { FileManager.default.fileExists(atPath: probed) }
}

/// Typed into whatever the pane ends at: writes the probe file only from a login shell.
private func probe(_ kind: PaneShell, path: String) -> String {
    if kind == .fish { return "status is-login; and echo ok > $HEED_TEST_PROBE\n" }
    return path.hasSuffix("bash")
        ? "shopt -q login_shell && echo ok > \"$HEED_TEST_PROBE\"\n"
        : "[[ -o login ]] && echo ok > \"$HEED_TEST_PROBE\"\n"
}

/// Runs `command` (sh words) as Ghostty runs a surface's command, `bash --noprofile --norc -c 'exec -l <command>'`
/// (login(1) in front of that only sets up the session), in a terminal; returns what the screen got.
private func runInTerminal(
    _ command: String, home: Home, environment: [String: String], probe: String, type: String = ""
) async throws -> String {
    let spec: [String: Any] = [
        "argv": ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(command)"], "env": environment,
        "cwd": home.dir + "/work", "type": type, "wait": home.out, "probed": home.probed, "probe": probe,
        "timeout": 20,
    ]
    let json = try String(decoding: JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
    let result = try await ProcessRunner.run(
        python,
        ["-I", "-c", terminal, json],
        timeout: .seconds(40),
        caller: "test"
    )
    let decoded = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
    return decoded?["output"] ?? result.stderr
}

private var canRun: Bool { FileManager.default.isExecutableFile(atPath: python) }

/// zmx as you installed it, for the zmx cases; nil skips them.
private let zmx = [
    ProcessInfo.processInfo.environment["HEED_ZMX"], "/opt/homebrew/bin/zmx", "/usr/local/bin/zmx",
].compactMap(\.self).first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.serialized)
struct PaneLaunchTests {
    /// The agent's line as a pane runs it: with setup, the prompt as an argument and on stdin.
    private func commands() throws -> [(name: String, command: ShellCommand, expected: [String])] {
        var piped = stub
        piped.prompt = .stdin
        piped.command = "stubagent --stdin"
        let argument = stub.launchCommand(prompt: prompt, extraArguments: ["--settings", path])
        return try [
            ("argument", argument, ["function", "--settings", path, prompt, ""]),
            ("stdin", piped.launchCommand(prompt: prompt), ["function", "--stdin", prompt]),
            (
                "setup", #require(WorktreeSetup.paneCommand(setup: ["true"], then: argument)),
                ["function", "--settings", path, prompt, ""]
            ),
        ]
    }

    @Test func theProcessLineInEachShell() throws {
        let command = stub.launchCommand(prompt: "it's")
        let fish = PaneLaunch(command: command, shellPath: "/opt/homebrew/bin/fish")
        #expect(fish.line == "stubagent \"$HEED_PROMPT\"\nset -e HEED_PROMPT\nexec /opt/homebrew/bin/fish -l")
        #expect(fish.environment == ["HEED_PROMPT": "it's"])
        #expect(fish.commandLine(quotedFor: .posix).hasPrefix("/opt/homebrew/bin/fish -l -i -c 'stubagent"))
        let zsh = PaneLaunch(command: command, shellPath: "/bin/zsh")
        #expect(zsh.line == "stubagent \"$HEED_PROMPT\"\nunset HEED_PROMPT\nexec /bin/zsh -l")
        // A shell heed does not write the syntax of: sh runs the line, then hands over to it.
        let nu = PaneLaunch(command: command, shellPath: "/opt/homebrew/bin/nu")
        #expect(nu.commandLine(quotedFor: .posix).hasPrefix("/bin/sh -c 'stubagent"))
        #expect(nu.line.hasSuffix("exec /opt/homebrew/bin/nu -l"))
        // No prompt: nothing to carry.
        let plain = PaneLaunch(command: stub.launchCommand(prompt: ""), shellPath: "/bin/zsh")
        #expect(plain.environment.isEmpty)
        #expect(plain.line == "stubagent\nexec /bin/zsh -l")
    }

    /// The pane's process as heed builds it, run as Ghostty runs it in a terminal, in each shell: your config's
    /// function of the agent's name gets the prompt as exactly one argument, intact, and once the agent is done a login
    /// shell is left in the pane. The prompt is never on the command line.
    @Test func theAgentGetsThePromptIntactAndAShellRemains() async throws {
        guard canRun else { return }
        for shell in shells {
            for test in try commands() {
                let home = try Home(for: shell)
                defer { home.remove() }
                let launch = PaneLaunch(command: test.command, shellPath: shell.path)
                let process = launch.commandLine(quotedFor: .posix)
                #expect(!process.contains("second line"), "\(process)")
                let screen = try await runInTerminal(
                    process, home: home, environment: home.environment(shell: shell.path, launch.environment),
                    probe: probe(shell.kind, path: shell.path)
                )
                #expect(home.recorded == test.expected, "\(test.name) in \(shell.path): \(process)\n\(screen)")
                #expect(home.shellRemained, "\(test.name) in \(shell.path): no login shell after\n\(screen)")
            }
        }
    }

    /// A setup that fails says so, names the agent, and still leaves a login shell in the pane.
    @Test func aFailedSetupLeavesAShell() async throws {
        guard canRun else { return }
        let agent = stub.launchCommand(prompt: prompt)
        let command = try #require(WorktreeSetup.paneCommand(setup: ["sh -c 'exit 3'"], then: agent))
        for shell in shells {
            let home = try Home(for: shell)
            defer { home.remove() }
            // Nothing for the agent to write: the probe goes in once the setup has failed.
            FileManager.default.createFile(atPath: home.out, contents: nil)
            let launch = PaneLaunch(command: command, shellPath: shell.path)
            let screen = try await runInTerminal(
                launch.commandLine(quotedFor: .posix), home: home,
                environment: home.environment(shell: shell.path, launch.environment),
                probe: probe(shell.kind, path: shell.path)
            )
            #expect(screen.contains("heed: setup failed (sh -c 'exit 3'); fix it, then run the agent again: stubagent"))
            #expect(home.recorded == [""], "in \(shell.path): the agent ran")
            #expect(home.shellRemained, "in \(shell.path): no login shell after\n\(screen)")
        }
    }

    /// With zmx, the session's process is the same launch.
    @Test func throughZmx() async throws {
        guard canRun, let zmx else { return }
        for shell in shells {
            let home = try Home(for: shell)
            defer { home.remove() }
            let command = try #require(try commands().first)
            let launch = PaneLaunch(command: command.command, shellPath: shell.path)
            let pane = "t\(UUID().uuidString.prefix(6))"
            let environment = home.environment(shell: shell.path, launch.environment)
                .merging(Zmx.environment(socketDirectory: home.dir + "/.heed/zmx")) { _, new in new }
            let screen = try await runInTerminal(
                Zmx.attachCommand(zmx: zmx, pane: pane, launch: launch), home: home, environment: environment,
                probe: probe(shell.kind, path: shell.path)
            )
            await Zmx.kill(panes: [pane], zmx: zmx, socketDirectory: home.dir + "/.heed/zmx")
            #expect(home.recorded == command.expected, "in \(shell.path): \(screen)")
            #expect(home.shellRemained, "in \(shell.path): no login shell after\n\(screen)")
        }
    }

    /// On a host: the pane's ssh line, with an ssh that does what sshd does (runs the part after `--` with your login
    /// shell, `$SHELL -c`, where the prompt is not in the environment). The prompt crosses in that part, quoted for the
    /// host's shell; with zmx on the host and without.
    @Test func onAHost() async throws {
        guard canRun else { return }
        for shell in shells {
            for hostZmx in [nil, zmx] {
                let home = try Home(for: shell)
                defer { home.remove() }
                let ssh = """
                #!/bin/sh
                for last; do :; done
                cd "$HOME" && exec env -u HEED_PROMPT "$SHELL" -c "$last"
                """
                try ssh.write(toFile: "\(home.bin)/ssh", atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(home.bin)/ssh")
                let command = try #require(try commands().first)
                let pane = "r\(UUID().uuidString.prefix(6))"
                let process = RemotePane.command(
                    host: "box", pane: pane, directory: home.dir + "/work", sessionID: "s1", zmx: hostZmx,
                    command: command.command, shell: shell.kind, controlDirectory: home.dir
                )
                let screen = try await runInTerminal(
                    process, home: home, environment: home.environment(shell: shell.path),
                    probe: probe(shell.kind, path: shell.path)
                )
                if let hostZmx {
                    await Zmx.kill(panes: [pane], zmx: hostZmx, socketDirectory: home.dir + "/.heed/zmx")
                }
                let how = hostZmx == nil ? "no zmx" : "zmx"
                #expect(home.recorded == command.expected, "\(how), \(shell.path): \(process)\n\(screen)")
                #expect(home.shellRemained, "\(how), \(shell.path): no login shell after\n\(screen)")
            }
        }
    }
}
