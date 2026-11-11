import HeedCore
import SwiftUI

/// One part of a pane bar's breadcrumb; a click runs `runs` when it has one.
struct PaneCrumb {
    var text: String
    var runs: CommandInvocation?

    init(_ text: String, runs: CommandInvocation? = nil) {
        self.text = text
        self.runs = runs
    }
}

/// One tab of a pane bar's strip.
struct PaneBarTab: Identifiable {
    var id: String
    var title: String
    /// What opens it: the tooltip is its summary, and its key is shown unless `showsKey` is off.
    var command: String
    var count: Int
    var showsKey = true
    /// A wider gap before it: a tab that belongs to the view, not to what is selected in it.
    var gapBefore = false
}

/// Above a view's panes: where you are (a breadcrumb, with what the view wants on the right), and a tab per pane with
/// its key and what waits there. A click on a tab opens it as its key does; the keys keep working.
struct PaneBar<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let crumb: [PaneCrumb]
    let tabs: [PaneBarTab]
    let active: String
    /// The key scope the tabs' keys are looked up in.
    let scope: String
    var tabsRegion: ShotRegion?
    let select: (PaneBarTab) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                crumbs
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ViewThatFits(in: .horizontal) {
                strip(keys: true)
                strip(keys: false)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            .shotRegion(tabsRegion)
        }
    }

    private var crumbs: some View {
        HStack(spacing: 7) {
            ForEach(Array(crumb.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("›").foregroundStyle(Theme.fg3) }
                let last = index == crumb.count - 1
                Text(part.text)
                    .foregroundStyle(last ? Theme.fg : Theme.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .clickRuns(last ? nil : part.runs)
            }
        }
        .font(Theme.ui(13, weight: .medium))
    }

    private func strip(keys: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                // A hairline between tabs, and a wider gap before one that belongs to the view.
                if index > 0 {
                    if tab.gapBefore { Spacer(minLength: 12) }
                    Theme.line.frame(width: 1, height: 14)
                }
                TabLabel(
                    title: tab.title, active: active == tab.id, count: tab.count > 0 ? "\(tab.count)" : nil,
                    key: keys && tab.showsKey ? model.keyText(for: tab.command, in: scope) : nil
                )
                .onTapGesture { select(tab) }
                .help(Commands.spec(tab.command)?.summary ?? tab.title)
            }
        }
    }
}
