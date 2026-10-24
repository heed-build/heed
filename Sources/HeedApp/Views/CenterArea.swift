import AppKit
import HeedCore
import SwiftUI

/// Tabs and the focused tab's split panes.
struct CenterArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TabStrip().shotRegion(.tabStrip)
            if let tab = model.currentTab {
                Group {
                    if tab.zoomed, let pane = tab.tree.panes.first(where: { $0.id == tab.focused }) {
                        PaneView(pane: pane, number: (tab.tree.panes.firstIndex(of: pane) ?? 0) + 1, tab: tab)
                    } else {
                        PaneTreeView(tree: tab.tree, tab: tab)
                    }
                }
                .shotRegion(.panes)
                // A pane's terminal must survive re-layout (splits, zoom); identity is the pane id, not position.
                .id(tab.id)
            } else {
                EmptyCenter()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pane)
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    /// Each tab's width as drawn, for working out where a dragged tab lands.
    @State private var widths: [String: Double] = [:]
    /// The tab being dragged and how far, while it is.
    @State private var dragging: (id: String, offset: Double)?

    var body: some View {
        let tabs = model.currentTabs
        let strip = tabs.map { widths[$0.id] ?? 0 }
        let dragIndex = dragging.flatMap { drag in tabs.firstIndex { $0.id == drag.id } }
        let target = dragIndex.map { TabDrag.target(dragging: $0, by: dragging?.offset ?? 0, widths: strip) }
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let on = index == model.currentTabIndex
                HStack(spacing: 8) {
                    if index == 0, let session = model.currentSession {
                        StateGlyph(state: session.state.state, guessed: session.state.source == .guessed, size: 11)
                    } else if let helper = tab.tree.panes.first(where: { $0.role == .helper }) {
                        // A get it green / get it merged run: its own agent's state.
                        StateGlyph(state: model.runStates[helper.id] ?? .idle, size: 11)
                    } else if let task = tab.tree.panes.first(where: { $0.role == .task }),
                              let code = model.taskResults[task.id]
                    {
                        // A pinned task's last run: done when it passed, a red square when it failed.
                        if code == 0 {
                            StateGlyph(state: .done, size: 11)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.err).frame(width: 9, height: 9)
                        }
                    }
                    Text(tab.title).lineLimit(1).fixedSize()
                    TabCloseButton { model.closeTab(index) }
                }
                .font(Theme.mono(12))
                .foregroundStyle(on ? Theme.fg : Theme.fg3)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(on ? Theme.pane : .clear)
                .overlay(alignment: .bottom) { if on { Theme.inverse.frame(height: 2) } }
                .contentShape(Rectangle())
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TabWidths.self, value: [tab.id: geometry.size.width])
                })
                .onTapGesture { model.selectTab(index) }
                .rightClickMenu { model.rightClickTab(index) } _: { model.tabMenu(tab.id) }
                // Dragged along the strip, the tab follows the pointer and the others make room; let go, it moves.
                .offset(x: dragIndex == index ? dragging?.offset ?? 0 : dragIndex.flatMap { from in
                    target.map { TabDrag.shift(of: index, dragging: from, to: $0, widths: strip) }
                } ?? 0)
                .zIndex(dragIndex == index ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: target)
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { dragging = (tab.id, $0.translation.width) }
                        .onEnded { value in
                            let destination = TabDrag.target(
                                dragging: index, by: value.translation.width, widths: strip
                            )
                            var quiet = Transaction()
                            quiet.disablesAnimations = true
                            withTransaction(quiet) {
                                dragging = nil
                                if destination != index { model.moveTab(from: index, to: destination) }
                            }
                        }
                )
            }
            Text("+").font(Theme.mono(13)).foregroundStyle(Theme.fg3).padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
                .onTapGesture { model.perform(CommandInvocation(name: "tab.new")) }
                .help("New tab (:tab.new)")
            Spacer()
            HStack(spacing: 10) {
                // What the keys do here, as you have them bound: into the terminal in NORMAL, back out in INSERT.
                if model.mode == .insert {
                    HStack(spacing: 5) {
                        KeyCap(text: "⇧ esc")
                        let chord = KeyCapText.of(model.config.insertEscape)
                        if chord != "⇧⎋" {
                            Text("or").foregroundStyle(Theme.fg3)
                            KeyCap(text: chord)
                        }
                        Text("normal").foregroundStyle(Theme.fg3)
                    }
                    .fixedSize()
                } else {
                    hint(model.keyLabel(for: "mode.insert"), "insert")
                    hint(model.keyLabel(for: "pane.split.right"), "split right")
                    hint(model.keyLabel(for: "pane.split.below"), "below")
                    hint(model.keyLabel(for: "tab.next"), "tab")
                }
                if !model.inspectorVisible {
                    CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
                }
            }
            .font(Theme.ui(11.5))
            .padding(.horizontal, 14)
        }
        .frame(height: 36)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .onPreferenceChange(TabWidths.self) { widths = $0 }
    }
}

private struct TabWidths: PreferenceKey {
    static let defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue()) { $1 }
    }
}

