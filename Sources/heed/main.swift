// heed: what agent hooks call to tell the Heed app what they are doing.
//
// Never slows an agent down: one write to a unix socket with a short timeout, and if the app is not running the
// message is dropped with exit 0, so a hook can never fail a tool call or a turn.
import Foundation
import HeedCore

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" {
    print(HookCommandLine.usage)
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
let lines = kinds.compactMap { try? HookMessage(session: session, pane: pane, kind: $0).encodedLine() }

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

if !lines.isEmpty, !send(lines.reduce(Data(), +), to: socketPath) {
    FileHandle.standardError.write(Data("heed: app not reachable at \(socketPath), message dropped\n".utf8))
}

exit(0)
