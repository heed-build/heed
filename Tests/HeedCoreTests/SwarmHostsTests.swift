import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A host that is never reached: every command `ProcessRunner.run(on:)` would send over ssh comes here instead, is
/// recorded (with what would go on its stdin), and answers by the first rule its command line matches.
private final class FakeHost: Sendable {
    struct Call: Sendable, Equatable {
        var host: String
        var line: [String]
        var input: String?
    }

    private let calls = Mutex<[Call]>([])
    private let rules: [(match: String, result: ProcessResult)]

    init(_ rules: [(String, ProcessResult)] = []) {
        self.rules = rules.map { (match: $0.0, result: $0.1) }
    }

    var recorded: [Call] { calls.withLock { $0 } }

    var runner: HostRunner {
        { [self] host, executable, arguments, input in
            let line = [executable] + arguments
            let text = input.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            calls.withLock { $0.append(Call(host: host, line: line, input: text)) }
            let joined = line.joined(separator: " ")
            return rules.first { joined.contains($0.match) }?.result ?? ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }

    static func ok(_ out: String = "") -> ProcessResult { ProcessResult(status: 0, stdout: out, stderr: "") }
    static let failed = ProcessResult(status: 1, stdout: "", stderr: "fatal: not a git repository")
}

private let devboxRecord = RepoRecord(
    repo: Repo(org: "acme", name: "docs-toolkit"), path: "/home/you/code/docs-toolkit", defaultBranch: "main",
    location: .host("devbox")
)

struct SwarmPlaceTests {
    private let hosts = ["devbox", "lab"]

    @Test func aTaskRunsWhereItSaysElseWhereTheSwarmRuns() {
        let here = SwarmSettings()
        let there = SwarmSettings(host: "devbox")
        let plain = SwarmTask(id: "g/a", title: "A", phase: "P")
        var onLab = plain
        onLab.host = "lab"
        var onMac = plain
        onMac.host = SwarmPlace.local
        #expect(SwarmPlace.location(of: plain, swarm: here) == .local)
        #expect(SwarmPlace.location(of: plain, swarm: there) == .host("devbox"))
        #expect(SwarmPlace.location(of: onLab, swarm: here) == .host("lab"))
        #expect(SwarmPlace.location(of: onMac, swarm: there) == .local)
        #expect(SwarmPlace.location(of: nil, swarm: there) == .host("devbox"))
        #expect(SwarmPlace.hosts(there, tasks: [plain, onLab, onMac]) == ["devbox", "lab"])
        #expect(SwarmPlace.hosts(here, tasks: [plain, onMac]).isEmpty)
        // An empty host is no host.
        #expect(SwarmSettings(host: "").host == nil)
        #expect(SwarmTask(id: "g/a", title: "A", phase: "P", host: "").host == nil)
    }

    @Test func placesAreReadAsTyped() {
        #expect(SwarmPlace.parse("@devbox", hosts: hosts) == .success("devbox"))
        #expect(SwarmPlace.parse(" lab ", hosts: hosts) == .success("lab"))
        for word in ["local", "this Mac", "mac", "here", "@local"] {
            #expect(SwarmPlace.parse(word, hosts: hosts) == .success(SwarmPlace.local), "\(word)")
        }
        for word in ["", "-", "swarm", "default"] {
            #expect(SwarmPlace.parse(word, hosts: hosts) == .success(nil), "\(word)")
        }
        #expect(SwarmPlace.parse("gpu", hosts: hosts) == .failure(.init("no host @gpu (@devbox, @lab)")))
        #expect(SwarmPlace.parse("gpu", hosts: []) == .failure(.init("no host @gpu (no hosts yet: gH adds one)")))
        // Without config (the lead's JSON): any name.
        #expect(SwarmPlace.parse("gpu") == .success("gpu"))
    }

