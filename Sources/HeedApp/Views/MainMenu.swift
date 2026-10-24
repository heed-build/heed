import AppKit
import HeedCore

/// The menu bar's File, Session, View, PR, Go, Window and Help, from `MenuBar`: every command, its key drawn beside it
/// as text, as in the right-click menus (`RightClickMenu`). SwiftUI keeps the menus it makes (File, Edit, View, Window,
/// Help, with Close, Copy, Full Screen and the window list); heed's items go at the top of those, and Session, PR and
/// Go are menus of their own before Window.
///
/// The items are rebuilt each time the menu bar opens, from the world as it is then, so a title, check mark or greyed
/// item is never stale. None has a key equivalent but Start work's ⌘N: heed's keys are the mode engine's.
@MainActor
final class MainMenu {
    static let shared = MainMenu()

    private static let ours = NSUserInterfaceItemIdentifier("heed.menubar")
    private var host: ModelHost?
    private var observer: NSObjectProtocol?

    func install(host: ModelHost) {
        self.host = host
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The menu bar itself, not one of the menus that open from it or a right-click.
            let tracked = (note.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let tracked, tracked == NSApp.mainMenu.map(ObjectIdentifier.init) else { return }
                self?.rebuild()
            }
        }
    }

    /// Takes out what the last rebuild put in, and puts in the menus as they are now.
    func rebuild() {
        guard let main = NSApp.mainMenu, let model = host?.current else { return }
        for spec in MenuBar.menus(model.menuBarFacts()) {
            let target = menu(titled: spec.title, in: main)
            for item in target.items where item.identifier == Self.ours {
                target.removeItem(item)
            }
            let built = RightClickMenu.menu(spec.entries, model: model, menuBar: true)
            var items = built.items
            built.removeAllItems()
            if spec.title == "File", let start = items.first(where: { Self.runs($0, "work.start") }) {
                // ⌘N, the one key equivalent: the Mac's "new" is heed's start work. KeyRouter hands it to the menu.
                start.keyEquivalent = "n"
                start.keyEquivalentModifierMask = .command
                start.attributedTitle = nil
                start.title = "Start work…"
            }
            if spec.title == "Help" {
                let docs = NSMenuItem(title: "Heed documentation", action: #selector(Link.open), keyEquivalent: "")
                let link = Link(MenuBar.docsURL)
                docs.target = link
                docs.representedObject = link
                items += [.separator(), docs]
            }
            if target.items.contains(where: { !$0.isSeparatorItem }) { items.append(.separator()) }
            for (index, item) in items.enumerated() {
                item.identifier = Self.ours
                target.insertItem(item, at: index)
            }
        }
    }

    private static func runs(_ item: NSMenuItem, _ command: String) -> Bool {
        (item.representedObject as? RightClickMenu.Action)?.command == command
    }

    private static let order = ["File", "Edit", "View", "Session", "PR", "Go", "Window", "Help"]

    /// The menu bar's menu with this title: SwiftUI's, or one of heed's own, made in its place when missing.
    private func menu(titled title: String, in main: NSMenu) -> NSMenu {
        if title == "Window", let windows = NSApp.windowsMenu { return windows }
        if title == "Help", let help = NSApp.helpMenu { return help }
        if let existing = main.items.first(where: { $0.submenu?.title == title })?.submenu { return existing }
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        // Before the first menu that comes after it (Session before PR, both before Window).
        let later = Self.order.drop { $0 != title }.dropFirst()
        let index = main.items.firstIndex { later.contains($0.submenu?.title ?? "") }
        main.insertItem(item, at: index ?? main.items.count)
        if title == "Help" { NSApp.helpMenu = menu }
        if title == "Window" { NSApp.windowsMenu = menu }
        return menu
    }

    private final class Link: NSObject {
        let url: String

        init(_ url: String) { self.url = url }

        @objc func open() {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
    }
}
