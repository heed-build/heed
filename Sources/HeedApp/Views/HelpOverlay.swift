import HeedCore
import SwiftUI

/// `?` / `⌘/`: modes, every bound key and the agent states. Drawn from the live keymaps, so it always shows what the
/// keys do now, config included.
struct HelpOverlay: View {
    @Environment(AppModel.self) private var model

    private static let modeBlurbs: [(Mode, String, [(String, String)])] = [
        (.normal, "Default. Keys drive the app, nothing reaches a terminal.", [("⎋", "from any other mode")]),
        (
            .insert,
            "Every key goes to the focused pty. Only the escape chord is caught.",
            [("i", "enter on focused pane"), (KeyCapText.of(DefaultKeys.insertEscape), "leave (configurable)")]
        ),
        (
            .visual,
            "Select several sessions, worktrees or panes, then act on all of them.",
            [("v V", "enter"), ("d p y", "remove, pin, copy")]
        ),
        (.command, "Typed commands with completion.", [(":", "enter"), ("⇥", "complete")]),
        (
            .hint,
            "Letter badges over every pane, tab and session. Type one to jump.",
            [("f", "jump to anything"), ("F", "jump and enter INSERT")]
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Self.modeBlurbs, id: \.0) { mode, blurb, keys in
                        modeCard(mode, blurb, keys)
                    }
                }
                HStack(alignment: .top, spacing: 40) {
                    keyColumn(groups: [.move])
                    keyColumn(groups: [.panes, .views])
                    states
                }
                Spacer(minLength: 0)
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .padding(.top, 28)
            .padding(.leading, 60)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Keys & states").font(Theme.ui(15, weight: .semibold))
            Text("you are in \(model.mode.label)")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.modeColor(model.mode)))
            Spacer()
            KeyCap(text: "?")
            Text("every mode except INSERT").foregroundStyle(Theme.fg2)
            KeyCap(text: "⌘/")
            Text("everywhere").foregroundStyle(Theme.fg2)
            KeyCap(text: "⎋")
            Text("close").foregroundStyle(Theme.fg2)
        }
        .font(Theme.ui(12))
    }

    private func modeCard(_ mode: Mode, _ blurb: String, _ keys: [(String, String)]) -> some View {
        let current = mode == model.mode
        return VStack(alignment: .leading, spacing: 10) {
            Text(mode.label)
                .font(Theme.mono(11.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.modeColor(mode)))
            Text(blurb).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            ForEach(keys, id: \.0) { key, what in
                HStack(spacing: 8) {
                    KeyCap(text: key)
                    Text(what).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            current ? Theme.fg2 : Theme.line,
            lineWidth: current ? 1.5 : 1
        ))
    }

    private func keyColumn(groups: [CommandSpec.Group]) -> some View {
        let keymap = model.engine.keymaps[.normal] ?? Keymap()
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.self) { group in
                SectionHeader(title: "Normal · \(group.rawValue)").padding(.bottom, 4)
                ForEach(rows(group, keymap), id: \.1) { keys, summary in
                    HStack(spacing: 10) {
                        Text(keys)
                            .font(Theme.mono(11.5))
                            .padding(.horizontal, 6)
                            .frame(width: 70, height: 20, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                        Text(summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    }
                }
                Spacer().frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per command, its keys joined; `pin.jump 1..9` folds into one row.
    private func rows(_ group: CommandSpec.Group, _ keymap: Keymap) -> [(String, String)] {
        Commands.all.filter { $0.group == group }.compactMap { spec in
            let keys = keymap.bindings.filter { CommandInvocation(parsing: $0.command).name == spec.name }.map(\.keys)
            guard !keys.isEmpty else { return nil }
            if spec.name == "pin.jump" { return ("'1-'9", "jump to pinned 1 to 9") }
            if spec.name == "view" { return ("⌘1-6", "sessions, inbox, issues, PRs, repos, history") }
            return (keys.prefix(2).map(KeyCapText.of).joined(separator: " "), spec.summary)
        }
    }

    private var states: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Agent states · set by hooks").padding(.bottom, 10)
            ForEach(AgentState.allCases, id: \.self) { state in
                HStack(spacing: 12) {
                    StateGlyph(state: state)
                    Text(state.rawValue).font(Theme.ui(12.5, weight: .medium)).frame(width: 90, alignment: .leading)
                    Text(state.summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            }
            HStack(spacing: 12) {
                StateGlyph(state: .working, guessed: true)
                Text("guessed").font(Theme.ui(12.5, weight: .medium)).frame(width: 90, alignment: .leading)
                Text("Dotted ring: read from terminal output, trust it less.").font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg2)
            }
            .padding(.vertical, 9)
            SectionHeader(title: "Agent → app, over a local socket").padding(.top, 16).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("$ heed state blocked --reason \"Bash(dotnet publish)\"")
                Text("$ heed state asking --reason \"3 questions\"")
                Text("$ heed pr add https://github.com/…/pull/1920")
                Text("$ heed title \"Fix broken anchors\"")
            }
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.fg2)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