    @Test func aHostMustAnswerAndSayWhereItsHomeIs() {
        let configured = ["devbox": HostConfig(name: "devbox")]
        func connected(home: String?) -> HostStatus {
            .connected(HostInfo(
                latency: .milliseconds(5), platform: "Linux x86_64", git: "2.46.0", zmx: "0.8.1", agents: ["claude"],
                home: home
            ))
        }
        #expect(SwarmPlace.problem(.local, hosts: [:], statuses: [:]) == nil)
        #expect(SwarmPlace.problem(.host("gpu"), hosts: configured, statuses: [:]) == "no host @gpu in config.toml")
        #expect(SwarmPlace.problem(.host("devbox"), hosts: configured, statuses: [:])
            == "@devbox does not answer: gH shows why")
        #expect(SwarmPlace.problem(
            .host("devbox"), hosts: configured, statuses: ["devbox": .offline(reason: "x", lastSeen: nil)]
        ) == "@devbox does not answer: gH shows why")
        #expect(SwarmPlace.problem(.host("devbox"), hosts: configured, statuses: ["devbox": connected(home: nil)])?
            .contains("home") == true)
        #expect(SwarmPlace.problem(
            .host("devbox"), hosts: configured, statuses: ["devbox": connected(home: "/home/you")]
        ) == nil)
    }

    @Test func goalDocOnAHostIsReadThroughHeedGoalShow() {
        #expect(SwarmPlace.doc("~/x/GOAL.md", at: .local) == "~/x/GOAL.md")
        #expect(SwarmPlace.doc("~/x/GOAL.md", at: .host("devbox")).contains("heed goal show"))
    }

    @Test func storedRunsAndWorkersFromBeforeHostsReadAsThisMac() throws {
        let settings = try JSONDecoder().decode(SwarmSettings.self, from: Data("""
        {"repos": ["acme/docs-toolkit"], "lead": {"agent": "claude"}, "workers": [],
         "limits": {"agents": 2, "hours": 1, "dollars": 10}, "autonomy": "planChanges"}
        """.utf8))
        #expect(settings.host == nil)
        #expect(settings.location == .local)
        var there = settings
        there.host = "devbox"
        let again = try JSONDecoder().decode(SwarmSettings.self, from: JSONEncoder().encode(there))
        #expect(again.host == "devbox")

        let task = try JSONDecoder().decode(SwarmTask.self, from: Data("""
        {"id": "g/a", "title": "A", "phase": "P", "after": [], "doneWhen": []}
        """.utf8))
        #expect(task.host == nil)
        // A task with no host stores none, so plans written before read the same.
        #expect(try !String(decoding: JSONEncoder().encode(task), as: UTF8.self).contains("host"))

        let worker = try JSONDecoder().decode(SwarmWorker.self, from: Data("""
        {"id": "w", "task": "g/a", "owner": {"agent": "claude"}, "host": "s1", "repo": "acme/docs-toolkit",
         "branch": "swarm/g/a", "base": "main", "worktree": "/w", "startedAt": 0}
        """.utf8))
        #expect(worker.machine == nil)
        #expect(worker.location == .local)
        var remote = worker
        remote.machine = "devbox"
        #expect(remote.location == .host("devbox"))
    }

    @Test func movingATaskToAnotherMachineIsASmallChange() {
        let before = [SwarmTask(id: "g/a", title: "A", phase: "P"), SwarmTask(id: "g/b", title: "B", phase: "P")]
        var after = before
        after[1].host = "devbox"
        #expect(SwarmPlan.classify(old: before, new: after) == .small)
        #expect(SwarmPlan.diff(old: before, new: after) == [.changed(old: before[1], new: after[1], fields: [.host])])
        let lines = SwarmPlan.lines(old: before, new: after).map(\.text)
        #expect(lines.contains("runs on: where the swarm runs"))
        #expect(lines.contains("runs on: @devbox"))
        var local = after
        local[1].host = SwarmPlace.local
        #expect(SwarmPlan.lines(old: after, new: local).map(\.text).contains("runs on: this Mac"))
    }

    @Test func planMdAndPlanShowSayWhereTasksRun() {
        var task = SwarmTask(id: "g/a", title: "Profile the build", phase: "Spike", host: "devbox")
        let swarm = GoalSwarm(
            id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(host: "lab"), plan: 1,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let version = SwarmPlanVersion(
            swarm: swarm.id, goal: "g", number: 1, at: Date(timeIntervalSince1970: 0), author: .lead, note: "",
            tasks: [task]
        )
        let markdown = SwarmPlan.render(version, swarm: swarm, goalTitle: "Faster builds")
        #expect(markdown.contains("on @lab"))
        #expect(markdown.contains("(`a`) · on @devbox"))
        let view = SwarmPlanView(SwarmBoard(swarm: swarm, versions: [version]))
        #expect(view.host == "lab")
        #expect(view.tasks.first?.host == "devbox")
        #expect(view.text.contains("· on @lab"))
        #expect(view.text.contains("on @devbox"))
        task.host = SwarmPlace.local
        let mac = SwarmPlanView(SwarmBoard(swarm: swarm, versions: [SwarmPlanVersion(
            swarm: swarm.id, goal: "g", number: 1, at: Date(timeIntervalSince1970: 0), author: .lead, note: "",
            tasks: [task]
        )]))
        #expect(mac.text.contains("on this Mac"))
    }

    @Test func theLeadsPlanNamesAHostPerTask() throws {
        let input = try SwarmPlanInput.parse("""
        [{"title": "Profile", "phase": "Spike", "host": "@devbox"},
         {"title": "Fix", "host": "local"},
         {"title": "Ship"}]
        """, goal: "g")
        #expect(input.tasks.map(\.host) == ["devbox", SwarmPlace.local, nil])
        #expect(throws: SwarmPlanInput.ParseError.self) {
            try SwarmPlanInput.parse(#"[{"title": "Profile", "host": 3}]"#, goal: "g")
        }
    }

    @Test func thePlanEditorReadsTheHost() throws {
        let tasks = [SwarmTask(id: "g/a", title: "A", phase: "P", host: "devbox")]
        let form = SwarmTaskForm(tasks[0], in: tasks)
        #expect(form.host == "devbox")
        #expect(try form.task(id: "g/a", in: tasks, hosts: hosts).get().host == "devbox")
        var typed = form
        typed.host = "this mac"
        #expect(try typed.task(id: "g/a", in: tasks, hosts: hosts).get().host == SwarmPlace.local)
        typed.host = ""
        #expect(try typed.task(id: "g/a", in: tasks, hosts: hosts).get().host == nil)
        typed.host = "gpu"
        #expect(throws: SwarmTaskForm.Problem.self) { try typed.task(id: "g/a", in: tasks, hosts: hosts).get() }
    }

    @Test func aHostsWorktreeIsReadLessOften() {
        #expect(FileActivityPolling.interval(for: .local) == FileActivityPolling.interval)
        #expect(FileActivityPolling.interval(for: .host("devbox")) == FileActivityPolling.hostInterval)
        #expect(FileActivityPolling.hostInterval > FileActivityPolling.interval)
        let now = Date(timeIntervalSince1970: 1000)
        let last = now.addingTimeInterval(-90)
        #expect(FileActivityPolling.due(last: last, now: now, interval: FileActivityPolling.interval(for: .local)))
        #expect(!FileActivityPolling.due(
            last: last, now: now, interval: FileActivityPolling.interval(for: .host("devbox"))
        ))
    }

    @Test func theTaskMenuOffersTheOtherPlaces() {
        let menu = ContextMenus.swarmTask(
            id: "g/a", title: "A", first: true, last: true, active: true, hosts: ["devbox", "lab"], host: "devbox"
        )
        let items = menu.compactMap { entry -> MenuItem? in if case let .item(item) = entry { item } else { nil } }
        let hostItems = items.filter { $0.command.name == "swarm.task.host" }
        #expect(hostItems.map(\.command.arguments) == [["lab"], [SwarmPlace.local], ["-"]])
        let none = ContextMenus.swarmTask(id: "g/a", title: "A", first: true, last: true, active: true)
        #expect(!none
            .contains { if case let .item(item) = $0 { item.command.name == "swarm.task.host" } else { false } })
        var context = CompletionContext()
        context.hosts = ["devbox"]
        let words = CommandCompletions.arguments(for: "swarm.task.host", context).map(\.value)
        #expect(words == ["local", "-", "devbox"])
    }
}

