import Foundation
@testable import HeedCore
import Testing

/// The shells on this machine a pane could run, with the syntax heed writes for each. A shell that is not installed is
/// left out.
private let shells: [(path: String, kind: PaneShell)] = [
    ("/bin/sh", .posix), ("/bin/bash", .posix), ("/bin/zsh", .posix), ("/bin/dash", .posix),
    ("/opt/homebrew/bin/fish", .fish), ("/usr/local/bin/fish", .fish), ("/usr/bin/fish", .fish),
].filter { FileManager.default.isExecutableFile(atPath: $0.path) }

/// Runs `line` in `shell`, with none of your own shell config, after `prelude` (shell code that defines functions).
/// `bin` goes first on PATH; `prompt` is the pane's `HEED_PROMPT`.
private func type(
    _ line: String, into shell: (path: String, kind: PaneShell), prelude: String = "", bin: String,
    environment: [String: String] = [:], prompt: String? = nil
) async throws -> ProcessResult {
    var env = environment
    env[PaneLaunch.promptVariable] = prompt
    env["PATH"] = "\(bin):/usr/bin:/bin"
    let arguments: [String] = switch shell.path {
    case let path where path.hasSuffix("fish"): ["--no-config", "-C", prelude, "-c", line]
    case let path where path.hasSuffix("zsh"): ["-f", "-c", prelude + "\n" + line]
    case let path where path.hasSuffix("bash"): ["--norc", "--noprofile", "-c", prelude + "\n" + line]
    default: ["-c", prelude + "\n" + line]
    }
    return try await ProcessRunner.run(shell.path, arguments, environment: env, timeout: .seconds(20), caller: "test")
}

