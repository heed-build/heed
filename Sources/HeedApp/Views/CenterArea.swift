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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.currentTabs.enumerated()), id: \.element.id) { index, tab in
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
                .onTapGesture { model.selectTab(index) }
                .rightClickMenu { model.rightClickTab(index) } _: { model.tabMenu(tab.id) }
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

    var body: some View {
        switch tree {
        case let .leaf(pane):
            PaneView(pane: pane, number: (tab.tree.panes.firstIndex(of: pane) ?? 0) + 1, tab: tab)
        case let .split(axis, first, second, ratio):
            GeometryReader { geometry in
                if axis == .horizontal {
                    HStack(spacing: 1) {
                        PaneTreeView(tree: first, tab: tab).frame(width: (geometry.size.width - 1) * ratio)
                        PaneTreeView(tree: second, tab: tab)
                    }
                } else {
                    VStack(spacing: 1) {
                        PaneTreeView(tree: first, tab: tab).frame(height: (geometry.size.height - 1) * ratio)
                        PaneTreeView(tree: second, tab: tab)
                    }
                }
            }
            .background(Theme.line)
        }
    }
}

/// `@devbox ~/code/wt/flake-hunt · connected · 24 ms`, tinted in the host's colour.
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
        case let .connected(info):
            info.zmxPath == nil
                ? ("connected · \(info.latencyMilliseconds) ms · not persistent", Theme.block)
                : ("connected · \(info.latencyMilliseconds) ms", Theme.done)
        case .unknown: ("checking…", Theme.fg3)
        case .needsAuth: ("ssh needs your key · a", Theme.ask)
        case .hostKeyChanged: ("host key changed · blocked", Theme.err)
        case .unknownHostKey: ("host key not known", Theme.block)
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