/// A worker on a host, against `FakeHost`: nothing leaves this Mac.
struct SwarmRemoteWorkerTests {
    private let path = "~/code/wt/heed/docs-toolkit/swarm-g-profile"

    @Test func aWorkersWorktreeIsMadeOnItsHostAfterHeedsFilesGoThere() async throws {
        let fake = FakeHost([
            // No worktree there yet: `rev-parse` in it fails; the new one's top level is its real path.
            (
                "-C \(path) rev-parse --show-toplevel",
                FakeHost.ok("/home/you/code/wt/heed/docs-toolkit/swarm-g-profile\n")
            ),
            ("worktree add", FakeHost.ok()),
        ])
        let checked = Mutex(false)
        // The first look at the path finds nothing; after `worktree add` it is there.
        let runner: HostRunner = { host, executable, arguments, input in
            if arguments.last == "--show-toplevel", !checked.withLock({ $0 }) {
                checked.withLock { $0 = true }
                _ = try await fake.runner(host, executable, arguments, input)
                return FakeHost.failed
            }
            return try await fake.runner(host, executable, arguments, input)
        }
        let made = try await ProcessRunner.$hostRunner.withValue(runner) {
            try await SwarmWorktree.make(
                devboxRecord, path: path, branch: "swarm/g/profile", base: "main", keptBase: "old",
                hostFiles: HostSetup.integration(home: "/home/you").files
            )
        }
        #expect(made.path == "/home/you/code/wt/heed/docs-toolkit/swarm-g-profile")
        #expect(!made.reused)
        #expect(made.base == "main")
        let calls = fake.recorded
        #expect(calls.allSatisfy { $0.host == "devbox" })
        // heed's files first: the hook, heed's `heed` for `heed goal`, the agents' hook settings.
        let writes = calls.prefix { $0.line.first == "sh" }
        let written = writes.compactMap { $0.line.last }
        #expect(written.contains { $0.contains(".heed/bin/heed.tmp") && $0.contains("chmod +x") })
        #expect(written.contains { $0.contains(".heed/bin/heed-hook.tmp") && $0.contains("chmod +x") })
        #expect(written.contains { $0.contains(".heed/claude-hooks.json") && !$0.contains("chmod") })
        #expect(writes.contains { $0.input == HostSetup.heedScript })
        // Then the worktree, from the host's clone, under its worktree root, on the task's branch.
        let rest = calls.dropFirst(writes.count).map { $0.line.joined(separator: " ") }
        #expect(rest.contains("git -C /home/you/code/docs-toolkit fetch origin main"))
        #expect(rest.contains("mkdir -p ~/code/wt/heed/docs-toolkit"))
        // From what GitHub has (the fake's origin/main answers).
        #expect(rest.contains(
            "git -C /home/you/code/docs-toolkit worktree add -B swarm/g/profile \(path) origin/main"
        ))
        let add = try #require(rest.firstIndex { $0.contains("worktree add") })
        let firstLook = try #require(rest.firstIndex { $0.hasSuffix("rev-parse --show-toplevel") })
        #expect(firstLook < add)
    }

    @Test func aResumedTaskCarriesOnInTheWorktreeItLeftOnTheHost() async throws {
        let fake = FakeHost([
            ("rev-parse --show-toplevel", FakeHost.ok("/home/you/code/wt/heed/docs-toolkit/swarm-g-profile\n")),
        ])
        let made = try await ProcessRunner.$hostRunner.withValue(fake.runner) {
            try await SwarmWorktree.make(
                devboxRecord, path: path, branch: "swarm/g/profile", base: "main", keptBase: "swarm/g/spike"
            )
        }
        #expect(made.reused)
        #expect(made.base == "swarm/g/spike")
        #expect(made.path == "/home/you/code/wt/heed/docs-toolkit/swarm-g-profile")
        #expect(!fake.recorded.contains { $0.line.contains("worktree") })
        #expect(fake.recorded.allSatisfy { $0.host == "devbox" })
    }

    @Test func aHostThatRefusesTheFilesStopsTheStart() async {
        let fake = FakeHost([("claude-hooks.json", ProcessResult(status: 1, stdout: "", stderr: "disk full"))])
        await #expect(throws: HostSetup.Failure.self) {
            try await ProcessRunner.$hostRunner.withValue(fake.runner) {
                try await SwarmWorktree.make(
                    devboxRecord, path: path, branch: "b", base: "main",
                    hostFiles: HostSetup.integration(home: "/home/you").files
                )
            }
        }
        #expect(!fake.recorded.contains { $0.line.first == "git" })
    }

    @Test func aWorkersFilesAreReadOnItsHost() async throws {
        let fake = FakeHost([
            ("status --porcelain", FakeHost.ok(" M Sources/Anchors.swift\n?? Tests/AnchorsTests.swift\n")),
            (
                "diff --stat",
                FakeHost
                    .ok(" Sources/Anchors.swift | 12 ++++++++----\n 1 file changed, 8 insertions(+), 4 deletions(-)\n")
            ),
            ("rev-parse HEAD", FakeHost.ok("4e1c2aa\n")),
        ])
        let activity = try await ProcessRunner.$hostRunner.withValue(fake.runner) {
            try await Git.fileActivity(at: "/home/you/code/wt/x", on: .host("devbox"))
        }
        #expect(activity.files.contains("Sources/Anchors.swift"))
        #expect(activity.insertions == 8)
        #expect(fake.recorded.count == 3)
        #expect(fake.recorded.allSatisfy { $0.host == "devbox" && $0.line[0 ... 2] == [
            "git",
            "-C",
            "/home/you/code/wt/x",
        ] })
    }

    @Test func heedsFilesForAHostPointAtItsHome() {
        let (files, integration) = HostSetup.integration(home: "/home/you")
        #expect(integration.heedBinary == "/home/you/.heed/bin/heed-hook")
        #expect(integration.claudeSettings == "/home/you/.heed/claude-hooks.json")
        #expect(Set(files.keys) == ["~/.heed/claude-hooks.json", "~/.heed/heed-pi.js", "~/.heed/heed-opencode.js"])
    }

    @Test func aRemotePanePutsHeedsHeedFirstOnTheAgentsPath() {
        let command = ShellCommand(line: "claude --x")
        let line = RemotePane.command(
            host: "devbox", pane: "p1", directory: "~/code/wt/x", sessionID: "s1", zmx: "/home/you/.local/bin/zmx",
            command: command, controlDirectory: "/tmp/c"
        )
        #expect(line.contains(#"PATH=\"$HOME/.heed/bin:$PATH\"; export PATH"#)
            || line.contains(#"PATH="$HOME/.heed/bin:$PATH"; export PATH"#))
        var launch = PaneLaunch(command: command, shell: .login, kind: .fish)
        launch.homePath = ".heed/bin"
        #expect(launch.line.hasPrefix(#"set -gx PATH "$HOME/.heed/bin" $PATH"#))
        launch.kind = .posix
        #expect(launch.line.hasPrefix(#"PATH="$HOME/.heed/bin:$PATH"; export PATH"#))
        launch.homePath = nil
        #expect(!launch.line.contains(".heed/bin"))
    }
}

