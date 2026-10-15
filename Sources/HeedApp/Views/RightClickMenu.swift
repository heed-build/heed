import AppKit
import HeedCore
import SwiftUI

extension View {
    /// A right-click (or ⌃-click) menu over this view. `prepare` runs first and targets the clicked thing (selects its
    /// row, as a click does); false means clicks do not reach lists now (a dialog is up) and no menu opens. The entries
    /// are built after it, so they describe the world as it is when the menu opens.
    ///
    /// The menu is AppKit's own, not SwiftUI's `.contextMenu`: a SwiftUI menu can only show a key as a real key
    /// equivalent, and heed's keys are sequences (`gd`, `⌃w c`) that no key equivalent can hold. Each item's key is
    /// drawn as text instead, right-aligned on a tab stop where macOS puts shortcuts, in the secondary label colour.
    func rightClickMenu(prepare: @escaping () -> Bool, _ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay {
            // The offscreen renderer of the docs' screenshots draws no AppKit views.
            if !ShotMode.active { RightClickArea(prepare: prepare, entries: entries) }
        }
    }
}

/// An invisible AppKit view over the SwiftUI one that takes only the right-click: every other event passes through
/// it (`hitTest` answers nil), so taps, double-clicks, hover and scrolling behave as before.
private struct RightClickArea: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let prepare: () -> Bool
    let entries: () -> [MenuEntry]

    func makeNSView(context _: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context _: Context) {
        view.model = model
        view.prepare = prepare
        view.entries = entries
    }

    final class AreaView: NSView {
        weak var model: AppModel?
        var prepare: () -> Bool = { false }
        var entries: () -> [MenuEntry] = { [] }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.opensMenu(event) else { return nil }
            return super.hitTest(point)
        }

        static func opensMenu(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }
        /// Only a ⌃-click gets here (see `hitTest`).
        override func mouseDown(with event: NSEvent) { show(event) }

        private func show(_ event: NSEvent) {
            guard let model, prepare() else { return }
            let entries = entries()
            guard entries.contains(where: { if case .item = $0 { true } else { false } }) else { return }
            NSMenu.popUpContextMenu(RightClickMenu.menu(entries, model: model), with: event, for: self)
        }
    }
}

/// The NSMenu for a list of entries: each item runs its command through the model, its key on the right.
@MainActor
enum RightClickMenu {
    static func menu(_ entries: [MenuEntry], model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        let items = entries.compactMap { if case let .item(item) = $0 { item } else { nil } }
        let keys = Dictionary(items.map { ($0.keyCommand, model.keyText(for: $0.keyCommand)) }) { first, _ in first }
        // One tab stop for the whole menu, past its widest title, so the keys line up as shortcuts do.
        let widest = items.map { width($0.title, font) }.max() ?? 0
        let widestKey = keys.values.map { width($0, font) }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: widest + 36 + widestKey)]
        for entry in entries {
            switch entry {
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case let .item(item):
                let action = Action { model.perform(item.command) }
                let menuItem = NSMenuItem(title: item.title, action: #selector(Action.run), keyEquivalent: "")
                menuItem.target = action
                // The target is weak; the item keeps the action alive.
                menuItem.representedObject = action
                menuItem.isEnabled = item.enabled
                menuItem.state = item.checked ? .on : .off
                menuItem.attributedTitle = title(
                    item.title, key: keys[item.keyCommand] ?? "", enabled: item.enabled, font: font,
                    paragraph: paragraph
                )
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    /// `Diff⇥gd`: the title as AppKit draws it (an attributed title is not greyed when disabled, so that is done
    /// here), the key in the secondary colour.
    private static func title(
        _ title: String, key: String, enabled: Bool, font: NSFont, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if !enabled { base[.foregroundColor] = NSColor.disabledControlTextColor }
        let text = NSMutableAttributedString(string: title, attributes: base)
        var keyAttributes = base
        keyAttributes[.foregroundColor] = enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        text.append(NSAttributedString(string: "\t\(key)", attributes: keyAttributes))
        return text
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private final class Action: NSObject {
        let perform: () -> Void

        init(_ perform: @escaping () -> Void) { self.perform = perform }

        @objc func run() { perform() }
    }
}
