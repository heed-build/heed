import AppKit
import HeedCore

/// Headless check: `HEED_SNAPSHOT=out.png Heed.app/Contents/MacOS/Heed` renders the window to a PNG and quits, so a
/// screen can be compared against design/screens without anyone looking. `HEED_SNAPSHOT_KEYS="?"` types keys first
/// (vim notation), e.g. to snapshot the help overlay or a split. Snapshots open on the `main` fixture unless
/// `HEED_FIXTURE` names another; `HEED_FIXTURE=live` uses the real cache and git.
enum Snapshot {
    @MainActor
    static func runIfRequested(window: NSWindow, host: ModelHost) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HEED_SNAPSHOT"] else { return }
        // HEED_SNAPSHOT_SIZE=900x700 checks narrow layouts; the default is the design boards' size.
        let size = (environment["HEED_SNAPSHOT_SIZE"] ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrame(
            NSRect(x: 0, y: 0, width: size.first ?? 1440, height: size.count > 1 ? size[1] : 900), display: true
        )
        Task { @MainActor in
            // HEED_SNAPSHOT_DELAY (ms) gives a live run time to load and refresh before the keys and the capture.
            let delay = Int(environment["HEED_SNAPSHOT_DELAY"] ?? "") ?? 400
            try? await Task.sleep(for: .milliseconds(delay))
            if let keys = environment["HEED_SNAPSHOT_KEYS"] {
                for stroke in (try? KeyNotation.parse(keys)) ?? [] {
                    _ = host.current.handle(stroke)
                }
                // HEED_SNAPSHOT_SETTLE (ms) waits after the keys, for what they start (a git lookup, a fetch).
                try? await Task.sleep(for: .milliseconds(Int(environment["HEED_SNAPSHOT_SETTLE"] ?? "") ?? 300))
            }
            write(window: window, to: path)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func write(window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
