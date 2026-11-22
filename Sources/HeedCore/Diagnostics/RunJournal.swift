import Foundation

/// What a launch leaves behind so the next one can tell whether it ended cleanly.
///
/// `run.json` is written at launch, refreshed by every heartbeat, and marked `clean` when Heed quits through its own
/// quit path. A file found not clean means the last run went away without that: a crash, a kill or a power loss. The
/// last heartbeat says when it was last alive and how big it had grown, and the boot time says whether the Mac
/// restarted in between.
public struct RunJournal: Codable, Equatable, Sendable {
    public var pid: Int32
    public var version: String
    public var started: Date
    public var lastBeat: Date
    public var boot: Date
    public var footprintMB: Int
    public var clean: Bool
    /// Why a clean exit happened: "quit", "SIGTERM" and so on.
    public var reason: String?

    public init(
        pid: Int32, version: String, started: Date, lastBeat: Date, boot: Date, footprintMB: Int,
        clean: Bool = false, reason: String? = nil
    ) {
        self.pid = pid
        self.version = version
        self.started = started
        self.lastBeat = lastBeat
        self.boot = boot
        self.footprintMB = footprintMB
        self.clean = clean
        self.reason = reason
    }

    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("run.json") }

    public static func read(in directory: URL) -> RunJournal? {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(RunJournal.self, from: data)
    }

    public func write(in directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.file(in: directory), options: .atomic)
    }

    /// What to say about the run found on disk when a new one starts. Nil when it ended cleanly or there was none.
    public func lostRun(rebootedSince bootNow: Date, now: Date) -> String? {
        guard !clean else { return nil }
        let silent = Int(now.timeIntervalSince(lastBeat) / 60)
        let ran = Int(lastBeat.timeIntervalSince(started) / 60)
        var text = "the previous run (pid \(pid), \(version)) did not quit cleanly: started \(RunLog.format(started)), "
            + "last alive \(RunLog.format(lastBeat)) after \(ran) min, \(footprintMB) MB then; \(silent) min passed before this launch"
        // A boot time that moved is the Mac restarting (power loss, update, kernel panic), not Heed dying.
        if abs(bootNow.timeIntervalSince(boot)) > 5 { text += "; the Mac restarted in between" }
        return text
    }
}
