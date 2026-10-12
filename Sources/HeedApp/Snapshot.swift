import AppKit
import HeedCore

/// Headless check: `HEED_SNAPSHOT=out.png Heed.app/Contents/MacOS/Heed` renders the window to a PNG and quits, so a
/// screen can be compared against design/screens without anyone looking. `HEED_SNAPSHOT_KEYS="?"` types keys first
/// (vim notation), e.g. to snapshot the help overlay or a split.
enum Snapshot {
    @MainActor
    static func runIfRequested(window: NSWindow, model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HEED_SNAPSHOT"] else { return }
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if let keys = environment["HEED_SNAPSHOT_KEYS"] {
                for stroke in (try? KeyNotation.parse(keys)) ?? [] {
                    _ = model.handle(stroke)
                }
                try? await Task.sleep(for: .milliseconds(300))
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
