import Foundation

/// Owns the persisted domain. Runs off the main actor: loading, applying and writing never touch the UI path.
///
/// Writes are coalesced: a burst of changes (a git refresh across ten repos) produces one write, a moment later.
public actor DomainStore {
    public private(set) var domain: Domain
    private let file: URL?
    private var writeScheduled = false
    private let writeDelay: Duration

    /// `file` nil keeps everything in memory (fixtures, tests).
    public init(domain: Domain = .empty, file: URL?, writeDelay: Duration = .milliseconds(250)) {
        self.domain = domain
        self.file = file
        self.writeDelay = writeDelay
    }

    /// `~/Library/Application Support/Heed/domain.json`.
    public static func defaultFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/domain.json")
    }

    /// Reads the cached domain. A missing or unreadable cache starts empty: it is a cache, never a source of truth
    /// that can block startup.
    public static func load(from file: URL) async -> Domain {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return Domain.empty }
            return (try? JSONDecoder.heed.decode(CachedDomain.self, from: data))
                .flatMap { $0.version == CachedDomain.currentVersion ? $0.domain : nil } ?? .empty
        }.value
    }

    public func apply(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            domain.apply(change)
        }
        scheduleWrite()
    }

    public func apply(_ change: DomainChange) { apply([change]) }

    /// Writes now, e.g. on quit.
    public func flush() {
        writeScheduled = false
        guard let file else { return }
        let cached = CachedDomain(version: CachedDomain.currentVersion, domain: domain)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder.heed.encode(cached).write(to: file, options: .atomic)
        } catch {
            NSLog("heed: could not write \(file.path): \(error)")
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

/// The cache file: the domain plus a version, so a format change starts fresh instead of failing to decode.
struct CachedDomain: Codable {
    static let currentVersion = 3
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
