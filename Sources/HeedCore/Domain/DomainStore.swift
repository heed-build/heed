import Foundation

/// Owns the persisted domain. Runs off the main actor: loading, applying and writing never touch the UI path.
///
/// Writes are coalesced: a burst of changes (a git refresh across ten repos) produces one write, a moment later.
/// A change that leaves the domain as it was writes nothing, and writes are spaced `minimumInterval` apart: the file
/// is megabytes, and a store rewriting it every few seconds for hours was what macOS flagged for excessive disk writes.
/// What a crash can lose is the last few seconds, and quitting writes at once (`flushAll`).
///
/// With an event log, what happened goes there as the domain changes (`DomainEvents`), batched the same way, and
/// history and session timelines are kept there instead of in `domain.json`.
public actor DomainStore {
    public private(set) var domain: Domain
    private var stats = Stats()
    private let file: URL?
    private var writeScheduled = false
    private let writeDelay: Duration
    private let minimumInterval: Duration
    private let quietInterval: Duration
    /// When the write now scheduled will run, and which scheduled task may run it: a change that cannot wait brings
    /// it forward, and the task it replaces then finds it has been superseded.
    private var writeAt: ContinuousClock.Instant?
    private var writeToken = 0
    private let backgroundInterval: Duration
    private var lastWrite: ContinuousClock.Instant?
    /// What each file last held, so a flush writes only the one whose part of the domain changed.
    private var writtenCore: Domain?
    private var writtenBackground: Background?
    private var lastBackgroundWrite: ContinuousClock.Instant?
    private var backgroundScheduled = false
    private let log: EventLog?
    private var pendingLog: [EventLogWrite] = []
    private var logScheduled = false
    /// The log write in flight: the next one waits for it, so writes land in the order the domain changed.
    private var logWriting: Task<Void, Never>?

    /// `file` nil keeps everything in memory (fixtures, tests).
    public init(
        domain: Domain = .empty, file: URL?, log: EventLog? = nil, writeDelay: Duration = .milliseconds(250),
        minimumInterval: Duration = .seconds(5), quietInterval: Duration = .seconds(60),
        backgroundInterval: Duration = .seconds(120)
    ) {
        self.backgroundInterval = backgroundInterval
        self.domain = domain
        self.minimumInterval = minimumInterval
        self.quietInterval = quietInterval
        self.file = file
        self.log = log
        self.writeDelay = writeDelay
    }

    /// `~/Library/Application Support/Heed/domain.json`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/domain.json")
    }

    /// Reads the cached domain. A missing cache starts empty; it never blocks startup. But sessions live only here,
    /// so nothing is thrown away: a cache that reads keeps a copy as `domain.previous.json` (the last launch's, for
    /// putting back by hand), and one that does not read is moved aside as `domain.unreadable-<time>.json` with the
    /// reason logged, instead of being overwritten by the first write.
    public static func load(from file: URL) async -> Domain {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return Domain.empty }
            switch decode(data) {
            case var .success(domain):
                try? data.write(to: previousFile(of: file), options: .atomic)
                adoptBackground(of: file, into: &domain)
                return domain
            case let .failure(reason):
                let aside = file.deletingLastPathComponent()
                    .appendingPathComponent("domain.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: aside)
                NSLog("heed: could not read \(file.path) (\(reason)); kept it as \(aside.lastPathComponent)")
                return Domain.empty
            }
        }.value
    }

    /// `~/Library/Application Support/Heed/domain.background.json`: what changes with syncs and runs, not with what
    /// you do (`Background`), so a session's next tool call does not rewrite it.
    public static func backgroundFile(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("domain.background.json")
    }

    /// Puts the background file's parts into `domain`. A core that still holds them (written before the split, or by
    /// an older build since) is newer than the file or the file is absent, and keeps them. A file that does not read
    /// is moved aside with the reason logged; GitHub's part comes back with the next sync.
    static func adoptBackground(of file: URL, into domain: inout Domain) {
        let backgroundFile = backgroundFile(of: file)
        guard domain.background == Background(), let data = try? Data(contentsOf: backgroundFile) else { return }
        do {
            let cached = try JSONDecoder.heed.decode(CachedBackground.self, from: data)
            guard cached.version == CachedBackground.currentVersion else {
                throw Unreadable.version(cached.version)
            }
            domain.adopt(cached.background)
        } catch {
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("domain.background.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: backgroundFile, to: aside)
            NSLog("heed: could not read \(backgroundFile.path) (\(error)); kept it as \(aside.lastPathComponent)")
        }
    }

    /// The cache as it was when the app last started.
    public static func previousFile(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("domain.previous.json")
    }

    enum Unreadable: Error, CustomStringConvertible {
        case version(Int)
        case format(String)

        var description: String {
            switch self {
            case let .version(found): "format version \(found), this build reads \(CachedDomain.currentVersion)"
            case let .format(error): error
            }
        }
    }

    static func decode(_ data: Data) -> Result<Domain, Unreadable> {
        do {
            let cached = try JSONDecoder.heed.decode(CachedDomain.self, from: data)
            guard cached.version == CachedDomain.currentVersion else { return .failure(.version(cached.version)) }
            return .success(cached.domain)
        } catch {
            return .failure(.format("\(error)"))
        }
    }

    /// What the store did since the last `takeStats()`: how often it wrote, and which kinds of change asked for it.
    /// The heartbeat logs it, so a store rewriting itself while nobody is there shows who keeps asking.
    public struct Stats: Sendable, Equatable {
        public var writes = 0
        public var bytes = 0
        public var changes: [String: Int] = [:]
        /// What each part of the domain weighs when encoded, largest first (taken with the stats, only if it wrote).
        public var sizes: [FieldSize] = []

        /// "12 writes, 34.5 MB; changes: sessionUpserted ×40, ...", the five most frequent kinds.
        public var summary: String {
            let top = changes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            let size = String(format: "%.1f", Double(bytes) / 1_048_576)
            let heaviest = sizes.prefix(4).map { "\($0.name) \(Self.kb($0.bytes))" }.joined(separator: ", ")
            return "\(writes) writes, \(size) MB" + (top.isEmpty ? "" : "; changes: " + top)
                + (heaviest.isEmpty ? "" : "; heaviest: " + heaviest)
        }

        private static func kb(_ bytes: Int) -> String {
            bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(bytes / 1024) KB"
        }
    }

    public struct FieldSize: Sendable, Equatable {
        public var name: String
        public var bytes: Int
    }

    /// The counts so far, and starts them again.
    public func takeStats() -> Stats {
        defer { stats = Stats() }
        var taken = stats
        if taken.writes > 0 { taken.sizes = domain.leavingLog.fieldSizes() }
        return taken
    }

    /// `quiet` marks changes that are worth keeping but not worth a rewrite of the file soon: the next tool of a
    /// working turn, a sync that found nothing new. They are written `quietInterval` after the last write, or
    /// with the next change that cannot wait.
    public func apply(_ changes: [DomainChange], quiet: Bool = false) {
        guard !changes.isEmpty else { return }
        for change in changes {
            stats.changes[Mirror(reflecting: change).children.first?.label ?? "\(change)", default: 0] += 1
        }
        let before = domain
        if log != nil {
            pendingLog += DomainEvents.apply(changes, to: &domain, now: Date())
            scheduleLogWrite()
        } else {
            for change in changes {
                domain.apply(change)
            }
        }
        // Changes that left the domain as it was (a poll that found nothing new) do not rewrite the file.
        if domain != before { scheduleWrite(quiet: quiet) }
    }

    public func apply(_ change: DomainChange, quiet: Bool = false) { apply([change], quiet: quiet) }

    /// Events that are not domain changes (what a notification did), into the log in order with the rest.
    public func log(_ events: [LoggedEvent]) {
        guard log != nil, !events.isEmpty else { return }
        pendingLog.append(.events(events))
        scheduleLogWrite()
    }

    /// Writes the domain now, and the event log, e.g. on quit.
    public func flushAll() async {
        flush()
        await flushLog()
    }

    /// Writes the domain now, both files.
    public func flush() { flush(background: .now) }

    private enum BackgroundWrite { case now, whenDue }

    /// Writes what changed since each file was last written. The core goes now; the background file, which is most
    /// of the bytes and changes with every sync, waits `backgroundInterval` after its last write unless `.now`.
    private func flush(background mode: BackgroundWrite) {
        writeScheduled = false
        writeAt = nil
        guard let file else { return }
        let perf = Perf.begin("domain.flush")
        defer { perf.end() }
        lastWrite = .now
        let persisted = log == nil ? domain : domain.leavingLog
        let core = persisted.leavingBackground
        let background = persisted.background
        var wrote = false
        if core != writtenCore {
            let cached = CachedDomain(version: CachedDomain.currentVersion, domain: core)
            if write(cached, to: file) { writtenCore = core; wrote = true }
        }
        if background != writtenBackground {
            let due = lastBackgroundWrite.map { ContinuousClock.now - $0 >= backgroundInterval } ?? true
            if mode == .now || due {
                let cached = CachedBackground(version: CachedBackground.currentVersion, background: background)
                if write(cached, to: Self.backgroundFile(of: file)) {
                    writtenBackground = background
                    lastBackgroundWrite = .now
                    wrote = true
                }
            } else {
                scheduleBackground()
            }
        }
        if wrote { stats.writes += 1 }
    }

    private func write(_ value: some Encodable, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder.heed.encode(value)
            try data.write(to: file, options: .atomic)
            stats.bytes += data.count
            return true
        } catch {
            NSLog("heed: could not write \(file.path): \(error)")
            return false
        }
    }

    private func scheduleBackground() {
        guard !backgroundScheduled, let lastBackgroundWrite else { return }
        backgroundScheduled = true
        let delay = max(.milliseconds(1), backgroundInterval - (ContinuousClock.now - lastBackgroundWrite))
        Task {
            try? await Task.sleep(for: delay)
            self.flushBackground()
        }
    }

    private func flushBackground() {
        backgroundScheduled = false
        flush(background: .whenDue)
    }

    /// Hands what is pending to the log, after the one in flight.
    public func flushLog() async {
        logScheduled = false
        let writes = pendingLog
        pendingLog = []
        let previous = logWriting
        let log = log
        let task = Task {
            await previous?.value
            guard let log, !writes.isEmpty else { return }
            await log.write(writes)
        }
        logWriting = task
        await task.value
    }

    private func scheduleLogWrite() {
        guard !logScheduled else { return }
        logScheduled = true
        let delay = writeDelay
        Task {
            try? await Task.sleep(for: delay)
            await self.flushLog()
        }
    }

    private func scheduleWrite(quiet: Bool) {
        guard file != nil else { return }
        let since = lastWrite.map { ContinuousClock.now - $0 }
        var delay = writeDelay
        if let since { delay = max(delay, (quiet ? quietInterval : minimumInterval) - since) }
        let due = ContinuousClock.now + delay
        // Already scheduled for then or sooner: nothing to bring forward.
        if writeScheduled, let writeAt, writeAt <= due { return }
        writeScheduled = true
        writeAt = due
        writeToken += 1
        let token = writeToken
        Task {
            try? await Task.sleep(for: delay)
            self.flushScheduled(token)
        }
    }

    private func flushScheduled(_ token: Int) {
        guard token == writeToken, writeScheduled else { return }
        flush(background: .whenDue)
    }
}

