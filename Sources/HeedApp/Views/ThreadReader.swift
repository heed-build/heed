import HeedCore
import SwiftUI

/// A thread's header in a reader: where it is and who opened it, its title, chips for its state, and what you can do
/// with it, each a button showing its key.
struct ThreadHeader: View {
    struct Chip: Hashable {
        let text: String
        var tint: Color = Theme.fg2
    }

    struct Action: Hashable {
        let command: String
        let label: String
        var scope: String?
        var key: String?
    }

    let repo: Repo
    let kind: ThreadConversation.Kind
    let number: Int
    let title: String
    var author: String?
    var openedAt: Date?
    var chips: [Chip] = []
    var actions: [Action] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RepoChip(repo: repo)
                Text(verbatim: place).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Text(title).font(Theme.ui(18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !chips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip.text).font(Theme.ui(11.5)).foregroundStyle(chip.tint)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(chip.tint.opacity(0.14)))
                    }
                }
            }
            if !actions.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(actions, id: \.self) { ThreadActionButton(action: $0) }
                }
                .padding(.top, 2)
            }
        }
    }

    private var place: String {
        var parts = [kind == .pr ? "pull request #\(number)" : "issue #\(number)"]
        if let author {
            parts.append("opened by \(author)" + (openedAt.map { " \(Ages.long($0))" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// `Reply R`: what a key does, as a button that runs the same command.
struct ThreadActionButton: View {
    @Environment(AppModel.self) private var model
    let action: ThreadHeader.Action

    var body: some View {
        HStack(spacing: 7) {
            Text(action.label).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
            Text(action.key ?? action.scope.map { model.keyText(for: action.command, in: $0) }
                ?? model.keyText(for: action.command))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.keyCapBorder))
        .clickRuns(CommandInvocation(name: action.command))
    }
}

/// A thread's conversation: the opening post, whatever the reader puts after it (a PR's review threads and
/// checks), then the comments. With `seenAt`, the comments you had read fold into one line (a click unfolds them)
/// and "new · N" marks where the new ones start; your own comments count as read, and so does what came before
/// them. Without either everything shows. `compact` is the narrow Attention
/// pane.
struct ThreadConversationView<Between: View>: View {
    @Environment(AppModel.self) private var model
    let conversation: ThreadConversation
    var seenAt: Date?
    var compact = false
    @ViewBuilder var between: () -> Between

    @State private var unfolded = false

    var body: some View {
        let comments = conversation.comments
        let fold = ThreadFold.compute(comments, seenAt: seenAt, viewer: model.github.viewer, unfolded: unfolded)
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            ThreadCard(
                author: conversation.author, verb: "opened this", at: conversation.createdAt,
                html: conversation.bodyHTML, reactions: conversation.reactions, base: conversation.url,
                compact: compact
            )
            between()
            if conversation.olderNotLoaded > 0 {
                Text("\(conversation.olderNotLoaded) older comments are only on GitHub")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            if fold.folded > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(fold.foldText).font(Theme.ui(12.5))
                }
                .foregroundStyle(Theme.fg2)
                .clickable()
                .onTapGesture { unfolded = true }
                .help("Show the comments you read")
            }
            ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                if index >= fold.folded {
                    if index == fold.divider { NewDivider(text: fold.dividerText) }
                    ThreadCard(
                        author: comment.author, verb: comment.verb, at: comment.createdAt, html: comment.bodyHTML,
                        reactions: comment.reactions, base: comment.url ?? conversation.url, compact: compact,
                        review: comment.review, hidden: comment.minimizedReason
                    )
                }
            }
        }
        .onAppear { loadAvatars() }
        .onChange(of: conversation.fetchedAt) { loadAvatars() }
    }

    private func loadAvatars() {
        guard !model.isFixture else { return }
        let people = ([conversation.author] + conversation.comments.map(\.author)).compactMap(\.self)
        var urls: [String: URL] = [:]
        for person in people {
            if let url = person.avatarURL.flatMap(URL.init(string:)) { urls[person.login.lowercased()] = url }
        }
        Avatars.shared.load(people.map(\.login), urls: urls)
    }
}

extension ThreadConversationView where Between == EmptyView {
    init(conversation: ThreadConversation, seenAt: Date? = nil, compact: Bool = false) {
        self.init(conversation: conversation, seenAt: seenAt, compact: compact) { EmptyView() }
    }
}

/// `──── new · 3 ────`
private struct NewDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Theme.busy.opacity(0.35).frame(height: 1)
            Text(text).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.busy).fixedSize()
            Theme.busy.opacity(0.35).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

/// One post: avatar, who and when, then GitHub's rendered body and its reactions.
private struct ThreadCard: View {
    let author: ThreadAuthor?
    let verb: String
    let at: Date
    let html: String
    let reactions: [ThreadReaction]
    let base: String
    let compact: Bool
    var review: String?
    var hidden: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PersonAvatar(login: author?.login ?? "ghost", size: compact ? 18 : 20)
                Text(author?.login ?? "ghost").font(Theme.ui(compact ? 12.5 : 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                if author?.isBot == true {
                    Text("bot").font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 5).background(Capsule().strokeBorder(Theme.line))
                }
                Text("\(verb) · \(Ages.long(at))").font(Theme.ui(compact ? 12 : 12.5)).foregroundStyle(verbColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 8 : 10)
            if let hidden {
                Text("Hidden on GitHub as \(hidden).").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, compact ? 12 : 16).padding(.bottom, 10)
            } else if !(review != nil && html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Theme.line.frame(height: 1)
                ThreadWebView(
                    html: html, base: base, background: compact ? ThreadWeb.page : ThreadWeb.card,
                    fontSize: compact ? 12.5 : 13.5
                )
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, compact ? 10 : 14)
            }
            if !reactions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(reactions, id: \.content) { reaction in
                        Text("\(reaction.emoji) \(reaction.count)").font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.bg3))
                            .overlay(Capsule().strokeBorder(Theme.line))
                    }
                }
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.bottom, compact ? 10 : 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The narrow Attention pane is bg2 itself: its cards sit darker.
        .background(RoundedRectangle(cornerRadius: 8).fill(compact ? Theme.bg : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(reviewTint?.opacity(0.5) ?? Theme.line))
    }

    private var reviewTint: Color? {
        switch review {
        case "APPROVED": Theme.done
        case "CHANGES_REQUESTED": Theme.err
        default: nil
        }
    }

    private var verbColor: Color { reviewTint ?? Theme.fg3 }
}

/// A person's GitHub avatar (cached like org avatars), or their first letter on a colour while there is none.
struct PersonAvatar: View {
    let login: String
    var size: CGFloat = 20

    var body: some View {
        if let image = Avatars.shared.image(for: login) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Text(String(login.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(OrgPalette.automatic(for: login).foreground.opacity(0.85)))
        }
    }
}

extension Ages {
    /// `4 min ago`, `2 h ago`, `3 d ago`; `just now` under a minute.
    static func long(_ date: Date, now: Date = Clock.now) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }
}
