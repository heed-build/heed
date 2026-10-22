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
/// window is hidden.
private struct Spinner: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
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
