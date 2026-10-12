import Foundation

/// Watches the config file's folder (editors often save by replacing the file) and reports the new source, debounced.
/// Runs on its own queue; the callback is where the caller hops to the main actor.
public final class ConfigWatcher: @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "heed.config")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable (String) -> Void

    public init(file: URL, onChange: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    /// True when `start` had to write the default file: Heed is running for the first time.
    public private(set) var createdFile = false

    /// Writes the commented default if the file does not exist yet, then starts watching. Returns the current source.
    public func start() -> String {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? ConfigLoader.defaultSource.write(to: file, atomically: true, encoding: .utf8)
            createdFile = true
        }
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ConfigLoader.defaultSource
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            onChange(text)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    /// Changes one value in place (comments and layout kept) and writes the file; the watcher then reloads it.
    public static func set(_ path: [String], to value: TOMLValue, in file: URL) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ConfigLoader.defaultSource
        let document = try TOMLDocument(text)
        try document.setting(path, to: value).write(to: file, atomically: true, encoding: .utf8)
    }
}
