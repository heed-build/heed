import Foundation

/// Hook messages sent while the app is not running: `heed` appends them to a file beside the socket, and the app
/// reads them on launch, in order, as if they had just arrived (each keeps its `sentAt`). Remote hosts do the same
/// with `~/.heed/events.log`; this is the Mac's own.
public enum HookSpool {
    /// The file beside `socket` (`~/Library/Application Support/Heed/hooks.spool` for the default socket).
    public static func path(forSocket socket: String) -> String {
        (socket as NSString).deletingLastPathComponent + "/hooks.spool"
    }

    /// Past this the spool takes nothing more: an app that never starts again must not fill the disk.
    public static let limit = 4 << 20

    /// Appends `lines` (complete JSON lines). One `write` with `O_APPEND`, no reading and no SQLite, so a hook stays
    /// fast. False when it could not, or the spool is full.
    @discardableResult
    public static func append(_ lines: Data, to path: String, limit: Int = limit) -> Bool {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) + lines.count <= limit else { return false }
        return lines.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == lines.count
    }

    /// Takes everything spooled, oldest first, and empties the spool. The file is moved aside before it is read, so
    /// a hook appending meanwhile starts a new one rather than being lost; one left aside by a crash is read first.
    public static func drain(_ path: String) -> [HookMessage] {
        let manager = FileManager.default
        let draining = path + ".draining"
        if !manager.fileExists(atPath: draining) {
            rename(path, draining)
        } else if let more = try? Data(contentsOf: URL(fileURLWithPath: path)), append(
            more,
            to: draining,
            limit: Int.max / 2
        ) {
            try? manager.removeItem(atPath: path)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: draining))) ?? Data()
        try? manager.removeItem(atPath: draining)
        return data.split(separator: 0x0A).compactMap { try? HookMessage.decode(line: Data($0)) }
    }
}
