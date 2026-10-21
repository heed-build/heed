import Foundation
import HeedCore

/// A host's agent events: `tail -F ~/.heed/events.log` over the shared ssh connection, each line back into a hook
/// message. It remembers how far it read (so a restart of heed or of the link picks up where it stopped, and nothing an
/// agent reported meanwhile is lost) and starts again on its own when ssh exits.
@MainActor
final class HostEventStream {
    let host: String
    private let onMessage: (HookMessage) -> Void
    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var offsetKey: String { "heed.hostEvents.offset.\(host)" }
    private var offset: Int {
        get { UserDefaults.standard.integer(forKey: offsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: offsetKey) }
    }

    init(host: String, onMessage: @escaping (HookMessage) -> Void) {
        self.host = host
        self.onMessage = onMessage
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() {
        guard !isRunning else { return }
        stopped = false
        Task { await launch() }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() async {
        // Where to start: where it stopped, unless the log is new or shorter (then from its end: old lines are old).
        let size = await (try? ProcessRunner.output(
            on: .host(host), "sh",
            [
                "-c",
                "mkdir -p \"$HOME/.heed\" && touch \"$HOME/.heed/events.log\" && wc -c < \"$HOME/.heed/events.log\"",
            ],
            timeout: .seconds(15), caller: "hosts.events"
        )).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !stopped, let size else { return retry() }
        if UserDefaults.standard.object(forKey: offsetKey) == nil || offset > size { offset = size }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Remote.sshArguments(
            host: host, command: ["sh", "-c", "exec tail -c +\(offset + 1) -F \"$HOME/.heed/events.log\" 2>/dev/null"]
        )
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.retry() }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            retry()
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            offset += line.count + 1
            for message in HostEvents.messages(fromLine: String(decoding: line, as: UTF8.self)) {
                onMessage(message)
            }
        }
    }

    private func retry() {
        process = nil
        buffer.removeAll()
        guard !stopped else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !stopped else { return }
            await launch()
        }
    }
}
