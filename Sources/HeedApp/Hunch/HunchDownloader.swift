import CryptoKit
import Foundation
import HeedCore

/// Downloads a checkpoint into the models folder, resumably: each file goes to the staging directory with a ranged
/// request from where it stopped, is checked against its sha256 once complete, and the staging directory becomes the
/// checkpoint's only when every file matched (`HunchDownloadPlan` decides each step). Cancelling keeps what was
/// fetched; the next Download picks it up. Runs off the main actor; reports through `report`.
enum HunchDownloader {
    typealias Report = @Sendable (HunchDownloadState) async -> Void

    static func run(_ checkpoint: HunchCheckpoint, folder: HunchFolder, report: @escaping Report) async throws {
        let fileManager = FileManager.default
        let staging = folder.staging(checkpoint)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var verified = readVerified(folder.verified(checkpoint))
        let total = checkpoint.totalSize
        var mismatches: [String: Int] = [:]

        for file in checkpoint.files {
            let target = staging.appending(path: file.path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileLoop: while true {
                try Task.checkCancellation()
                let staged = size(of: target)
                let done = HunchDownloadPlan.completed(checkpoint, staged: stagedSizes(checkpoint, staging))
                switch HunchDownloadPlan.step(for: file, staged: staged, verified: verified.contains(file.path)) {
                case .done:
                    break fileLoop
                case .restart:
                    try? fileManager.removeItem(at: target)
                case let .fetch(offset):
                    await report(.downloading(done: done, total: total, file: file.path))
                    try await fetch(
                        checkpoint.url(for: file), to: target, from: offset, expected: file.size
                    ) { bytes in
                        let now = done - min(offset, file.size) + min(file.size, bytes)
                        await report(.downloading(done: now, total: total, file: file.path))
                    }
                    // A request that wrote nothing (a full disk, an empty reply) would otherwise be asked again
                    // forever.
                    if (size(of: target) ?? 0) <= offset, file.size > offset {
                        throw HunchDownloadError.http("no bytes of \(file.path) arrived")
                    }
                case .verify:
                    await report(.verifying(file: file.path, done: done, total: total))
                    let actual = try await sha256(of: target)
                    if actual == file.sha256 {
                        verified.insert(file.path)
                        writeVerified(verified, to: folder.verified(checkpoint))
                        break fileLoop
                    }
                    mismatches[file.path, default: 0] += 1
                    try? fileManager.removeItem(at: target)
                    if mismatches[file.path, default: 0] > HunchDownloadPlan.mismatchRetries {
                        throw HunchDownloadError.checksum(file.path)
                    }
                }
            }
        }

        // Every file matched: the staging directory becomes the checkpoint. Its bookkeeping stays behind.
        let destination = folder.checkpoint(checkpoint)
        try? fileManager.removeItem(at: folder.verified(checkpoint))
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            let aside = destination.deletingLastPathComponent()
                .appending(path: "\(destination.lastPathComponent).replaced-\(Int(Date().timeIntervalSince1970))")
            try fileManager.moveItem(at: destination, to: aside)
            try? fileManager.removeItem(at: aside)
        }
        try fileManager.moveItem(at: staging, to: destination)
        await report(.ready)
    }

    /// What is on disk for `checkpoint`, without IO on the caller's actor.
    static func state(_ checkpoint: HunchCheckpoint, folder: HunchFolder) -> HunchDownloadState {
        if isReady(checkpoint, folder: folder) { return .ready }
        return HunchDownloadPlan.state(
            checkpoint, staged: stagedSizes(checkpoint, folder.staging(checkpoint)),
            verified: readVerified(folder.verified(checkpoint))
        )
    }

    /// Every file of the checkpoint at its size. Files are only moved there after their sha256 matched.
    static func isReady(_ checkpoint: HunchCheckpoint, folder: HunchFolder) -> Bool {
        let directory = folder.checkpoint(checkpoint)
        return checkpoint.files.allSatisfy { size(of: directory.appending(path: $0.path)) == $0.size }
    }

    static func stagedSizes(_ checkpoint: HunchCheckpoint, _ staging: URL) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for file in checkpoint.files {
            if let size = size(of: staging.appending(path: file.path)) { sizes[file.path] = size }
        }
        return sizes
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size].flatMap { ($0 as? NSNumber)?.int64Value }
    }

    /// Bytes below `url`, recursively.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Verified files

    private static func readVerified(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    private static func writeVerified(_ files: Set<String>, to url: URL) {
        try? JSONEncoder().encode(files.sorted()).write(to: url, options: .atomic)
    }

    // MARK: One file

    /// Lowercase hex sha256, read in chunks off the caller's actor.
    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Fetches `url` into `target` from byte `offset` on: appended when the server resumes there, rewritten when it
    /// sends the whole file.
    private static func fetch(
        _ url: URL, to target: URL, from offset: Int64, expected _: Int64,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let fetcher = FileFetcher(target: target, offset: offset, progress: progress)
        try await fetcher.run(request)
    }
}

enum HunchDownloadError: Error, CustomStringConvertible {
    case checksum(String)
    case http(String)

    var description: String {
        switch self {
        case let .checksum(file): "\(file) did not match its sha256 twice"
        case let .http(reason): reason
        }
    }
}

/// One ranged GET written straight to a file as it arrives, so an interrupted one keeps what it got. Progress is the
/// file's size so far.
private final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let target: URL
    private let offset: Int64
    private let progress: @Sendable (Int64) async -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    /// Where the file stood before this request's bytes: the offset when appending, 0 when rewriting.
    private var base: Int64 = 0
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    init(target: URL, offset: Int64, progress: @escaping @Sendable (Int64) async -> Void) {
        self.target = target
        self.offset = offset
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            try? handle?.close()
            handle = nil
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let action = HunchDownloadPlan.resume(
            from: offset, status: http?.statusCode ?? 0,
            contentRange: http?.value(forHTTPHeaderField: "Content-Range")
        )
        do {
            switch action {
            case .append:
                let handle = try FileHandle(forWritingTo: target)
                try handle.seekToEnd()
                lock.withLock {
                    self.handle = handle
                    base = offset
                }
            case .replace:
                FileManager.default.createFile(atPath: target.path, contents: nil)
                let handle = try FileHandle(forWritingTo: target)
                try handle.truncate(atOffset: 0)
                lock.withLock {
                    self.handle = handle
                    base = 0
                }
            case let .fail(reason):
                completionHandler(.cancel)
                finish(.failure(HunchDownloadError.http(reason)))
                return
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        let report: Int64? = lock.withLock {
            do {
                try handle?.write(contentsOf: data)
            } catch {
                return nil
            }
            written += Int64(data.count)
            // Progress at most ten times a second.
            guard Date().timeIntervalSince(lastReport) >= 0.1 else { return nil }
            lastReport = Date()
            return base + written
        }
        if let report {
            let progress = progress
            Task { await progress(report) }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else {
            finish(.success(()))
        }
    }
}
