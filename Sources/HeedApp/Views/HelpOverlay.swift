import HeedCore
import SwiftUI

/// `?` / `⌘/`: modes, every command with the key that runs it here (or its `:name` when it has none) and the agent
/// states. Drawn from the live keymaps, so it always shows what the keys do now, config included.
struct HelpOverlay: View {
    @Environment(AppModel.self) private var model

    private static let modeBlurbs: [(Mode, String, [(String, String)])] = [
        (.normal, "Default. Keys drive the app, nothing reaches a terminal.", [("⎋", "from any other mode")]),
        (
            .insert,
            "Every key goes to the focused pty. Only the escape chord is caught.",
            [
                ("i", "enter on focused pane"),
                ("⇧⎋", "leave"),
                (KeyCapText.of(DefaultKeys.insertEscape), "leave (configurable)"),
            ]
        ),
        (
            .visual,
            "Select several sessions, worktrees or panes, then act on all of them.",
            [("v V", "enter"), ("d m y", "remove, pin, copy")]
        ),
        (.command, "Typed commands with completion.", [
            (":", "enter"), ("⇥", "complete"), ("↑↓", "choose"), (":tutor", "lessons on a pretend world"),
        ]),
        (
            .hint,
            "Letter badges over every pane, tab and session. Type one to jump.",
            [("f", "jump to anything"), ("F", "jump and enter INSERT")]
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            helpCard.shotRegion(.help)
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.modeBlurbs, id: \.0) { mode, blurb, keys in
                    modeCard(mode, blurb, keys)
                }
            }
            HStack(alignment: .top, spacing: 32) {
                ListScroll {
                    HStack(alignment: .top, spacing: 32) {
                        keyColumn(groups: [.move, .panes])
                        keyColumn(groups: [.views, .modes])
                        keyColumn(groups: [.selection])
                    }
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity)
                states.frame(width: 330)
            }
            // As tall as the card leaves, not as tall as every command: the columns scroll.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .padding(.top, 28)
        .padding(.leading, 60)
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
            KeyHint("overlay.close", key: "⎋", spacing: 10, label: "close", color: Theme.fg2, font: Theme.ui(12))
            KeyCap(text: "t")
            Text("tutor for this view").foregroundStyle(Theme.fg2)
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groups, id: \.self) { group in
                SectionHeader(title: group.rawValue).padding(.bottom, 4)
                ForEach(rows(group), id: \.name) { row in
                    HStack(spacing: 10) {
                        if let key = row.key {
                            Text(key)
                                .font(Theme.mono(11.5))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 64, minHeight: 20, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                                .fixedSize()
                        } else {
                            Text(":\(row.name)").font(Theme.mono(11.5)).foregroundStyle(Theme.ask).fixedSize()
                        }
                        Text(row.summary).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
                        if let context = row.context {
                            Text(context).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3).fixedSize()
                        }
                    }
                    .frame(height: 20)
                    // A click runs it, as its key would (one that needs an argument opens `:` with it typed).
                    .clickable()
                    .onTapGesture { model.clickHelpRow(row.name) }
                    .help(Clicks.help(CommandInvocation(name: row.name)))
                }
                Spacer().frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per command: the key that runs it here (`pin.jump`'s nine fold into `'1…'9`), where that key works when
    /// it is not here, or, with no key, its `:name`. COMMAND's own keys (⇥, ↩) are in its card instead.
    private func rows(_ group: CommandSpec.Group) -> [(name: String, key: String?, context: String?, summary: String)] {
        Commands.all.filter { $0.group == group && !Commands.keyOnly.contains($0.name) }.map { spec in
            let label = model.keyBinding(for: spec.name)
            return (spec.name, label?.text, label?.context, spec.summary)
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
