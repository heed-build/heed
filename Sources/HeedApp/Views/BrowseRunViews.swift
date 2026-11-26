import HeedCore
import SwiftUI

// An agent run in Browse's reader: the header bar, the worktree line, the feed, the steer line and the buttons; the
// clone card that comes first when the repo is not on this Mac; and the drafted review a Review run leaves for you.

extension BrowseFeedLine.Kind {
    var symbol: String {
        switch self {
        case .you: "person"
        case .read: "magnifyingglass"
        case .said: "checkmark"
        case .edited: "arrow.triangle.branch"
        case .tested: "checkmark"
        case .ran: "terminal"
        case .commented: "bubble.left"
        case .openedPR: "arrow.triangle.pull"
        case .labelled: "tag"
        case .pushed: "arrow.up"
        case .committed: "smallcircle.filled.circle"
        case .refused: "nosign"
        case .note: "info"
        }
    }

    var tint: Color {
        switch self {
        case .you, .read, .note: Theme.fg2
        case .said, .tested: Theme.done
        case .edited, .pushed, .committed, .ran: Theme.busy
        case .commented: Theme.busy
        case .openedPR: Theme.done
        case .labelled: Theme.block
        case .refused: Theme.err
        }
    }
}

/// The lower part of the reader while a run is on the item.
struct BrowseRunPanel: View {
    @Environment(AppModel.self) private var model
    let run: BrowseRun

    var body: some View {
        let lines = BrowseFeed.lines(run.story.feed)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(
                    verbatim: "\(Paths.tilde(run.worktree.isEmpty ? "~/code/wt/heed/\(run.repo.name)/…" : run.worktree)) · removed when you close this"
                )
                .font(Theme.mono(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 4)
            feed(lines)
            if let draft = run.draft { BrowseDraftCard(run: run, draft: draft).padding(.horizontal, 28).padding(
                .bottom,
                10
            ) }
            footer(lines)
        }
        .shotRegion(.browseRun)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.effectiveVerb.symbol).font(.system(size: 13)).foregroundStyle(run.effectiveVerb.tint)
            Text(run.verb.title).font(Theme.ui(14.5, weight: .semibold))
            Text(run.agent).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
            HStack(spacing: 6) {
                if run.phase.holdsSlot { PulseDot(color: run.effectiveVerb.tint) }
                Text(run.phase.text).font(Theme.ui(13.5)).foregroundStyle(statusTint).lineLimit(1)
            }
            if case let .chatOnly(reason) = run.mode {
                Text("read-only: \(reason)").font(Theme.ui(11.5)).foregroundStyle(Theme.block).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !run.name.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(run.name).font(Theme.mono(12))
                }
                .foregroundStyle(Theme.fg).padding(.horizontal, 9).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.keyCapBorder))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.busy.opacity(0.7), lineWidth: 1.2))
    }

    private var statusTint: Color {
        switch run.phase {
        case .failed: Theme.err
        case .done: Theme.done
        default: Theme.fg2
        }
    }

    private func feed(_ lines: [BrowseFeedLine]) -> some View {
        let content = VStack(alignment: .leading, spacing: 11) {
            ForEach(lines) { line in BrowseFeedRow(line: line).id(line.id) }
            if run.phase == .preparing || run.phase == .cloning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(run.phase == .cloning ? "cloning \(run.repo.slug)…" : "preparing the worktree and its agent…")
                        .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if ShotMode.active {
                // An offscreen render draws a scroll view empty.
                content.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { content }
                        .onChange(of: lines.last?.id) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                }
            }
        }
    }

    private func footer(_ lines: [BrowseFeedLine]) -> some View {
        let steering = model.browse.runs.input?.run == run.id && model.browse.runs.input?.kind == .steer
        let pr = lines.last { $0.kind == .openedPR }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if steering, let box = model.browse.runs.input?.box {
                    CaretText(input: box, caret: Theme.busy).font(Theme.ui(13.5))
                } else {
                    Text("Steer it, or ask a follow-up…").font(Theme.ui(13.5)).foregroundStyle(Theme.fg3)
                }
                Spacer(minLength: 0)
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                    .frame(width: 22, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(steering ? Theme.busy.opacity(0.6) : Theme.line))
            .contentShape(Rectangle())
            .clickRuns(steering ? nil : CommandInvocation(name: "browse.run.steer"))
            HStack(spacing: 10) {
                button(
                    "Close",
                    key: closeKey,
                    filled: true,
                    command: "browse.run.close"
                )
                button(
                    "Keep as a session",
                    key: model.keyText(for: "browse.run.keep", in: "browse"),
                    filled: false,
                    command: "browse.run.keep"
                )
                Text(closing(pr)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(
                    horizontal: false,
                    vertical: true
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .background(Theme.bg2)
    }

    private var closeKey: String {
        let key = model.keyText(for: "browse.run.close", in: "browse")
        return key.contains("\u{238B}") ? "esc" : key
    }

    private func closing(_ pr: BrowseFeedLine?) -> String {
        guard let number = pr?.number
        else { return "Closing removes the worktree. Anything it pushed stays on its branch." }
        return "Closing removes the worktree. PR #\(number) stays on its branch."
    }

    private func button(_ title: String, key: String, filled: Bool, command: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(14, weight: filled ? .semibold : .regular))
            Text(key).font(Theme.mono(10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(filled ? Color.black : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(filled ? Color.clear : Theme.keyCapBorder))
                .foregroundStyle(filled ? Color.white : Theme.fg3)
        }
        .foregroundStyle(filled ? Color.black : Theme.fg)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Color(white: 0.95) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filled ? Color.clear : Theme.keyCapBorder))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command))
    }
}

