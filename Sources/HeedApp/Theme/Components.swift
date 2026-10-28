import HeedCore
import SwiftUI

/// The state glyph: a different shape per state, so it reads without color. Guessed states get a dotted ring.
struct StateGlyph: View {
    let state: AgentState
    var guessed = false
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            shape
            if guessed {
                Circle()
                    .stroke(Theme.fg3, style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                    .frame(width: size + 6, height: size + 6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(guessed ? "\(state.rawValue) (guessed)" : state.rawValue)
    }

    @ViewBuilder private var shape: some View {
        switch state {
        case .working:
            Spinner(size: size)
        case .idle:
            Circle().strokeBorder(Theme.fg3, lineWidth: 1.5)
        case .blocked:
            RoundedRectangle(cornerRadius: 2).fill(Theme.block)
                .rotationEffect(.degrees(45)).scaleEffect(0.78)
        case .asking:
            Circle().fill(Theme.ask)
                .overlay(Text("?").font(.system(size: size * 0.7, weight: .bold)).foregroundStyle(Theme.ink))
        case .done:
            Circle().fill(Theme.done)
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(Theme.ink))
        case .limited:
            Circle().strokeBorder(Theme.block, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        case .exited:
            RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.fg2, lineWidth: 1.5)
        }
    }
}

/// The working spinner. Driven by the render clock rather than a repeating animation, so it costs nothing when the
/// window is hidden. Shots draw it at rest, so two renders of the same shot are the same picture.
private struct Spinner: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: ShotMode.active)) { context in
            let angle = ShotMode.active ? 0
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            ZStack {
                Circle().stroke(Theme.busy.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(Theme.busy, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .padding(1)
        }
    }
}

/// A key cap: `gp`, `⌃w v`, `?`.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.fg2)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.keyCap))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
            .fixedSize()
    }
}

/// A key hint you can click: the key cap and what it does. A click runs what the key runs, by the key's path: the
/// command through `AppModel.perform`, or for a dialog that reads its keys itself (`⎋`), the keys pressed. The pointer
/// and a faint highlight say it is clickable; the tooltip names the command.
struct KeyHint<Label: View>: View {
    enum Action {
        case command(CommandInvocation)
        case keys([KeyStroke])
    }

    @Environment(AppModel.self) private var model
    private let action: Action
    private let key: String?
    private let scope: String?
    private let spacing: CGFloat
    private let alignment: VerticalAlignment
    private let capWidth: CGFloat?
    private let label: Label

    /// `command` with `arguments`, acting on `target` (else on what the cursor is on, as the key does). The cap shows
    /// `key`, else the command's key as bound, in `scope`'s bindings first (`pr`, `ledger`).
    init(
        _ command: String, _ arguments: [String] = [], target: CommandTarget? = nil, count: Int? = nil,
        key: String? = nil, scope: String? = nil, spacing: CGFloat = 6, alignment: VerticalAlignment = .center,
        capWidth: CGFloat? = nil, @ViewBuilder label: () -> Label
    ) {
        action = .command(CommandInvocation(name: command, arguments: arguments, count: count, target: target))
        self.key = key
        self.scope = scope
        self.spacing = spacing
        self.alignment = alignment
        self.capWidth = capWidth
        self.label = label()
    }

    /// Keys pressed, in notation (`<Esc>`), for what is not a command.
    init(keys notation: String, spacing: CGFloat = 6, @ViewBuilder label: () -> Label) {
        let strokes = (try? KeyNotation.parse(notation)) ?? []
        action = .keys(strokes)
        key = KeyCapText.of(strokes)
        scope = nil
        self.spacing = spacing
        alignment = .center
        capWidth = nil
        self.label = label()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            KeyCap(text: cap).frame(minWidth: capWidth)
            label
        }
        .clickable()
        .onTapGesture { run() }
        .help(help)
    }

    private var cap: String {
        if let key { return key }
        guard case let .command(invocation) = action else { return "" }
        return scope.map { model.keyText(for: invocation.name, in: $0) } ?? model.keyText(for: invocation.name)
    }

    private var help: String {
        switch action {
        case let .command(invocation): Clicks.help(invocation)
        case let .keys(strokes): "Press \(KeyCapText.of(strokes))"
        }
    }

    private func run() {
        switch action {
        case let .command(invocation): model.clickHint(invocation)
        case let .keys(strokes): model.press(strokes)
        }
    }
}

