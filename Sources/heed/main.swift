// heed: what agent hooks call to tell the Heed app what they are doing.
//
// Never slows an agent down: one write to a unix socket with a short timeout, and if the app is not running the
// message is appended to a spool file the app reads on launch (`HookSpool`), with exit 0, so a hook can never fail a
// tool call or a turn.
import Foundation
import HeedCore

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

// `heed goal …`: the goal this pane's session is on, over the control socket. The app runs every change through
// GoalOps; this process only parses and prints. Exit codes in `GoalExit`.
if arguments.first == "goal" {
    if GoalCommandLine.wantsHelp(arguments) {
        print(GoalCommandLine.usage)
        exit(0)
    }
    let request: ControlRequest
    do {
        request = try GoalCommandLine.request(arguments, environment: environment)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(GoalExit.usage.rawValue)
    }
    let reply: ControlReply
    do {
        reply = try ControlClient().call(request)
    } catch {
        FileHandle.standardError.write(Data("heed goal: \(error)\n".utf8))
        exit(GoalExit.unreachable.rawValue)
    }
    let result = GoalCommandLine.finish(reply, json: request.goal?.json == true)
    if let out = result.out { print(out) }
    if let err = result.err { FileHandle.standardError.write(Data((err + "\n").utf8)) }
    exit(result.code)
}

// `heed sessions|watch|start|send|show`: the control socket, from a terminal or a script. Not a hook: no time limit.
if let verb = arguments.first, ControlCommandLine.verbs.contains(verb) {
    do {
        let request = try ControlCommandLine.parse(
            arguments, directory: FileManager.default.currentDirectoryPath
        )
        let client = try ControlClient()
        let reply = try client.call(request)
        guard reply.ok else {
            FileHandle.standardError.write(Data("heed \(verb): \(reply.error ?? "failed")\n".utf8))
            exit(1)
        }
        switch request.method {
        case .sessions:
            let table = ControlCommandLine.table(reply.sessions ?? [])
            if !table.isEmpty { print(table) }
        case .watch:
            setvbuf(stdout, nil, _IOLBF, 0)
            try FileHandle.standardOutput.write(ControlCoding.line(reply))
            while true {
                try FileHandle.standardOutput.write(ControlCoding.line(client.next()))
            }
        case .start, .send, .show, .goal:
            print(reply.session ?? "")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(2)
    }
}

// A hook must never hold up an agent: whatever happens (a stdin that never closes, a stuck socket), give up quietly.
if arguments.first != "tools", arguments.first != "cleanup" {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(3)
}

if arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" {
    print(HookCommandLine.usage)
    exit(0)
}

// `heed tools`: what the app's tool detection finds, from wherever this runs (`env -i heed tools` mimics Finder).
if arguments.first == "tools" {
    let source = (try? String(contentsOf: ConfigLoader.defaultFile(), encoding: .utf8)) ?? ""
    let settings = ConfigLoader.decode(source).config?.tools ?? ToolSettings()
    let report = await ToolDetection.detect(settings)
    print("shell   \(report.shell) (\(report.shellPath == nil ? "did not report its PATH" : "PATH read"))")
    for tool in report.tools {
        print("\(tool.name.padding(toLength: 8, withPad: " ", startingAt: 0))\(tool.path ?? "not found")"
            + [tool.version, tool.source.map { "from \($0.rawValue)" }].compactMap(\.self).map { "  \($0)" }.joined())
        if let problem = tool.problem { print("        \(problem)") }
    }
    print("PATH    \(report.pathVariable)")
    exit(report.tools.allSatisfy { $0.path != nil } ? 0 : 1)
}

// `heed cleanup runs [path]`: removes what get it green runs left behind (heed/get-it-green/*, heed/get-it-merged/*
// branches and their worktrees) in the repo at path (or here), when safe: no uncommitted changes, nothing that is not
// on the pull request's branch, and not touched in the last hour (a run may still be working).
if arguments.first == "cleanup" {
    guard arguments.dropFirst().first == "runs" else {
        print("usage: heed cleanup runs [path]")
        exit(2)
    }
    let path = arguments.dropFirst(2).first ?? FileManager.default.currentDirectoryPath
    guard let record = await Git.record(at: path) else {
        FileHandle.standardError.write(Data("heed cleanup runs: no git repo at \(path)\n".utf8))
        exit(2)
    }
    let leftovers = await RunCleanup.clean(record, live: [], untouchedFor: 3600)
    if leftovers.isEmpty { print("nothing left by runs in \(record.repo.slug)") }
    for leftover in leftovers {
        print("\(leftover.removed ? "removed" : "kept   ") \(leftover.branch)  (\(leftover.reason))")
    }
    exit(0)
}

let kinds: [HookMessage.Kind]
do {
    kinds = try HookCommandLine.parse(arguments) { FileHandle.standardInput.readDataToEndOfFile() }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

guard let session = environment[HeedEnvironment.sessionID], !session.isEmpty else {
    // Run outside a Heed pane (e.g. the agent started from another terminal): nothing to report to.
    exit(0)
}

let socketPath = environment[HeedEnvironment.socket] ?? HeedEnvironment.defaultSocketPath()
let pane = environment[HeedEnvironment.pane]
let agent = HookCommandLine.agent(arguments)
let lines = kinds.compactMap { try? HookMessage(session: session, pane: pane, kind: $0, agent: agent).encodedLine() }

func send(_ data: Data, to path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return false }
    return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
}

let data = lines.reduce(Data(), +)
if !lines.isEmpty, !send(data, to: socketPath) {
    let spool = HookSpool.path(forSocket: socketPath)
    let outcome = HookSpool.append(data, to: spool) ? "kept in \(spool) for its next launch" : "message dropped"
    FileHandle.standardError.write(Data("heed: app not reachable at \(socketPath), \(outcome)\n".utf8))
}

exit(0)