/// A directory with `stubagent` (prints `bin`, `$STUB_ENV`, then each argument in brackets; with `--stdin` first, what
/// it read) and `stubheed` (prints the exit code `task-exit` reports).
private func stubs() throws -> String {
    let dir = NSTemporaryDirectory() + "heed-shell-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let agent = """
    #!/bin/sh
    printf 'bin\\n'
    printf 'env=%s\\n' "$STUB_ENV"
    if [ "$1" = --stdin ]; then shift; printf 'stdin=%s\\n' "$(cat)"; fi
    for a in "$@"; do printf '[%s]\\n' "$a"; done
    """
    let heed = "#!/bin/sh\nprintf 'reported=%s %s\\n' \"$1\" \"$2\"\n"
    for (name, script) in [("stubagent", agent), ("stubheed", heed)] {
        try script.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(dir)/\(name)")
    }
    return dir
}

/// What `stubagent` prints for `arguments` with `STUB_ENV=env`.
private func printed(_ arguments: [String], env: String = "", by who: String = "bin", stdin: String? = nil) -> String {
    "\(who)\nenv=\(env)\n" + (stdin.map { "stdin=\($0)\n" } ?? "") + arguments.map { "[\($0)]\n" }.joined()
}

/// A prompt with everything that quotes differently between shells.
private let prompt = "Fix Bob's \"anchors\" in $HOME and `pwd` $(id)\nsecond line \\ back\\\\slash \\' %self {a,b} ~ *"
private let path = "/Users/you/Library/Application Support/heed/claude-hooks.json"

private let stub: AgentProfile = {
    var agent = AgentProfile(
        name: "stub", command: "stubagent", resumeArguments: "--resume {id}", sessionIDFlag: "--session-id"
    )
    agent.modelFlag = "--model"
    return agent
}()

struct ShellCommandTests {
    @Test func shellsByName() {
        #expect(PaneShell(name: "/opt/homebrew/bin/fish") == .fish)
        #expect(PaneShell(name: "-zsh") == .posix)
        #expect(PaneShell(name: "bash") == .posix)
        #expect(PaneShell(name: nil) == .posix)
        #expect(PaneShell(name: "nu") == .other)
    }

    @Test func fishQuotesItsOwnWay() {
        #expect(PaneShell.fish.quote("it's") == #"'it\'s'"#)
        #expect(PaneShell.fish.quote(#"a\b"#) == #"'a\\b'"#)
        #expect(PaneShell.fish.quote("%self") == "'%self'")
        #expect(PaneShell.fish.quote("plain-word") == "plain-word")
        #expect(PaneShell.posix.quote("it's") == #"'it'\''s'"#)
    }

    /// Every kind of line heed types, run in each shell in that shell's syntax: the agent gets exactly the arguments
    /// and environment heed meant.
    @Test func everyLineReachesTheAgentIntactInEveryShell() async throws {
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let env = "a 'b' \"c\" $d \\e"
        let launch = stub.launchCommand(
            prompt: prompt, extraArguments: ["--settings", path], environment: ["STUB_ENV": env], model: "m'1"
        )
        var piped = stub
        piped.prompt = .stdin
        piped.command = "stubagent --stdin"
        let cases: [(name: String, command: ShellCommand, expected: String)] = try [
            ("prompt", launch, printed(["--settings", path, "--model", "m'1", prompt], env: env)),
            ("stdin", piped.launchCommand(prompt: prompt), printed([], stdin: prompt)),
            (
                "resume", #require(stub.resumeCommand(id: "a b'c", extraArguments: ["--settings", path])),
                printed(["--settings", path, "--resume", "a b'c"])
            ),
            (
                "home", ShellCommand(words: [.raw("stubagent"), .path("~/dir with space/it's"), .path("/abs")]),
                printed(["\(home)/dir with space/it's", "/abs"])
            ),
            (
                "setup", #require(WorktreeSetup.paneCommand(setup: ["printf '%s\\n' \"it's set\""], then: launch)),
                printed(["--settings", path, "--model", "m'1", prompt], env: env)
            ),
        ]
        for shell in shells {
            for test in cases {
                let line = test.command.rendered(for: shell.kind)
                #expect(!line.contains("second line"), "the prompt is never on the line: \(line)")
                let result = try await type(line, into: shell, bin: bin, prompt: test.command.prompt)
                let output = test.name == "setup"
                    ? String(result.stdout.drop { $0 != "\n" }.dropFirst())
                    .replacingOccurrences(of: "it's set\n", with: "")
                    : result.stdout
                #expect(output == test.expected, "\(test.name) in \(shell.path): \(line)\n\(result.stderr)")
            }
        }
    }

    /// The agent is whatever your shell calls by that name: a function (or alias) you defined wins over the program
    /// on PATH, and gets the environment heed sets on the line.
    /// The sign-off's arguments (claude's system prompt, codex's `-c` config) arrive as one word each, in every shell.
    @Test func theSignOffReachesTheAgentIntactInEveryShell() async throws {
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        for agent in ["claude", "codex"] {
            let extra = SignOff.arguments(agent: agent)
            let line = stub.launchCommand(prompt: "do it", extraArguments: extra)
            for shell in shells {
                let typed = line.rendered(for: shell.kind)
                let result = try await type(typed, into: shell, bin: bin, prompt: line.prompt)
                #expect(result.stdout == printed(extra + ["do it"]), "in \(shell.path): \(typed)\n\(result.stderr)")
            }
        }
    }

    @Test func theAgentIsYourShellsOwnFunction() async throws {
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let line = stub.launchCommand(prompt: "it's", extraArguments: ["--x"], environment: ["STUB_ENV": "on"])
        let behind = try #require(WorktreeSetup.paneCommand(setup: ["true"], then: line))
        for shell in shells {
            let prelude = shell.kind == .fish
                ? #"function stubagent; printf 'function\nenv=%s\n' "$STUB_ENV"; for a in $argv; printf '[%s]\n' $a; end; end"#
                : #"stubagent() { printf 'function\nenv=%s\n' "$STUB_ENV"; for a in "$@"; do printf '[%s]\n' "$a"; done; }"#
            for command in [line, behind] {
                let typed = command.rendered(for: shell.kind)
                let result = try await type(typed, into: shell, prelude: prelude, bin: bin, prompt: command.prompt)
                #expect(
                    result.stdout.hasSuffix(printed(["--x", "it's"], env: "on", by: "function")),
                    "in \(shell.path): \(typed)\n\(result.stdout)\(result.stderr)"
                )
            }
        }
    }

    /// A failed setup names the agent to run again, short and as you would type it, and stops there: neither the
    /// agent's line nor its prompt is in it.
    @Test func aFailedSetupNamesTheAgent() async throws {
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        var piped = stub
        piped.prompt = .stdin
        for agent in [stub, piped] {
            let line = agent.launchCommand(prompt: prompt, environment: ["STUB_ENV": "x"])
            let command = try #require(WorktreeSetup.paneCommand(setup: ["sh -c 'exit 3'"], then: line))
            for shell in shells {
                let result = try await type(command.rendered(for: shell.kind), into: shell, bin: bin, prompt: prompt)
                #expect(result.status == 3, "in \(shell.path): \(result.stderr)")
                #expect(result.stdout.hasSuffix(
                    "\nheed: setup failed (sh -c 'exit 3'); fix it, then run the agent again: stubagent\n"
                ), "in \(shell.path): \(result.stdout)")
                #expect(!result.stdout.contains("bin\n"))
                #expect(!command.rendered(for: shell.kind).contains("second line"))
            }
        }
    }

    /// A task's exit code reaches heed (`$HEED_BIN task-exit`), and with no heed the line still runs.
    @Test func aTaskReportsItsExitInEveryShell() async throws {
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let task = try #require(TaskSpec(name: "t", command: "stubagent task; sh -c 'exit 3'").pane(directory: "/x")
            .command)
        for shell in shells {
            let line = task.rendered(for: shell.kind)
            let reported = try await type(line, into: shell, bin: bin, environment: ["HEED_BIN": "\(bin)/stubheed"])
            #expect(reported.stdout == printed(["task"]) + "reported=task-exit 3\n", "in \(shell.path): \(line)")
            let alone = try await type(line, into: shell, bin: bin, environment: ["HEED_BIN": ""])
            #expect(alone.stdout == printed(["task"]), "in \(shell.path): \(alone.stderr)")
            #expect(alone.succeeded)
        }
    }

    /// The test above would catch heed typing sh syntax into fish.
    @Test func fishNeedsItsOwnSyntax() async throws {
        guard let fish = shells.first(where: { $0.kind == .fish }) else { return }
        let bin = try stubs()
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let line = stub.launchCommand(prompt: prompt).posix
        let result = try await type(line, into: fish, bin: bin)
        #expect(result.stdout != printed([prompt]))
    }

    /// Panes cached as an sh line still load, and keep it as it was; new ones keep the line for older versions too.
    @Test func panesKeepTheirCommandAcrossVersions() throws {
        let old = #"{"id":"p","role":"agent","title":"claude","directory":"/x","command":"claude 'it'\\''s'"}"#
        let pane = try JSONDecoder().decode(PaneSpec.self, from: Data(old.utf8))
        #expect(pane.command?.rendered(for: .fish) == #"claude 'it'\''s'"#)
        let new = PaneSpec(role: .agent, title: "a", directory: "/x", command: stub.launchCommand(prompt: "it's"))
        let data = try JSONEncoder().encode(new)
        #expect(try JSONDecoder().decode(PaneSpec.self, from: data) == new)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["command"] as? String == #"stubagent 'it'\''s'"#)
    }

    /// In sh syntax, the prompt in place, every line is byte for byte what heed typed before it kept commands as
    /// structure, but for a failed setup's hint, which names the agent now instead of repeating its line.
    @Test func shSyntaxIsUnchanged() throws {
        let env = ["OPENCODE_CONFIG_CONTENT": #"{"plugin":["file:///x y/p.js"]}"#, "A": ""]
        for agent in AgentProfile.builtIn + [stub] {
            for delivery in PromptDelivery.allCases {
                var agent = agent
                agent.prompt = delivery
                for text in ["", "go", prompt] {
                    for (plan, model) in [(false, nil), (true, "m'1"), (true, "")] {
                        let line = agent.launchCommand(
                            prompt: text, planFirst: plan, extraArguments: ["--settings", path, "-c", "a=b c"],
                            environment: env, model: model
                        )
                        let before = Legacy.launch(
                            agent, prompt: text, planFirst: plan, extra: ["--settings", path, "-c", "a=b c"],
                            environment: env, model: model
                        )
                        #expect(line.posix == before)
                        for report in [false, true] {
                            let setup = ["pnpm install", "echo \"it's\" $HOME", "uv sync"]
                            #expect(
                                WorktreeSetup.paneCommand(setup: setup, then: line, report: report)?.posix
                                    == Legacy.pane(
                                        setup: setup, then: before, agent: agent.command.split(separator: " ").first
                                            .map(String.init), report: report
                                    )
                            )
                        }
                    }
                }
            }
            for id in ["abc-123", "a b'c"] {
                #expect(
                    agent.resumeCommand(id: id, extraArguments: [path], environment: env)?.posix
                        == Legacy.resume(agent, id: id, extra: [path], environment: env)
                )
            }
        }
        #expect(WorktreeSetup.paneCommand(setup: ["npm ci"], then: nil)?.posix
            == Legacy.pane(setup: ["npm ci"], then: nil, agent: nil, report: false))
        #expect(TaskSpec(name: "t", command: "mise run 'a b'").pane(directory: "/x").command?.posix
            == #"mise run 'a b'; "${HEED_BIN:-true}" task-exit $?"#)
    }
}

/// How heed built these lines as strings before, kept to hold the sh rendering to it.
private enum Legacy {
    static func launch(
        _ agent: AgentProfile, prompt text: String, planFirst: Bool, extra: [String], environment: [String: String],
        model: String?
    ) -> String {
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(ShellQuote.quote($0.value)) " }.joined()
        var line = env + ([agent.command] + extra.map(ShellQuote.quote)).joined(separator: " ")
        if let model, !model.isEmpty, let flag = agent.modelFlag { line += " \(flag) \(ShellQuote.quote(model))" }
        if planFirst, let planArguments = agent.planArguments { line += " " + planArguments }
        guard !text.isEmpty else { return line }
        switch agent.prompt {
        case .argument: return line + " " + (agent.promptFlag.map { "\($0) " } ?? "") + ShellQuote.quote(text)
        case .stdin: return "printf '%s' \(ShellQuote.quote(text)) | " + line
        case .paste, .file: return line
        }
    }

    static func resume(_ agent: AgentProfile, id: String, extra: [String], environment: [String: String]) -> String? {
        guard let resumeArguments = agent.resumeArguments else { return nil }
        let resume = resumeArguments.replacingOccurrences(of: "{id}", with: ShellQuote.quote(id))
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(ShellQuote.quote($0.value)) " }.joined()
        return env + ([agent.command] + extra.map(ShellQuote.quote) + [resume]).joined(separator: " ")
    }

    /// As before, but for the failure's hint, which names the agent (`agent`) instead of repeating its line.
    static func pane(setup steps: [String], then command: String?, agent: String?, report: Bool) -> String? {
        let next = agent.map { "; fix it, then run the agent again: \($0)" } ?? ""
        let script = steps.map { step in
            let failed = "heed: setup failed (\(step))\(next)"
            let tell = report ? #" "${HEED_BIN:-true}" task-exit "$c";"# : ""
            let run = "printf '\\033[2mheed: setup: %s\\033[0m\\n' \(ShellQuote.quote(step)); "
                + "{ \(step); } || { c=$?; printf '\\n%s\\n' \(ShellQuote.quote(failed));\(tell) exit \"$c\"; }"
            guard let manifest = WorktreeSetup.manifest(for: step) else { return run }
            let skipped = "heed: setup: skipped \(step) (no \(manifest))"
            return "if [ -f \(manifest) ]; then \(run); "
                + "else printf '\\033[2m%s\\033[0m\\n' \(ShellQuote.quote(skipped)); fi"
        }.joined(separator: "; ")
        let setupLine = "sh -c " + ShellQuote.quote(script)
        return command.map { "\(setupLine) && \($0)" } ?? setupLine
    }
}
