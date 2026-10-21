import Foundation

/// Owns the persisted domain. Runs off the main actor: loading, applying and writing never touch the UI path.
///
/// Writes are coalesced: a burst of changes (a git refresh across ten repos) produces one write, a moment later.
///
/// With an event log, what happened goes there as the domain changes (`DomainEvents`), batched the same way, and
/// history and session timelines are kept there instead of in `domain.json`.
public actor DomainStore {
    public private(set) var domain: Domain
    private let file: URL?
    private var writeScheduled = false
    private let writeDelay: Duration
    private let log: EventLog?
    private var pendingLog: [EventLogWrite] = []
    private var logScheduled = false
    /// The log write in flight: the next one waits for it, so writes land in the order the domain changed.
    private var logWriting: Task<Void, Never>?

    /// `file` nil keeps everything in memory (fixtures, tests).
    public init(domain: Domain = .empty, file: URL?, log: EventLog? = nil, writeDelay: Duration = .milliseconds(250)) {
        self.domain = domain
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
            case let .success(domain):
                try? data.write(to: previousFile(of: file), options: .atomic)
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

    public func apply(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        if log != nil {
            pendingLog += DomainEvents.apply(changes, to: &domain, now: Date())
            scheduleLogWrite()
        } else {
            for change in changes {
                domain.apply(change)
            }
        }
        scheduleWrite()
    }

    public func apply(_ change: DomainChange) { apply([change]) }

    /// Writes the domain now, and the event log, e.g. on quit.
    public func flushAll() async {
        flush()
        await flushLog()
    }

    /// Writes the domain now.
    public func flush() {
        writeScheduled = false
        guard let file else { return }
        let cached = CachedDomain(version: CachedDomain.currentVersion, domain: log == nil ? domain : domain.leavingLog)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder.heed.encode(cached).write(to: file, options: .atomic)
        } catch {
            NSLog("heed: could not write \(file.path): \(error)")
        }
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

    private func scheduleWrite() {
        guard file != nil, !writeScheduled else { return }
        writeScheduled = true
        let delay = writeDelay
        Task {
            try? await Task.sleep(for: delay)
            self.flush()
        }
    }
}

extension Domain {
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