extension TabStrip {
    /// A key and what it does; nothing when the command has no key.
    @ViewBuilder func hint(_ key: String?, _ label: String) -> some View {
        if let key {
            HStack(spacing: 5) {
                KeyCap(text: key)
                Text(label).foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        }
    }
}

/// A tab's ×: closes the tab (asking first when the agent is in it).
private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(hovering ? Theme.fg : Theme.fg3)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.bg3 : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help("Close tab (:tab.close)")
    }
}

private struct PaneTreeView: View {
    let tree: PaneTree
    let tab: PaneTab
    /// Where this subtree sits in the tab's tree, for naming the split a divider belongs to.
    var path: PaneTree.SplitPath = []

    var body: some View {
        switch tree {
        case let .leaf(pane):
            PaneView(pane: pane, number: (tab.tree.panes.firstIndex(of: pane) ?? 0) + 1, tab: tab)
        case .split:
            SplitView(tree: tree, tab: tab, path: path)
        }
    }
}

/// Two sides and the divider between them. Dragging the divider resizes them live, at most once a frame, and the ratio
/// is kept when it is let go; a double-click makes the split equal again.
private struct SplitView: View {
    @Environment(AppModel.self) private var model
    let tree: PaneTree
    let tab: PaneTab
    let path: PaneTree.SplitPath
    /// The ratio shown while the divider is dragged; nil when the tree's own is.
    @State private var live: Double?
    /// The first side's extent when the drag began.
    @State private var dragStart: Double?
    @State private var throttle = FrameThrottle()
    /// A ratio the throttle held back, shown at the next frame unless a newer one replaced it.
    @State private var pending: Double?

    private let sizing = PaneSizing.standard
    /// How far either side of the 1-point line the divider can be grabbed.
    private let grab = 3.0

    var body: some View {
        if case let .split(axis, first, second, _) = tree {
            GeometryReader { geometry in
                let horizontal = axis == .horizontal
                let total = horizontal ? geometry.size.width : geometry.size.height
                let extent = sizing.firstExtent(of: live.map { tree.settingRatio($0, at: []) } ?? tree, total: total)
                Group {
                    if horizontal {
                        HStack(spacing: sizing.divider) {
                            PaneTreeView(tree: first, tab: tab, path: path + [.first]).frame(width: extent)
                            PaneTreeView(tree: second, tab: tab, path: path + [.second])
                        }
                    } else {
                        VStack(spacing: sizing.divider) {
                            PaneTreeView(tree: first, tab: tab, path: path + [.first]).frame(height: extent)
                            PaneTreeView(tree: second, tab: tab, path: path + [.second])
                        }
                    }
                }
                // Shots render with SwiftUI alone, which cannot draw an AppKit view; there is nothing to drag there.
                .overlay(alignment: .topLeading) {
                    if !ShotMode.active { handle(axis, extent: extent, size: geometry.size) }
                }
            }
            .background(Theme.line)
        }
    }

    private func handle(_ axis: PaneTree.Axis, extent: Double, size: CGSize) -> some View {
        let horizontal = axis == .horizontal
        let total = horizontal ? size.width : size.height
        return DividerHandle(
            axis: axis,
            dragged: { dragged($0, from: extent, total: total) },
            released: { released($0, total: total) },
            reset: { model.resetSplit(at: path) }
        )
        .frame(
            width: horizontal ? sizing.divider + 2 * grab : size.width,
            height: horizontal ? size.height : sizing.divider + 2 * grab
        )
        .offset(x: horizontal ? extent - grab : 0, y: horizontal ? 0 : extent - grab)
    }

    private func dragged(_ delta: Double, from extent: Double, total: Double) {
        let start = dragStart ?? extent
        dragStart = start
        let ratio = sizing.ratio(forFirstExtent: start + delta, of: tree, total: total)
        let now = CACurrentMediaTime()
        if throttle.admit(at: now) {
            pending = nil
            live = ratio
            return
        }
        let waiting = pending != nil
        pending = ratio
        guard !waiting else { return }
        let wait = throttle.wait(at: now)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard let next = pending, dragStart != nil else { return }
            pending = nil
            _ = throttle.admit(at: CACurrentMediaTime())
            live = next
        }
    }

    private func released(_ delta: Double, total: Double) {
        guard let start = dragStart else { return }
        let ratio = sizing.ratio(forFirstExtent: start + delta, of: tree, total: total)
        model.setSplitRatio(ratio, at: path)
        live = nil
        dragStart = nil
        pending = nil
        throttle.reset()
    }
}

/// The grab area over a divider: a resize pointer on hover, a drag that reports how far it moved along the split, and
/// a double-click. An AppKit view so it sits above the terminals beside it and gets the mouse before they do.
private struct DividerHandle: NSViewRepresentable {
    let axis: PaneTree.Axis
    let dragged: (Double) -> Void
    let released: (Double) -> Void
    let reset: () -> Void

    func makeNSView(context _: Context) -> DividerHandleView { DividerHandleView() }

    func updateNSView(_ view: DividerHandleView, context _: Context) {
        view.axis = axis
        view.dragged = dragged
        view.released = released
        view.reset = reset
    }
}