/// One line of the feed: a glyph in a small circle, what happened, and under it what it came to (a diff, a quote, why
/// heed refused).
struct BrowseFeedRow: View {
    let line: BrowseFeedLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: line.kind.symbol).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(line.failed ? Theme.err : line.kind.tint)
                .frame(width: 26, height: 26).background(Circle().fill(Theme.bg3))
            VStack(alignment: .leading, spacing: 6) {
                head.fixedSize(horizontal: false, vertical: true)
                if !line.diff.isEmpty { diff }
                if let detail = line.detail, line.kind == .refused || line.kind == .note {
                    Text(verbatim: detail).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var head: some View {
        switch line.kind {
        case .you:
            Text("You ").font(Theme.ui(14.5, weight: .semibold)) + Text(verbatim: line.text).font(Theme.ui(14.5))
        case .edited:
            let parts = line.text.split(separator: " ", maxSplits: 2).map(String.init)
            Text("Edited ").font(Theme.ui(14.5)) + Text(verbatim: parts.count > 1 ? parts[1] : line.text)
                .font(Theme.mono(13.5))
                + Text(verbatim: parts.count > 2 ? " " + parts[2] : "").font(Theme.ui(14.5))
        case .commented:
            Text(verbatim: line.text.replacingOccurrences(of: "#\(line.number ?? 0)", with: "")).font(Theme.ui(14.5))
                + Text(verbatim: line.number.map { "#\($0)" } ?? "").font(Theme.ui(14.5)).foregroundColor(Theme.busy)
                + Text(verbatim: line.detail.map { ": “\($0)”" } ?? "").font(Theme.ui(14.5))
        case .openedPR:
            FlowLayout(spacing: 6) {
                Text("Opened").font(Theme.ui(14.5))
                if let number = line.number {
                    Text(verbatim: "PR #\(number)").font(Theme.ui(14.5, weight: .semibold)).foregroundStyle(Theme.busy)
                        .onTapGesture {
                            if let url = line.link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                        }
                        .clickable()
                } else {
                    Text("a pull request").font(Theme.ui(14.5))
                }
                if let title = line.detail { Text(verbatim: title).font(Theme.ui(14.5)) }
                if !line.labels.isEmpty {
                    Text("· labelled").font(Theme.ui(14.5))
                    ForEach(line.labels, id: \.self) { label in
                        Text(verbatim: label).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Theme.keyCapBorder))
                    }
                }
            }
        case .tested:
            Text(verbatim: line.text).font(Theme.ui(14.5)) + Text(verbatim: line.detail.map { " " + $0 } ?? "")
                .font(Theme.ui(14.5))
        case .said:
            Text(verbatim: line.text).font(Theme.ui(14.5)).textSelection(.enabled)
        case .refused:
            Text(verbatim: line.text).font(Theme.ui(13.5)).foregroundStyle(Theme.err)
        case .note:
            Text(verbatim: line.text).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
        default:
            Text(verbatim: line.text).font(Theme.ui(14.5))
        }
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(line.diff.enumerated()), id: \.offset) { _, row in
                let added = row.kind == .added
                HStack(alignment: .top, spacing: 8) {
                    Text(added ? "+" : "–").foregroundStyle(added ? Theme.done : Theme.err)
                    Text(verbatim: row.text.trimmingCharacters(in: .init(charactersIn: " ")))
                        .foregroundStyle(added ? Theme.done : Theme.err.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .font(Theme.mono(12.5)).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3.opacity(0.7)))
    }
}

