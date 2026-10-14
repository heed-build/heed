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
            HostedMainWindow(host: delegate.host)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { delegate.windowAppeared() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Keys are the mode engine's; the menu must not claim ⌘/ or other keys before it sees them.
            CommandGroup(replacing: .newItem) {}
            // No key equivalent: ⌘⇧T is the mode engine's, so it works from a terminal pane too.
            CommandGroup(replacing: .help) {
                Button("Heed Tutor") { delegate.host.current.perform(CommandInvocation(name: "tutor")) }
            }
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
        // Before the model reads its preferences.
        LegacyDefaults.migrate()
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

    /// What the window shows: the live model, or the tutor's sandbox while it runs.
    lazy var host: ModelHost = {
        let host = ModelHost(live: model)
        model.onTutorRequest = { [weak self] request in self?.setTutor(request) }
        return host
    }()

    private lazy var router = KeyRouter(host: host)

    /// The tutor runs on its own model over a fake world in the same window: nothing done there reaches the live
    /// sessions, which keep running (and updating the Dock and menu bar) underneath, and come back as they were.
    func setTutor(_ request: AppModel.TutorRequest) {
        switch request {
        case let .start(lesson, world):
            guard let chosen = world ?? Tutor.lesson(lesson)?.world else { return }
            let previous = host.current
            let sandbox = AppModel(domain: chosen.domain, isFixture: true)
            sandbox.onTutorRequest = { [weak self] request in self?.setTutor(request) }
            sandbox.openSettings = model.openSettings
            sandbox.reopenWindow = model.reopenWindow
            sandbox.beginTutor(lesson: lesson, world: chosen)
            host.current = sandbox
            if previous !== model { Self.closePanes(of: previous) }
        case .exit:
            let sandbox = host.current
            host.current = model
            if sandbox !== model { Self.closePanes(of: sandbox) }
        }
    }

    private static func closePanes(of model: AppModel) {
        for pane in model.layouts.values.flatMap({ $0.tabs.flatMap(\.tree.panes) }) {
            TerminalSurfaces.shared.close(paneID: pane.id)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Heed's palette is dark only. Without this, anything left to the system colours (a Text with no style, native
        // controls, Settings) follows macOS and turns black on the dark panels in light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // HEED_SHOTS: render the docs' screenshots from the fake world, then quit; nothing else starts.
        if TutorCheck.requested {
            NSApp.setActivationPolicy(.accessory)
            Task { await exit(TutorCheck.run()) }
            return
        }
        if ShotRunner.requested {
            NSApp.setActivationPolicy(.accessory)
            Task {
                await ShotRunner.run()
                exit(0)
            }
            return
        }
        // No NSApp.activate(): Heed never takes focus, it only asks for attention.
        NSApp.setActivationPolicy(.regular)
        router.start()
        if !model.isFixture {
            Task { await model.start(cache: DomainStore.defaultFile()) }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Fixtures quit at once, unless HEED_OUTSIDE has them behave like the live app outside the window.
        let outside = ProcessInfo.processInfo.environment["HEED_OUTSIDE"] != nil
        guard !model.isFixture || outside else { return .terminateNow }
        // Quitting stops every agent: with any of them running, ask first (the confirm quits again when accepted).
        guard model.quitConfirmed || !model.confirmQuitIfAgentsRun() else { return .terminateCancel }
        // From here terminals ending are the quit, not exits: sessions keep their panes for the next launch.
        model.beginTerminating()
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
        Snapshot.runIfRequested(window: window, host: host)
    }

    /// With the menu bar item, closing the window leaves Heed (and every agent in it) running; Open Heed or the
    /// activate shortcut brings it back. Without it, closing the window quits as before.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        model.isFixture || !model.config.showMenuBarItem
    }
}

/// Which model the main window, the keys and pane clicks belong to. Swapped by the tutor.
@MainActor
@Observable
final class ModelHost {
    let live: AppModel
    var current: AppModel {
        didSet { wire() }
    }

    init(live: AppModel) {
        self.live = live
        current = live
        wire()
    }

    private func wire() {
        let model = current
        TerminalSurfaces.shared.onPaneClick = { [weak model] paneID in model?.clickedPane(paneID) }
        TerminalSurfaces.shared.onPaneExited = { [weak model] paneID in model?.paneExited(paneID) }
    }
}

/// The main window for whichever model the host holds.
struct HostedMainWindow: View {
    let host: ModelHost

    var body: some View {
        MainWindow().environment(host.current)
    }
}
