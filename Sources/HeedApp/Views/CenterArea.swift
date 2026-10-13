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
                    Text(tab.title)
                }
                .font(Theme.mono(12))
                .foregroundStyle(on ? Theme.fg : Theme.fg3)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(on ? Theme.pane : .clear)
                .overlay(alignment: .bottom) { if on { Theme.inverse.frame(height: 2) } }
                .contentShape(Rectangle())
                .onTapGesture { model.selectTab(index) }
            }
            Text("+").font(Theme.mono(13)).foregroundStyle(Theme.fg3).padding(.horizontal, 14)
            Spacer()
            HStack(spacing: 6) {
                KeyCap(text: "gt")
                KeyCap(text: "⌃w v")
                Text("split").foregroundStyle(Theme.fg3)
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

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let number: Int
    let tab: PaneTab

    var body: some View {
        let active = pane.id == tab.focused
        VStack(spacing: 0) {
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

            if ShotMode.active {
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