/// A dot that pulses while something is happening.
struct PulseDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).opacity(ShotMode.active || on ? 1 : 0.35)
            .onAppear {
                guard !ShotMode.active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: A drafted review

/// What a Review run left: the verdict and the text it would post, and the three things you can do. Nothing reaches
/// GitHub until Post.
struct BrowseDraftCard: View {
    @Environment(AppModel.self) private var model
    let run: BrowseRun
    let draft: BrowseReviewDraft

    var body: some View {
        let editing = model.browse.runs.input?.kind == .review && model.browse.runs.input?.run == run.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.checkmark").font(.system(size: 12)).foregroundStyle(Theme.done)
                Text("DRAFTED REVIEW").font(Theme.mono(11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.done)
                Text(draft.verdict.title).font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.fg)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.bg3))
                Spacer()
                Text(statusText).font(Theme.ui(12)).foregroundStyle(draft.failure == nil ? Theme.fg3 : Theme.err)
            }
            if editing, let box = model.browse.runs.input?.box {
                CaretText(input: box, caret: Theme.done).font(Theme.ui(13))
                    .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                Text("↩ saves · ⇧↩ new line · esc leaves it as it was").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            } else {
                Text(verbatim: draft.body).font(Theme.ui(13)).foregroundStyle(Theme.fg).textSelection(.enabled)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            }
            if draft.state == .drafted {
                HStack(spacing: 8) {
                    action("Post", "browse.run.review.post", filled: true)
                    action("Edit", "browse.run.review.edit", filled: false)
                    action("Discard", "browse.run.review.discard", filled: false)
                    Text("A review is public: it is posted only from Post.").font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.done.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.done.opacity(0.35)))
    }

    private var statusText: String {
        if let failure = draft.failure { return "could not post: \(failure)" }
        switch draft.state {
        case .drafted: return "waiting for you"
        case .posting: return "posting…"
        case .posted: return "posted"
        case .discarded: return "discarded"
        }
    }

    private func action(_ title: String, _ command: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.ui(13, weight: filled ? .semibold : .regular))
            Text(model.keyText(for: command, in: "browse")).font(Theme.mono(10.5))
                .foregroundStyle(filled ? Color.black.opacity(0.6) : Theme.fg3)
        }
        .foregroundStyle(filled ? Color.black : Theme.fg)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(filled ? Color(white: 0.95) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(filled ? Color.clear : Theme.keyCapBorder))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command))
    }
}

// MARK: Clone first

/// The repo is not on this Mac: where it goes, and the three ways on.
struct BrowseCloneCard: View {
    @Environment(AppModel.self) private var model
    let run: BrowseRun

    var body: some View {
        let editing = model.browse.runs.input?.kind == .folder && model.browse.runs.input?.run == run.id
        let root = run.cloneRoot ?? "~/code"
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "icloud").font(.system(size: 14)).foregroundStyle(Theme.block)
                Text(verbatim: "\(run.repo.slug) is not on this Mac").font(Theme.ui(15, weight: .semibold))
            }
            Text(
                "\(article) \(run.verb.title.lowercased()) works in a temporary worktree, so heed needs a clone first. It goes to the usual place and appears in Repos."
            )
            .font(Theme.ui(14)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            HStack {
                if editing, let box = model.browse.runs.input?.box {
                    CaretText(input: box, caret: Theme.busy).font(Theme.mono(14))
                } else {
                    Text(verbatim: "\(root)/\(run.repo.name)").font(Theme.mono(14))
                }
                Spacer()
                Text(editing ? "↩ saves" : "change").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    .clickRuns(editing ? nil : CommandInvocation(name: "browse.clone.folder"))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(editing ? Theme.busy.opacity(0.6) : Theme.line))
            HStack(spacing: 10) {
                if run.phase == .cloning {
                    ProgressView().controlSize(.small)
                    Text("cloning…").font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
                } else {
                    button(
                        "Clone and \(run.verb.title.lowercased())",
                        key: "↩",
                        filled: true,
                        command: "browse.clone.go"
                    )
                    button(
                        "Just clone",
                        key: model.keyText(for: "browse.clone.only", in: "browse"),
                        filled: false,
                        command: "browse.clone.only"
                    )
                    button("Not now", key: "esc", filled: false, command: "browse.run.close")
                }
                if case let .failed(why) = run.phase {
                    Text(why).font(Theme.ui(12.5)).foregroundStyle(Theme.err).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2)
        .overlay(alignment: .top) { Theme.block.opacity(0.5).frame(height: 1) }
        .shotRegion(.browseRun)
    }

    private var article: String { run.verb == .implement ? "An" : "A" }

    private func button(_ title: String, key: String, filled: Bool, command: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(14, weight: filled ? .semibold : .regular))
            Text(key).font(Theme.mono(10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(filled ? Color.black : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(filled ? Color.clear : Theme.keyCapBorder))
                .foregroundStyle(filled ? Color.white : Theme.fg3)
        }
        .foregroundStyle(filled ? Color.black : Theme.fg)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Color(white: 0.95) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filled ? Color.clear : Theme.keyCapBorder))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command))
    }
}

/// A run that could not start: what failed and what to do about it, in the reader, where it stays until it is
/// dismissed or the verb is tried again. (A message in the status bar goes after a few seconds; this does not.)
struct BrowseRunFailedCard: View {
    @Environment(AppModel.self) private var model
    let verb: BrowseVerb
    let why: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Theme.err)
                Text("\(verb.title) could not start").font(Theme.ui(14, weight: .semibold))
            }
            Text(why).font(Theme.ui(13)).foregroundStyle(Theme.err).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(BrowseRunFailure.advice(for: why)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    KeyCap(text: model.keyText(for: verb.command, in: "browse"))
                    Text("try again").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                .contentShape(Rectangle())
                .clickRuns(CommandInvocation(name: verb.command))
                HStack(spacing: 6) {
                    KeyCap(text: "esc")
                    Text("dismiss").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                }
                .contentShape(Rectangle())
                .clickRuns(CommandInvocation(name: "browse.run.close"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.err.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.err.opacity(0.7)))
        .shotRegion(.browseRun)
    }
}
