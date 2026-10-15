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
            .shotRegion(.dialog)
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
