import Foundation

/// Org and user avatars from github.com, cached on disk so chips draw them at once on launch. Everything here runs
/// off the main actor; a failed download keeps the cached image (or none, and the chip keeps its letter tile).
public struct AvatarCache: Sendable {
    public let directory: URL
    /// How old a cached avatar may get before it is fetched again.
    public var maxAge: TimeInterval

    public init(directory: URL, maxAge: TimeInterval = 7 * 86400) {
        self.directory = directory
        self.maxAge = maxAge
    }

    /// `~/Library/Caches/Heed/avatars`.
    public static func `default`() -> AvatarCache {
        AvatarCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/avatars"))
    }

    public func file(for login: String) -> URL {
        directory.appendingPathComponent(login.lowercased() + ".png")
    }

    public static func url(for login: String, size: Int = 64) -> URL? {
        URL(string: "https://github.com/\(login).png?size=\(size)")
    }

    /// Cached image data, whatever its age.
    public func cached(_ login: String) -> Data? {
        try? Data(contentsOf: file(for: login))
    }

    public func isStale(_ login: String, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file(for: login).path),
              let modified = attributes[.modificationDate] as? Date
        else { return true }
        return now.timeIntervalSince(modified) > maxAge
    }

    /// Downloads and caches an avatar; returns the fresh data, or nil (keeping any cached copy) on failure.
    public func refresh(_ login: String, session: URLSession = .shared) async -> Data? {
        guard let url = Self.url(for: login) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: login), options: .atomic)
            return data
        } catch {
            return nil
        }
    }
}
