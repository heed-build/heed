import HeedCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                switch model.view {
                case .sessions:
                    Sidebar()
                    CenterArea()
                    if model.inspectorVisible { Inspector() }
                case .repos:
                    ReposView()
                default:
                    ComingView(view: model.view)
                }
            }
            StatusBar()
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
        .overlay {
            if model.startWork != nil { StartWorkView() }
        }
        .overlay {
            if model.overlay == .help { HelpOverlay() }
        }
        .overlay(alignment: .bottom) {
            if model.mode == .command { CommandLineView().padding(.bottom, 28) }
        }
        .ignoresSafeArea()
    }
}

struct TitleBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            // Room for the window's own traffic lights.
            Color.clear.frame(width: 60, height: 1)
            if model.view != .sessions {
                Text(model.view == .repos ? "Repos & worktrees" : model.view.title)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
            } else if let session = model.currentSession {
                HStack(spacing: 4) {
                    Text(session.repos.first?.name ?? "").foregroundStyle(Theme.fg2)
                    Text("/").foregroundStyle(Theme.dim)
                    Text(session.branch).fontWeight(.medium)
                }
                .font(Theme.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            }
            HStack(spacing: 2) {
                ForEach(Array(AppView.allCases.enumerated()), id: \.element) { index, view in
                    Text(verbatim: "\(index + 1) \(view.title)")
                        .lineLimit(1)
                        .fixedSize()
                        .font(Theme.mono(11.5))
                        .foregroundStyle(model.view == view ? Theme.fg : Theme.fg3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(model.view == view ? Theme.selected : .clear))
                }
            }
            .padding(.leading, 12)
            Spacer()
            if model.blockedCount > 0 {
                Label { Text("\(model.blockedCount) blocked").fixedSize() } icon: { StateGlyph(state: .blocked) }
            }
            if model.askingCount > 0 {
                Label { Text("\(model.askingCount) asking").fixedSize() } icon: { StateGlyph(state: .asking) }
            }
            HStack(spacing: 6) {
                KeyCap(text: "ga")
                Text("next attention").foregroundStyle(Theme.fg3).fixedSize()
            }
        }
        .font(Theme.ui(12))
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text(model.mode.label)
                .font(Theme.mono(11.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Theme.modeColor(model.mode))
            if let session = model.currentSession {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(session.branch)
                }
                .padding(.horizontal, 12)
            }
            if let tab = model.currentTab, let index = tab.tree.panes.firstIndex(where: { $0.id == tab.focused }) {
                Text("pane \(index + 1) · \(tab.tree.panes[index].title)")
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 12)
            }
            if let flash = model.flash {
                Text(flash).foregroundStyle(Theme.block).padding(.horizontal, 12)
            } else if let problem = model.keyProblems.first {
                Text("config: \(problem.description)").foregroundStyle(Theme.err).padding(.horizontal, 12)
            }
            Spacer()
            Text(model.pendingKeys).foregroundStyle(Theme.fg).padding(.horizontal, 12)
            Text(hints).foregroundStyle(Theme.fg3).padding(.horizontal, 12)
            Text(position).foregroundStyle(Theme.fg2).padding(.horizontal, 12)
        }
        .font(Theme.mono(11.5))
        .frame(height: 28)
        .background(Theme.bg3)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var position: String {
        model.view == .repos
            ? "\(model.worktreeRows.isEmpty ? 0 : model.repoCursor + 1)/\(model.worktreeRows.count)"
            : "\(model.list.ordered.isEmpty ? 0 : model.cursor + 1)/\(model.list.ordered.count)"
    }

    private var hints: String {
        switch model.mode {
        case .normal where model.view == .repos: "v select · n new worktree · R rescan · ⎋ back to sessions"
        case .normal: "i insert · o start work · gp PR overlay · : command · ? keys"
        case .insert: "\(KeyCapText.of(DefaultKeys.insertEscape)) normal · ⌘/ keys"
        case .visual: "\(model.selectedRows.count) selected · space toggle · y copy path · o open session · ⎋ cancel"
        case .command: "⇥ complete · ↩ run · ⎋ cancel"
        case .hint: "type a label · ⎋ cancel"
        }
    }
}

/// Key notation as key-cap text: `<C-w>v` reads `⌃w v`.
enum KeyCapText {
    static func of(_ notation: String) -> String {
        guard let strokes = try? KeyNotation.parse(notation) else { return notation }
        return of(strokes)
    }

    /// Runs of plain characters share a cap (`gg`, `'1`); a modified or named key stands alone (`⌃w v`).
    static func of(_ strokes: [KeyStroke]) -> String {
        var parts: [String] = []
        var previousPlain = false
        for stroke in strokes {
            let plain = stroke.modifiers.isEmpty && !stroke.isNamed
            if plain, previousPlain {
                parts[parts.count - 1] += stroke.glyph
            } else {
                parts.append(stroke.glyph)
            }
            previousPlain = plain
        }
        return parts.joined(separator: " ")
    }
}

struct CommandLineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.commandCompletions, id: \.name) { spec in
                HStack {
                    Text(spec.name).font(Theme.mono(12))
                    if let args = spec.arguments { Text(args).font(Theme.mono(12)).foregroundStyle(Theme.fg3) }
                    Spacer()
                    Text(spec.summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            HStack(spacing: 0) {
                Text(":").foregroundStyle(Theme.ask)
                Text(model.commandText)
                Rectangle().fill(Theme.fg).frame(width: 7, height: 15)
                Spacer()
            }
            .font(Theme.mono(13))
            .padding(12)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 20)
    }
}

/// Views not built yet say which step brings them.
struct ComingView: View {
    let view: AppView

    var body: some View {
        VStack(spacing: 10) {
            Text(view.title).font(Theme.ui(15, weight: .medium))
            Text(view == .history ? "History arrives with persistence (step 5)." : "GitHub arrives in step 6.")
                .foregroundStyle(Theme.fg3)
            HStack(spacing: 6) {
                KeyCap(text: "⎋")
                Text("back to sessions").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
