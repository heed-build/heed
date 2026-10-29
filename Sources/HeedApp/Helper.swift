import AppKit
import Foundation

/// The bundled `heed` CLI, at exactly `Contents/Helpers/heed`. Never looked up with
/// `Bundle.url(forAuxiliaryExecutable:)`: that searches `Contents/MacOS` first, where on a case-insensitive disk
/// `heed` is the app itself, so hooks (and anything else running "the helper") would launch another Heed.
enum Helper {
    /// Nil when the helper is missing or is somehow the app's own executable; panes then get no `HEED_BIN` and hooks
    /// do nothing.
    static let path: String? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/heed")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        if let app = Bundle.main.executableURL, isSameFile(url, app) { return nil }
        return url.path
    }()

    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let manager = FileManager.default
        guard let left = try? manager.attributesOfItem(atPath: lhs.resolvingSymlinksInPath().path),
              let right = try? manager.attributesOfItem(atPath: rhs.resolvingSymlinksInPath().path)
        else { return false }
        return (left[.systemFileNumber] as? Int) == (right[.systemFileNumber] as? Int)
            && (left[.systemNumber] as? Int) == (right[.systemNumber] as? Int)
    }
}

/// Guards against the app ever multiplying: it only runs as the one GUI instance.
enum LaunchGuard {
    /// Quits right away when started with the CLI's arguments (something meant for `heed` reached the app), or when
    /// another Heed is already running (fixtures and snapshots excepted: they do no IO and are started on purpose).
    static func check() {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        let cliVerbs: Set = [
            "state",
            "notify",
            "pr",
            "title",
            "agent-session",
            "task-exit",
            "hook",
            "tools",
            "--help",
            "-h",
        ]
        if let first = arguments.first, cliVerbs.contains(first) { exit(0) }
        let environment = ProcessInfo.processInfo.environment
        guard environment["HEED_FIXTURE"] == nil, environment["HEED_SNAPSHOT"] == nil, environment["HEED_SHOTS"] == nil,
              environment["HEED_TUTOR_CHECK"] == nil,
              let id = Bundle.main.bundleIdentifier
        else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        // Leave without touching the running one: Heed never takes focus, even from itself.
        if !others.isEmpty { exit(0) }
    }
}
