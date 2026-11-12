import HeedCore
import SwiftUI

/// The left pane of Settings' two-pane pages (Agents, Orgs & repos): a filter, then the items, each with what it is (a
/// glyph or an org's tile), its name, a note, and its count of modified settings
/// (`● 2`) and a red ! for a value heed refused. Click one to show it.
struct ScopeList: View {
    struct Item: Identifiable {
        enum Leading {
            case none
            /// ✓ ○ ! ≡, in its colour.
            case glyph(String, Color)
            case org(String)
        }

        let id: String
        var title: String
        var mono = false
        var bold = false
        var indent: CGFloat = 0
        var leading: Leading = .none
        var note: String?
        var noteColor = Theme.fg3
        var count = 0
        var problems = 0
        var dimmed = false
        var help: String?
    }

    @Binding var query: String
    let items: [Item]
    let selected: String?
    let select: (String) -> Void

    static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder).font(Theme.ui(12))
                .padding(.bottom, 6)
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.trailing, 12)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 6) {
            switch item.leading {
            case .none: EmptyView()
            case let .glyph(glyph, color):
                Text(glyph).font(Theme.mono(12, weight: .semibold)).foregroundStyle(color).frame(width: 14)
            case let .org(name):
                OrgTile(org: name, color: Palette.shared.color(for: Repo(org: name, name: "")), size: 14)
            }
            Text(item.title)
                .font(item.mono ? Theme.mono(12.5) : Theme.ui(12.5, weight: item.bold ? .semibold : .regular))
                .foregroundStyle(item.dimmed ? Theme.fg3 : Theme.fg)
                .lineLimit(1).truncationMode(.middle)
            if let note = item.note {
                Spacer(minLength: 4)
                Text(note).font(Theme.ui(10.5)).foregroundStyle(item.noteColor).lineLimit(1).fixedSize()
            } else {
                Spacer(minLength: 4)
            }
            if item.count > 0 {
                Text("● \(item.count)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.block)
                    .fixedSize()
                    .help("\(item.count) modified")
            }
            if item.problems > 0 {
                Text("!").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.err)
            }
        }
        .padding(.leading, 8 + item.indent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected == item.id ? Theme.bg3 : .clear))
        .contentShape(Rectangle())
        .help(item.help ?? item.title)
        .onTapGesture { select(item.id) }
    }
}

/// A two-pane detail's tabs, as the title bar draws its views: each with its count of modified settings, ⌘1… to turn
/// to one.
struct SettingsTabStrip: View {
    let tabs: [SettingsTab]
    let current: SettingsTab
    let count: (SettingsTab) -> Int
    let pick: (SettingsTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    if index > 0 { Theme.line.frame(width: 1, height: 14) }
                    let count = count(tab)
                    Button { pick(tab) } label: {
                        TabLabel(title: tab.title, active: current == tab, count: count > 0 ? "● \(count)" : nil)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("\(tab.title): \(count == 0 ? "nothing" : "\(count)") modified (⌘\(index + 1))")
                }
            }
            Theme.line.frame(height: 1)
        }
    }
}
