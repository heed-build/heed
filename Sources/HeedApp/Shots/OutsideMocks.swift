import AppKit
import HeedCore
import SwiftUI

/// The menu bar around Heed's item, drawn for screenshots: the owl and its count as the real item shows them.
struct MenuBarMock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let attention = Attention(blocked: model.blockedCount, asking: model.askingCount)
        HStack(spacing: 18) {
            Spacer()
            HStack(spacing: 4) {
                if let image = MenuBarMock.owl {
                    Image(nsImage: image).renderingMode(.template).resizable().frame(width: 18, height: 18)
                }
                if attention.total > 0 { Text("\(attention.total)").font(.system(size: 13, weight: .medium)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
            .shotRegion(.picker)
            Image(systemName: "wifi").font(.system(size: 14))
            Image(systemName: "magnifyingglass").font(.system(size: 13))
            Image(systemName: "switch.2").font(.system(size: 13))
            Text("Tue 13 Oct  09:41").font(.system(size: 13))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1E2228))
    }

    static let owl: NSImage? = Bundle.main.url(forResource: "menubar", withExtension: "svg").flatMap {
        NSImage(contentsOf: $0)
    }
}

/// The menu bar item's open menu, from the same entries the real menu is built from.
struct MenuMock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MenuBarMock().frame(height: 30)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MenuBarItem.entries(for: model).enumerated()), id: \.offset) { _, entry in
                    if let entry {
                        HStack(spacing: 8) {
                            if let dot = entry.dot { Circle().fill(dot).frame(width: 8, height: 8) } else {
                                Color.clear.frame(width: 8, height: 8)
                            }
                            Text(entry.title).lineLimit(1)
                                .foregroundStyle(isAction(entry) ? Color.white : Color.white.opacity(0.45))
                            Spacer(minLength: 24)
                            if !entry.keyText.isEmpty {
                                Text(entry.keyText).foregroundStyle(Color.white.opacity(0.45))
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    } else {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 5)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x2A2E35)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 16)
            .padding(.trailing, 110)
            .shotRegion(.menuBarMenu)
            Spacer()
        }
        .background(LinearGradient(
            colors: [Color(hex: 0x2B3440), Color(hex: 0x1A1F26)], startPoint: .top, endPoint: .bottom
        ))
    }

    private func isAction(_ entry: MenuBarItem.Entry) -> Bool {
        if case .none = entry.action { return false }
        return true
    }
}

/// The Dock with Heed's badged icon, as the real tile draws it.
struct DockMock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let attention = Attention(blocked: model.blockedCount, asking: model.askingCount)
        VStack {
            Spacer()
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x3A4250)).frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x4A3F5C)).frame(width: 64, height: 64)
                Image(nsImage: DockState.image(attention, side: 128)).resizable().frame(width: 64, height: 64)
                    .shotRegion(.picker)
                RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x2F4A46)).frame(width: 64, height: 64)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.12)))
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(
            colors: [Color(hex: 0x2B3440), Color(hex: 0x1A1F26)], startPoint: .top, endPoint: .bottom
        ))
    }
}

/// A right-click menu as macOS draws it, from the entries the real one is built from (the offscreen renderer draws no
/// AppKit menu): the thing it is about greyed at the top, each command with its key where macOS puts shortcuts.
struct ContextMenuMock: View {
    @Environment(AppModel.self) private var model
    let entries: [MenuEntry]
    /// The menu bar's menu: keys shown wherever they work, as that menu does.
    var menuBar = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(hex: 0x2B3440), Color(hex: 0x1A1F26)], startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in line(entry) }
            }
            .padding(.vertical, 6)
            .frame(width: menuBar ? 430 : 330)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x2A2E35)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 16)
            .shotRegion(.contextMenu)
            .padding(30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func line(_ entry: MenuEntry) -> some View {
        switch entry {
        case let .header(title):
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1).padding(.horizontal, 12).padding(.vertical, 4)
        case .separator:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 10)
        case let .item(item):
            HStack(spacing: 8) {
                Text(item.checked ? "✓" : " ").frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if let reason = item.reason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 20)
                Text(RightClickMenu.key(for: item.keyCommand, model, anywhere: menuBar))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .font(.system(size: 13))
            .foregroundStyle(item.enabled ? Color.white : Color.white.opacity(0.35))
            .padding(.horizontal, 10).padding(.vertical, 4)
        case let .submenu(title, _):
            HStack {
                Text(title).padding(.leading, 18)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .font(.system(size: 13)).foregroundStyle(Color.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }
}

/// A notification banner as macOS draws one, top right of a desktop: the session, why it needs you, and the Open and
/// Allow actions heed adds.
struct NotificationBannerMock: View {
    let title: String
    let body_: String
    var actions = ["Open", "Allow"]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(hex: 0x2B3440), Color(hex: 0x1A1F26)], startPoint: .top, endPoint: .bottom
            )
            HStack(alignment: .top, spacing: 10) {
                if let image = MenuBarMock.owl {
                    Image(nsImage: image).renderingMode(.template).resizable().frame(width: 20, height: 20)
                        .padding(8).background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x3A4250)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Heed").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("now").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(body_).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(2)
                }
                VStack(spacing: 4) {
                    ForEach(actions, id: \.self) { action in
                        Text(action).font(.system(size: 12, weight: .medium)).frame(width: 64, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.16)))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x2F343C)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 16)
            .shotRegion(.notificationBanner)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sparkle's update window as it asks: the new version, the notes of each release since the one you have, and the
/// three answers.
struct UpdatePromptMock: View {
    var body: some View {
        ZStack {
            Color(hex: 0x1A1F26)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    if let image = MenuBarMock.owl {
                        Image(nsImage: image).renderingMode(.template).resizable().frame(width: 34, height: 34)
                            .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x3A4250)))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A new version of Heed is available!").font(.system(size: 14, weight: .bold))
                        Text("Heed 0.43.0 is now available, you have 0.42.0. Would you like to install it now?")
                            .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Release Notes:").font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("0.43.0").font(.system(size: 12, weight: .semibold))
                    Text("· Settings has a search that finds a setting by its key.")
                    Text("· Autopilot's Now lists what each PR waits for.")
                    Text("0.42.1").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                    Text("· Fixes a sidebar that kept a closed session's row.")
                }
                .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.85))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                HStack(spacing: 8) {
                    Text("Skip This Version")
                    Spacer()
                    Text("Remind Me Later").padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.16)))
                    Text("Install Update").padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x2F6FEB)))
                }
                .font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .padding(20).frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2A2E35)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
            .shotRegion(.dialog)
        }
    }
}