/// The parts of the domain that change with syncs and runs: GitHub's state and the PR details and feedback read from
/// it (all refetched by the next sync), and the logs the pilot and the merge queue keep. Together they are most of
/// the bytes of the domain, so they live in their own file, written less often than the sessions are.
struct Background: Equatable {
    var github = GitHubState()
    var pullDetails: [String: PullDetail] = [:]
    var feedback: [String: PullFeedback] = [:]
    var pilotLog: [PilotEvent] = []
    var mergeRuns: [String: [MergeRun]] = [:]
    var runs: [PilotRun] = []
    var archives: [ArchiveRef] = []
}

extension Background: Codable {}

struct CachedBackground: Codable {
    static let currentVersion = 1
    var version: Int
    var background: Background
}

extension Domain {
    var background: Background {
        Background(
            github: github, pullDetails: pullDetails, feedback: feedback, pilotLog: pilotLog, mergeRuns: mergeRuns,
            runs: runs, archives: archives
        )
    }

    /// The domain as `domain.json` keeps it: the fields of `Background` stay, empty, so an older build still reads
    /// the file (and refetches what it finds missing).
    var leavingBackground: Domain {
        var domain = self
        domain.adopt(Background())
        return domain
    }

    mutating func adopt(_ background: Background) {
        github = background.github
        pullDetails = background.pullDetails
        feedback = background.feedback
        pilotLog = background.pilotLog
        mergeRuns = background.mergeRuns
        runs = background.runs
        archives = background.archives
    }

