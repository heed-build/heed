import Foundation

/// Where a checkpoint's download stands, as the pane shows it.
public enum HunchDownloadState: Equatable, Sendable {
    /// Nothing on disk.
    case absent
    /// Stopped part-way (cancelled, quit, offline): Download picks up where it stopped.
    case partial(done: Int64, total: Int64)
    case downloading(done: Int64, total: Int64, file: String)
    /// Checking a downloaded file's sha256.
    case verifying(file: String, done: Int64, total: Int64)
    /// Every file is there and matched its sha256.
    case ready
    /// Stopped by an error; what was fetched is kept, so Download resumes.
    case failed(String, done: Int64, total: Int64)

    public var isActive: Bool {
        switch self {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// 0…1 of the bytes, nil when there is nothing to show a bar for.
    public var fraction: Double? {
        switch self {
        case let .partial(done, total), let .downloading(done, total, _), let .verifying(_, done, total),
             let .failed(_, done, total):
            total > 0 ? min(1, Double(done) / Double(total)) : nil
        case .absent, .ready: nil
        }
    }
}

/// What one file of a checkpoint needs next, given what is in the staging directory.
public enum HunchFileStep: Equatable, Sendable {
    /// There and matched its sha256.
    case done
    /// Complete, not yet checked.
    case verify
    /// Fetch from this byte on (0: from the start).
    case fetch(from: Int64)
    /// Larger than it should be: start it again.
    case restart
}

/// What a reply to a ranged request means for the partial file.
public enum HunchResume: Equatable, Sendable {
    /// 206 from where it stopped: append.
    case append
    /// The server sent the whole file (200), or no range it could serve (416): start the file again.
    case replace
    case fail(String)
}

/// The download as a plan over files, without IO: the app's downloader asks it what to do with each file, and how far
/// along the whole is. Files go to a staging directory next to the destination, are fetched with ranged requests
/// (resuming where a partial one stopped), checked against their sha256 once complete, and the staging directory
/// becomes the checkpoint's only when every file matched.
public enum HunchDownloadPlan {
    /// `staged`: the bytes of the file in the staging directory, nil when there is none; `verified`: it matched.
    public static func step(for file: HunchCheckpoint.File, staged: Int64?, verified: Bool) -> HunchFileStep {
        guard let staged, staged > 0 else { return .fetch(from: 0) }
        if staged > file.size { return .restart }
        if staged < file.size { return .fetch(from: staged) }
        return verified ? .done : .verify
    }

    /// Bytes counted as done: the staged bytes of every file, never past its size.
    public static func completed(_ checkpoint: HunchCheckpoint, staged: [String: Int64]) -> Int64 {
        checkpoint.files.reduce(0) { $0 + min($1.size, max(0, staged[$1.path] ?? 0)) }
    }

    /// The state before anything runs: absent, partial or ready.
    public static func state(_ checkpoint: HunchCheckpoint, staged: [String: Int64], verified: Set<String>)
        -> HunchDownloadState
    {
        let done = completed(checkpoint, staged: staged)
        let allVerified = checkpoint.files.allSatisfy {
            verified.contains($0.path) && step(for: $0, staged: staged[$0.path], verified: true) == .done
        }
        if allVerified { return .ready }
        return done == 0 ? .absent : .partial(done: done, total: checkpoint.totalSize)
    }

    /// The reply to a request for the bytes from `offset` on.
    public static func resume(from offset: Int64, status: Int, contentRange: String?) -> HunchResume {
        switch status {
        case 206:
            // "bytes 1000-1999/2000": it must start where the file stopped.
            guard offset > 0 else { return .replace }
            guard let start = contentRange.flatMap(rangeStart), start == offset else {
                return .fail("the server resumed from the wrong place")
            }
            return .append
        case 200: return .replace
        case 416: return .replace
        default: return .fail("HTTP \(status)")
        }
    }

    /// The first byte of a `Content-Range: bytes a-b/c` header.
    static func rangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let range = trimmed.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[range.startIndex ..< dash])
    }

    /// A finished file whose sha256 did not match is fetched again once; a second mismatch stops the download.
    public static let mismatchRetries = 1
}