extension KeyHint where Label == HintText {
    /// The usual hint: a key cap and a few quiet words.
    init(
        _ command: String, _ arguments: [String] = [], target: CommandTarget? = nil, count: Int? = nil,
        key: String? = nil, scope: String? = nil, spacing: CGFloat = 6, capWidth: CGFloat? = nil, label: String,
        color: Color = Theme.fg3, font: Font = Theme.ui(12)
    ) {
        self.init(
            command, arguments, target: target, count: count, key: key, scope: scope, spacing: spacing,
            capWidth: capWidth
        ) { HintText(text: label, color: color, font: font) }
    }

    init(
        keys notation: String, spacing: CGFloat = 6, label: String, color: Color = Theme.fg3, font: Font = Theme.ui(12)
    ) {
        self.init(keys: notation, spacing: spacing) { HintText(text: label, color: color, font: font) }
    }
}

extension View {
    /// A click runs `invocation` as its key would (see `KeyHint`): the pointer says it is clickable, the tooltip names
    /// the command. Nil: an ordinary view, not clickable.
    @ViewBuilder func clickRuns(_ invocation: CommandInvocation?) -> some View {
        if let invocation { modifier(ClickRuns(invocation: invocation)) } else { self }
    }
}

private struct ClickRuns: ViewModifier {
    @Environment(AppModel.self) private var model
    let invocation: CommandInvocation

    func body(content: Content) -> some View {
        content
            .clickable()
            .onTapGesture { model.clickHint(invocation) }
            .help(Clicks.help(invocation))
    }
}

extension View {
    /// Says a view is clickable: the pointing hand, and a faint highlight under it while hovered.
    func clickable() -> some View { modifier(Clickable()) }
}

private struct Clickable: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.selected : .clear).padding(-3))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

/// A key hint's words.
struct HintText: View {
    let text: String
    var color: Color = Theme.fg3
    var font: Font = Theme.ui(12)

    var body: some View {
        // Whole, never wrapped or cut: a row of hints wraps between them instead.
        Text(text).font(font).foregroundStyle(color).fixedSize()
    }
}

/// A repo chip: org avatar tile plus repo name, in the org's color.
struct RepoChip: View {
    let repo: Repo
    /// A filter whose matches in the name are highlighted.
    var highlight = ""

    var body: some View {
        HStack(spacing: 5) {
            OrgTile(org: repo.org, color: repo.color, size: 12)
            Highlighted(text: repo.name, query: highlight, mark: Theme.fg).font(Theme.mono(10.5)).lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(repo.color.foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(repo.color.background))
    }
}

/// A chat's mark: a speech bubble, where a session in a repo would show its repo.
struct ChatGlyph: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "bubble.left").font(.system(size: size)).foregroundStyle(Theme.fg2)
            .accessibilityLabel("chat")
    }
}

/// A chat's folder, in a neutral chip: `scratch`, or the folder you picked (`~/Downloads`).
struct ChatFolderChip: View {
    let chat: ChatFolder

    var body: some View {
        Text(chat.kind == .scratch ? "scratch" : Paths.tilde(chat.path))
            .font(Theme.mono(10.5)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(Theme.fg2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            .help(chat.path)
    }
}

/// "chat" where a history row or detail would show a repo: the glyph and the word.
struct ChatKindChip: View {
    var body: some View {
        HStack(spacing: 4) {
            ChatGlyph(size: 10)
            Text("chat").font(Theme.mono(10.5))
        }
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
    }
}

/// Where something runs: `@devbox` in the host's colour, or a quiet "local" (local is the unmarked default).
struct HostChip: View {
    let location: Location
    /// `[hosts.x] color`.
    var color: String?

    var body: some View {
        if let host = location.hostName {
            let palette = HostPalette.color(for: host, configured: color)
            Text("@\(host)").font(Theme.mono(10.5)).lineLimit(1)
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.background))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.swatch.opacity(0.45)))
        } else {
            Text("local").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
        }
    }
}