final class DividerHandleView: NSView {
    var axis: PaneTree.Axis = .horizontal {
        didSet { if axis != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    var dragged: (Double) -> Void = { _ in }
    var released: (Double) -> Void = { _ in }
    var reset: () -> Void = {}
    private var start: NSPoint?
    private var hovering = false { didSet { needsDisplay = true } }

    private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            start = nil
            reset()
            return
        }
        start = event.locationInWindow
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delta = delta(event) else { return }
        cursor.set()
        dragged(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let delta = delta(event) else { return }
        start = nil
        needsDisplay = true
        released(delta)
    }

    /// How far the pointer moved along the split since the press: right, or down (the window's y grows upward).
    private func delta(_ event: NSEvent) -> Double? {
        guard let start else { return nil }
        let point = event.locationInWindow
        return axis == .horizontal ? point.x - start.x : start.y - point.y
    }

    override func draw(_: NSRect) {
        guard hovering || start != nil else { return }
        NSColor.white.withAlphaComponent(start != nil ? 0.35 : 0.2).setFill()
        let line = axis == .horizontal
            ? NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        line.fill()
    }
}

/// `@devbox ~/code/wt/flake-hunt · connected · direct · 24 ms`, tinted in the host's colour.
private struct RemotePaneStrip: View {
    @Environment(AppModel.self) private var model
    let host: String
    let path: String

    var body: some View {
        let palette = HostPalette.color(for: host, configured: model.config.hosts[host]?.color)
        let (text, color) = link
        HStack(spacing: 8) {
            Text("@\(host)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(palette.foreground)
            Text(path).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.middle)
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Theme.mono(11)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(palette.swatch.opacity(0.10))
        .overlay(alignment: .bottom) { palette.swatch.opacity(0.35).frame(height: 1) }
    }

    private var link: (String, Color) {
        switch model.hostStatus(host) {
        // Over the tailnet the link says how traffic goes: `direct · 12 ms`, `via relay fra · 48 ms`.
        case let .connected(info):
            info.zmxPath == nil
                ? ("connected · \(info.linkSummary) · not persistent", Theme.block)
                : ("connected · \(info.linkSummary)", Theme.done)
        case .unknown: ("checking…", Theme.fg3)
        case .needsAuth: ("ssh needs your key · a", Theme.ask)
        case .hostKeyChanged: ("host key changed · blocked", Theme.err)
        case .unknownHostKey: ("host key not known", Theme.block)
        case .tailscale(.notInstalled): ("Tailscale is not installed · gH", Theme.block)
        case .tailscale(.off): ("Tailscale is off", Theme.block)
        case .tailscale(.needsLogin): ("sign in to Tailscale · gH", Theme.ask)
        case .tailscale(.checkAuth): ("Tailscale SSH wants you to confirm · gH", Theme.ask)
        case let .offline(_, lastSeen):
            ("offline" + (lastSeen.map { " · last seen \(Clock.relative($0))" } ?? ""), Theme.fg3)
        }
    }
}

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let number: Int
    let tab: PaneTab

    var body: some View {
        let active = pane.id == tab.focused
        VStack(spacing: 0) {
            // A pane on a host: a slim tinted strip saying where, how the link is, and how fast. Local panes have none.
            if let host = pane.location.hostName { RemotePaneStrip(host: host, path: pane.directory) }
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(Theme.mono(10.5, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? Theme.ink : Theme.fg)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(active ? Theme.inverse : Theme.selected))
                Text(pane.title)
                Spacer()
                if pane.role == .agent, let session = model.currentSession {
                    Text(session.state.state.rawValue).foregroundStyle(stateColor(session.state.state))
                }
            }
            .font(Theme.mono(11))
            .foregroundStyle(active ? Theme.fg : Theme.fg3)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.paneHeader)

            // The tutor's agents are scripted too: no shell, so nothing typed there reaches a real one.
            if ShotMode.active || model.tutor != nil {
                FakeTerminal(pane: pane)
            } else {
                TerminalPane(
                    pane: pane,
                    sessionID: model.currentSession?.id ?? "",
                    isFocused: active && model.mode == .insert,
                    focusRequest: model.terminalFocusRequest
                )
            }
        }
        .background(Theme.pane)
        // White only on the pane your keys go to (INSERT); in NORMAL no pane takes input, so the focused one is quiet.
        .overlay {
            if active, model.mode == .insert {
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            } else if active {
                Rectangle().strokeBorder(Theme.paneActive.opacity(0.3), lineWidth: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            if let hint = model.hintLabel(for: .pane(pane.id)) { HintBadge(label: hint).padding(30) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.clickedPane(pane.id) }
    }

    private func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .working: Theme.busy
        case .blocked, .limited: Theme.block
        case .asking: Theme.ask
        case .done: Theme.done
        case .idle, .exited: Theme.fg3
        }
    }
}

private struct EmptyCenter: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("No session").font(Theme.ui(15, weight: .medium))
            HStack(spacing: 6) {
                KeyCap(text: "o")
                Text("start work").foregroundStyle(Theme.fg3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
