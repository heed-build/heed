import HeedCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var width: CGFloat = 330

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "Sessions")
                Spacer()
                CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                if model.filtering || !model.sessionFilter.isEmpty {
                    HStack(spacing: 0) {
                        Text("/").foregroundStyle(Theme.fg3)
                        Text(model.sessionFilter).lineLimit(1)
                        if model.filtering { Rectangle().fill(Theme.fg).frame(width: 7, height: 14) }
                    }
                    .font(Theme.mono(12))
                } else {
                    KeyCap(text: "/ filter")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list.sections, id: \.group) { section in
                            groupHeader(section, pins: list.pins.count)
                            ForEach(section.sessions) { session in
                                let index = list.ordered.firstIndex(of: session) ?? 0
                                SessionRow(
                                    session: session,
                                    number: list.lineNumber(of: index, cursor: model.cursor),
                                    isCursor: index == model.cursor,
                                    pinNumber: list.pins.firstIndex(of: session).map { $0 + 1 },
                                    hint: model.hintLabel(for: .session(session.id))
                                )
                                .id(session.id)
                            }
                        }
                    }
                }
                .onChange(of: model.cursor) {
                    if let id = model.currentSession?.id { proxy.scrollTo(id) }
                }
            }

            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No sessions yet.").foregroundStyle(Theme.fg2)
                    HStack(spacing: 6) {
                        KeyCap(text: "o")
                        Text("start work").foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.ui(12.5))
                .padding(16)
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack {
                Text("\(model.repos.count) repos · \(model.worktreeRows.count) worktrees").foregroundStyle(Theme.fg2)
                Spacer()
                KeyCap(text: "gr")
            }
            .font(Theme.ui(12))
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
        .frame(width: width)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func groupHeader(_ section: SessionList.Section, pins: Int) -> some View {
        HStack(spacing: 6) {
            if section.group == .pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.fg3)
            }
            let count = section.group == .pinned ? "\(pins)/\(SessionGroup.maxPins)" : "\(section.sessions.count)"
            SectionHeader(
                title: "\(section.group.rawValue) · \(count)",
                tint: section.group == .needsYou ? Theme.block : Theme.fg3
            )
            Spacer()
            if section.group == .pinned { KeyCap(text: "'") }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct SessionRow: View {
    let session: Session
    let number: Int
    let isCursor: Bool
    let pinNumber: Int?
    let hint: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 1)
            StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(Theme.ui(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let pinNumber { KeyCap(text: "'\(pinNumber)") }
                    if !session.trackedPRs.isEmpty {
                        Text("\(session.trackedPRs.count) PR")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                    }
                }
                FlowChips(repos: session.repos)
                Text("\(session.agent) · \(session.activity)")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.fg3)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .topLeading) {
            if let hint { HintBadge(label: hint).padding(.leading, 8).padding(.top, 8) }
        }
    }
}

private struct FlowChips: View {
    let repos: [Repo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(repos, id: \.self) { RepoChip(repo: $0) }
        }
    }
}

/// HINT mode's letter badge.
struct HintBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.modeColor(.hint)))
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

/// The collapsed sidebar: one row per session with its number, state and pin, so moving and jumping still work.
struct SessionRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                .padding(.vertical, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.ordered.enumerated()), id: \.element.id) { index, session in
                        let isCursor = index == model.cursor
                        VStack(spacing: 4) {
                            Text("\(list.lineNumber(of: index, cursor: model.cursor))")
                                .font(Theme.mono(10, weight: isCursor ? .bold : .regular))
                                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                            StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                            if let pin = list.pins.firstIndex(of: session) {
                                Text("'\(pin + 1)").font(Theme.mono(9)).foregroundStyle(Theme.fg3)
                            }
                        }
                        .frame(width: 44)
                        .padding(.vertical, 8)
                        .background(isCursor ? Theme.bg3 : .clear)
                        .overlay(alignment: .topLeading) {
                            if let hint = model.hintLabel(for: .session(session.id)) { HintBadge(label: hint) }
                        }
                        .help(session.title)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 48)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }
}

/// A small chevron button that collapses or expands a pane, with its key in the tooltip.
struct CollapseButton: View {
    let systemImage: String
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.fg3)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("collapse / expand (\(key))")
    }
}
