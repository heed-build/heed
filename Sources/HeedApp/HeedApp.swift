import AppKit
import HeedCore
import SwiftUI

@main
struct HeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Heed", id: "main") {
            MainWindow()
                .environment(delegate.model)
                .frame(minWidth: 1100, minHeight: 640)
                .onAppear { delegate.windowAppeared() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Keys are the mode engine's; the menu must not claim ⌘1..⌘6 or ⌘/ before it sees them.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var router = KeyRouter(model: model)

    func applicationDidFinishLaunching(_: Notification) {
        // No NSApp.activate(): Heed never takes focus, it only asks for attention.
        NSApp.setActivationPolicy(.regular)
        router.start()
    }

    func windowAppeared() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        window.identifier = AppModel.mainWindowID
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        Snapshot.runIfRequested(window: window, model: model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