    /// What each part encodes to, largest first: where the megabytes of `domain.json` come from.
    func fieldSizes() -> [DomainStore.FieldSize] {
        let encoder = JSONEncoder.heed
        func size(_ name: String, _ value: some Encodable) -> DomainStore.FieldSize {
            DomainStore.FieldSize(name: name, bytes: (try? encoder.encode(value).count) ?? 0)
        }
        return [
            size("repos", repos), size("worktrees", worktrees), size("sessions", sessions), size("layouts", layouts),
            size("history", history), size("github", github), size("pullDetails", pullDetails),
            size("feedback", feedback), size("pilotLog", pilotLog), size("mergeRuns", mergeRuns), size("runs", runs),
            size("registeredWorktrees", registeredWorktrees), size("archives", archives),
        ].sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    /// The domain as `domain.json` keeps it once the event log keeps history and timelines. The fields stay, empty,
    /// so an older build still reads the file.
    var leavingLog: Domain {
        var domain = self
        domain.history = []
        for index in domain.sessions.indices {
            domain.sessions[index].timeline = []
        }
        return domain
    }
}

/// The cache file: the domain plus a version, so a format change starts fresh instead of failing to decode.
struct CachedDomain: Codable {
    static let currentVersion = 6
    var version: Int
    var domain: Domain
}

extension JSONEncoder {
    static var heed: JSONEncoder {
        // Dates keep full precision (the default, seconds as a double); ISO 8601 would drop fractions.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var heed: JSONDecoder { JSONDecoder() }
}