/// `heed goal` and `heed swarm` from a host: its `heed` writes a call to the event log, heed answers it.
struct HostCallTests {
    /// A line as `heed-hook call …` writes it: the time, session, pane, then each argument base64 and a space.
    private func line(_ arguments: [String], session: String = "s1", pane: String = "p1") -> String {
        let args = arguments.map { Data($0.utf8).base64EncodedString() + " " }.joined()
        return "1700000000\t\(session)\t\(pane)\t\(args)\t"
    }

    @Test func aCallIsReadFromItsLine() {
        let plan = #"{"tasks": [{"title": "Profile"}]}"#
        let call = HostCall(line: line([
            "call", "1700000000-42", Data(plan.utf8).base64EncodedString(), "goal", "plan", "propose", "--file",
            "plan.json",
        ]))
        #expect(call?.id == "1700000000-42")
        #expect(call?.session == "s1")
        #expect(call?.pane == "p1")
        #expect(call?.arguments == ["goal", "plan", "propose", "--file", "plan.json"])
        #expect(call?.input == plan)
        #expect(call?.replyPath == "~/.heed/replies/1700000000-42")
        // No file: the empty argument keeps its place.
        let show = HostCall(line: line(["call", "1-2", "", "goal", "show"]))
        #expect(show?.input == nil)
        #expect(show?.arguments == ["goal", "show"])
        // Not a call, a call for something else, an id that is not a file name: none.
        #expect(HostCall(line: line(["hook", "claude", "Stop"])) == nil)
        #expect(HostCall(line: line(["call", "1-2", "", "sessions"])) == nil)
        #expect(HostCall(line: line(["call", "../x", "", "goal", "show"])) == nil)
        #expect(HostCall(line: "garbage") == nil)
        // And a call is no hook message.
        #expect(HostEvents.messages(fromLine: line(["call", "1-2", "", "goal", "show"])).isEmpty)
    }