/// Whether heed manages a worktree on a host: registered, discovered (found, never touched), stale, missing.
struct RegistrationChip: View {
    let registration: WorktreeRegistration

    var body: some View {
        Text(registration.rawValue).font(Theme.mono(10.5))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.5)))
    }

    private var color: Color {
        switch registration {
        case .registered: Theme.done
        case .discovered: Theme.busy
        case .stale, .missing: Theme.fg3
        }
    }
}

/// Text with a filter's matches marked: bold and in `mark`, so the eye finds why a row is there.
struct Highlighted: View {
    let text: String
    let query: String
    var mark: Color = Theme.block

    var body: some View { Self.text(text, query: query, mark: mark) }

    /// As `Text`, so it joins other text. `base` colours what did not match; nil leaves it to the surrounding style.
    static func text(_ text: String, query: String, mark: Color = Theme.block, base: Color? = nil) -> Text {
        var attributed = AttributedString(text)
        if let base { attributed.foregroundColor = base }
        for range in FilterQuery.ranges(query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower ..< upper].foregroundColor = mark
            attributed[lower ..< upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }
}

/// A worktree's path, small: its root dimmed, the part below it (what filters match) brighter and highlighted.
struct WorktreePath: View {
    let path: String
    let roots: [String]
    var query = ""

    var body: some View {
        let split = Paths.split(path, roots: roots)
        let root = Text(split.root).foregroundColor(Theme.fg3)
        let relative = Highlighted.text(split.relative, query: query, base: Theme.fg2)
        return Text("\(root)\(relative)")
            .font(Theme.mono(11))
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// One tab of a strip, as the title bar's views draw theirs: its name (bold when it is the one shown), a count in the
/// block colour, and its key. Dimmed, the name is quiet: a tab with nothing to show under a filter.
struct TabLabel: View {
    let title: String
    let active: Bool
    var count: String?
    var key: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(dimmed ? Theme.fg3 : active ? Theme.fg : Theme.fg2)
            if let count { Text(count).foregroundStyle(Theme.block) }
            if let key {
                Text(key)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.keyCapBorder))
            }
        }
        .font(Theme.ui(12.5, weight: active ? .semibold : .regular))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, key == nil ? 7 : 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

/// Section header: small caps, tracked.
struct SectionHeader: View {
    let title: String
    var tint = Theme.fg3

    var body: some View {
        Text(title.uppercased())
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(tint)
    }
}

/// An org's avatar (cached from github.com), or its first letter on its color while there is none.
struct OrgTile: View {
    let org: String
    let color: OrgPalette
    var size: CGFloat = 12

    var body: some View {
        if let image = Avatars.shared.image(for: org) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 4))
        } else {
            Text(String(org.prefix(1)))
                .font(.system(size: size * 0.66, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size / 4).fill(color.foreground))
        }
    }
}

/// A goal's score, 0–10, as a ring filled that far with the number in it; "–" in a quiet ring until something scored
/// it. The colour says where it stands (under 5, under 7, 7 and up) and the number says it in words too.
struct ScoreRing: View {
    let score: Double?
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 2.5)
            if let score {
                Circle().trim(from: 0, to: min(max(score / 10, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(Theme.fg3, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
            Text(score.map { String(format: "%.1f", $0) } ?? "–")
                .font(Theme.mono(size * 0.32, weight: .semibold))
                .foregroundStyle(score == nil ? Theme.fg3 : tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(score.map { "score \(String(format: "%.1f", $0)) of 10" } ?? "no score yet")
        .help(score == nil ? "No score yet: reviewers score a goal once they have looked at it" : "Score out of 10")
    }

    private var tint: Color {
        guard let score else { return Theme.fg3 }
        return score >= 7 ? Theme.done : score >= 5 ? Theme.block : Theme.err
    }
}
