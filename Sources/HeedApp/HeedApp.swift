import AppKit
import HeedCore
import SwiftUI

@main
struct HeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        LaunchGuard.check()
    }

    var body: some Scene {
        Window("Heed", id: "main") {
            MainWindow()
                .environment(delegate.model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { delegate.windowAppeared() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Keys are the mode engine's; the menu must not claim ⌘/ or other keys before it sees them.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `HEED_FIXTURE=<name>` (or a snapshot run) opens on a fixture domain with no IO at all; otherwise the cached
    /// domain loads in the background and git refreshes it.
    let model: AppModel = {
        let environment = ProcessInfo.processInfo.environment
        let fixture = environment["HEED_FIXTURE"] ?? (environment["HEED_SNAPSHOT"] != nil ? "main" : nil)
        if let fixture, let domain = Fixtures.named(["resume", "firstrun"].contains(fixture) ? "main" : fixture) {
            let model = AppModel(domain: domain, isFixture: true)
            if fixture == "resume" { model.showResumeForFixture() }
            if fixture == "firstrun" {
                model.showFirstRun(report: FirstRunReport(githubUser: "you", agents: [
                    .init(name: "claude", path: "/Users/you/.local/bin/claude"), .init(
                        name: "codex",
                        path: "/opt/homebrew/bin/codex"
                    ),
                    .init(name: "cursor", path: nil), .init(name: "pi", path: nil),
                    .init(name: "opencode", path: "/opt/homebrew/bin/opencode"), .init(name: "gemini", path: nil),
                ]))
            }
            return model
        }
        return AppModel(domain: .empty, isFixture: false)
    }()

    private lazy var router = KeyRouter(model: model)

    func applicationDidFinishLaunching(_: Notification) {
        // No NSApp.activate(): Heed never takes focus, it only asks for attention.
        NSApp.setActivationPolicy(.regular)
        router.start()
        if !model.isFixture {
            Task { await model.start(cache: DomainStore.defaultFile()) }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !model.isFixture else { return .terminateNow }
        Task {
            await model.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowAppeared() {
        // The window exists but may not be on screen yet when its content appears; it is the app's only window.
        guard let window = NSApp.windows.first(where: { $0.identifier == AppModel.mainWindowID })
            ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.first
        else { return }
        window.identifier = AppModel.mainWindowID
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        Snapshot.runIfRequested(window: window, model: model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