    @Test func anAnswerNobodyWaitsForIsNotSent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let show = HostCall(id: "1700000050-1", session: "s1", pane: nil, arguments: ["goal", "show"])
        #expect(!show.isStale(now: now))
        let old = HostCall(id: "1700000000-1", session: "s1", pane: nil, arguments: ["goal", "show"])
        #expect(old.isStale(now: now))
        let ask = HostCall(id: "1700000000-1", session: "s1", pane: nil, arguments: ["goal", "ask", "x?"])
        #expect(!ask.isStale(now: now))
    }

    private func decode(_ reply: String) -> (code: Int32, out: String, err: String) {
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func text(_ index: Int) -> String {
            Data(base64Encoded: lines[index]).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return (Int32(lines[0]) ?? -1, text(1), text(2))
    }

    @Test func heedAnswersAsTheCLIOnThisMacWould() async {
        let asked = Mutex<[ControlRequest]>([])
        let propose = HostCall(
            id: "1-1", session: "s1", pane: "p1", arguments: ["goal", "plan", "propose", "--file", "plan.json"],
            input: #"{"tasks": []}"#
        )
        let answered = await propose.answer(
            call: { request in
                asked.withLock { $0.append(request) }
                return ControlReply(goal: GoalReply("applied", message: "plan v1 (0 tasks)", goal: "g"))
            }, sleep: { _ in }, clock: { Date() }
        )
        let request = asked.withLock { $0.first }
        // The file came from the host, not from this Mac's disk.
        #expect(request?.goal?.text == #"{"tasks": []}"#)
        #expect(request?.session == "s1" && request?.pane == "p1")
        #expect(decode(answered).code == 0)
        #expect(decode(answered).out.contains("plan v1"))

        // Refused: on stderr, its exit code.
        let refused = await HostCall(id: "1-2", session: "s1", pane: nil, arguments: ["goal", "show"]).answer(
            call: { _ in ControlReply(goal: GoalReply("refused", exit: .refused, message: "no goal", goal: nil)) },
            sleep: { _ in }, clock: { Date() }
        )
        #expect(decode(refused).code == GoalExit.refused.rawValue)
        #expect(decode(refused).err.contains("no goal"))

        // Help is answered without asking heed; a shell heed did not start, or a wrong command line, is refused.
        let never: @Sendable (ControlRequest) async -> ControlReply? = { _ in
            Issue.record("heed was asked")
            return nil
        }
        let help = await HostCall(id: "1-3", session: "", pane: nil, arguments: ["swarm", "--help"])
            .answer(call: never, sleep: { _ in }, clock: { Date() })
        #expect(decode(help).out.contains("heed swarm"))
        let outsider = await HostCall(id: "1-4", session: "", pane: nil, arguments: ["goal", "plan", "approve"])
            .answer(call: never, sleep: { _ in }, clock: { Date() })
        #expect(decode(outsider).code == GoalExit.refused.rawValue)
        let wrong = await HostCall(id: "1-5", session: "s1", pane: nil, arguments: ["goal", "frobnicate"])
            .answer(call: never, sleep: { _ in }, clock: { Date() })
        #expect(decode(wrong).code == GoalExit.usage.rawValue)
        // Heed gone meanwhile.
        let gone = await HostCall(id: "1-6", session: "s1", pane: nil, arguments: ["goal", "show"])
            .answer(call: { _ in nil }, sleep: { _ in }, clock: { Date() })
        #expect(decode(gone).code == GoalExit.unreachable.rawValue)
    }

    @Test func anAskFromAHostWaitsHereForItsAnswer() async {
        let calls = Mutex(0)
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let ask = HostCall(id: "1-1", session: "s1", pane: "p1", arguments: ["goal", "ask", "which?", "--timeout", "1"])
        let reply = await ask.answer(
            call: { request in
                let count = calls.withLock { $0 += 1
                    return $0
                }
                if count ==
                    1 { return ControlReply(goal: GoalReply("asked", message: "asked", goal: "g", question: 7)) }
                #expect(request.goal?.question == 7)
                return ControlReply(goal: GoalReply(
                    count < 3 ? "asked" : "answered", message: count < 3 ? "asked" : "the second", goal: "g",
                    question: 7
                ))
            },
            sleep: { seconds in clock.withLock { $0 = $0.addingTimeInterval(seconds) } },
            clock: { clock.withLock { $0 } }
        )
        #expect(calls.withLock { $0 } == 3)
        #expect(decode(reply).code == 0)
        #expect(decode(reply).out.contains("the second"))
    }

    /// The host's own `heed` and hook, run here with a throwaway home: a call goes into the event log, its answer
    /// comes back out. `sh` as on a host; nothing is reached over the network.
    @Test func theHostsHeedWritesItsCallAndPrintsTheAnswer() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("heed-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".heed/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, script) in [("heed-hook", HostSetup.hookScript), ("heed", HostSetup.heedScript)] {
            let file = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let plan = home.appendingPathComponent("plan.json")
        try Data(#"{"tasks": [{"title": "Profile"}]}"#.utf8).write(to: plan)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [bin.appendingPathComponent("heed").path, "goal", "plan", "propose", "--file", plan.path]
        process.environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "HEED_SESSION_ID": "s1", "HEED_PANE_ID": "p1",
            "HEED_CALL_TIMEOUT": "20",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let log = home.appendingPathComponent(".heed/events.log")
        var call: HostCall?
        for _ in 0 ..< 100 where call == nil {
            try await Task.sleep(for: .milliseconds(100))
            call = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").first
                .flatMap { HostCall(line: String($0)) }
        }
        let found = try #require(call)
        #expect(found.session == "s1" && found.pane == "p1")
        #expect(found.arguments == ["goal", "plan", "propose", "--file", plan.path])
        #expect(found.input == #"{"tasks": [{"title": "Profile"}]}"#)
        #expect(!found.isStale(now: Date()))

        let reply = HostCall.reply(code: 1, out: "plan v2 (1 task)", err: "heed goal: and a warning")
        let replies = home.appendingPathComponent(".heed/replies")
        try Data(reply.utf8).write(to: replies.appendingPathComponent(found.id))
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "plan v2 (1 task)\n")
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            == "heed goal: and a warning\n")
        // Read once, then gone.
        #expect(!FileManager.default.fileExists(atPath: replies.appendingPathComponent(found.id).path))
    }

    @Test func theHostsHeedRunsOnlyGoalAndSwarm() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HostSetup.heedScript, "heed", "sessions"]
        process.environment = ["HOME": "/nonexistent", "PATH": "/usr/bin:/bin"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
    }
}
