import HeedCore
import SwiftUI

/// `go` over a session: its PRs' feedback pipeline (design/screens/PROverlay.png).
struct PullOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.feedbackPull {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Color.black.opacity(0.45).frame(width: min(330, geometry.size.width * 0.25))
                    VStack(spacing: 0) {
                        tabs(current: ref)
                        FeedbackPanel(ref: ref, wide: geometry.size.width > 1100)
                    }
                    .background(Theme.bg)
                }
            }
        }
    }

    private func tabs(current: PullRef) -> some View {
        HStack(spacing: 10) {
            ForEach(model.currentSession?.trackedPRs ?? [], id: \.self) { ref in
                HStack(spacing: 6) {
                    RepoChip(repo: ref.repo).fixedSize()
                    Text(verbatim: "#\(ref.number)").font(Theme.mono(12))
                        .foregroundStyle(ref == current ? Theme.fg : Theme.fg3)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ref == current ? Theme.fg3 : .clear))
            }
            KeyCap(text: "]p")
            KeyCap(text: "[p")
            Text("PRs of this session").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            Spacer()
            KeyCap(text: "go")
            Text("or").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            KeyCap(text: "⎋")
            Text("back to session").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The pipeline counts, the items, and how delivery stands. Shared by the overlay and the reader.
struct FeedbackPanel: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef
    var wide = true

    var body: some View {
        let pipeline = model.feedback[ref.description] ?? PullFeedback(ref: ref)
        let items = model.feedbackItems
        VStack(alignment: .leading, spacing: 14) {
            watchBar(pipeline)
            HStack(spacing: 8) {
                ForEach(FeedbackItem.Status.allCases, id: \.self) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pipeline.count(status))").font(Theme.ui(18, weight: .semibold))
                            .foregroundStyle(status == .queued && pipeline.count(status) > 0 ? Theme.block : Theme.fg)
                        Text(status.rawValue).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ListScroll {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            FeedbackRow(item: item, isCursor: index == model.feedbackCursor)
                        }
                        if items.isEmpty {
                            Text(model.pullDetails[ref.description] == nil ? "Fetching the PR…" : "No feedback yet.")
                                .font(Theme.ui(12.5))
                                .foregroundStyle(Theme.fg3)
                                .padding(20)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                }
                if wide { delivery(pipeline).frame(width: 300) }
            }
        }
        .padding(20)
    }

    private func watchBar(_ pipeline: PullFeedback) -> some View {
        // What applies, from a hand-set choice or the settings, and which.
        let effective = model.pilot(for: ref)
        let paused = pipeline.isPaused(Clock.now)
        return FlowLayout(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(effective.watching && !paused ? Theme.busy : Theme.fg3).frame(width: 7, height: 7)
                Text(!effective.watching ? "not watched" : paused ? "paused" : "watching")
                    .foregroundStyle(effective.watching && !paused ? Theme.busy : Theme.fg3)
                Text(pipeline.watchSet ? "set here" : "from \(model.config.pilot.watchSource(ref.repo)) settings")
                    .foregroundStyle(Theme.fg3)
            }
            .fixedSize()
            if let fetched = model.pullDetails[ref.description]?.fetchedAt {
                Text("fetched \(Clock.relative(fetched))").foregroundStyle(Theme.fg3)
                    .fixedSize()
            }
            Text("Green").foregroundStyle(Theme.fg2).fixedSize()
            HStack(spacing: 0) {
                ForEach(AutoFeed.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                        .font(Theme.ui(12, weight: mode == effective.green ? .semibold : .regular))
                        .foregroundStyle(mode == effective.green ? Theme.ink : Theme.fg2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(mode == effective.green ? Theme.inverse : .clear)
                        .fixedSize()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("round \(min(pipeline.rounds + 1, effective.maxRounds)) of \(effective.maxRounds)")
                .foregroundStyle(pipeline.rounds >= effective.maxRounds ? Theme.block : Theme.fg2)
                .fixedSize()
            Text(effective.merge == .off ? "merge off" : "merge \(effective.merge.configName)"
                + (model.pullDetails[ref.description]?.autoMergeEnabled == true ? " · auto-merge on" : ""))
                .foregroundStyle(effective.merge == .off ? Theme.fg3 : Theme.fg2)
                .fixedSize()
            HStack(spacing: 6) {
                KeyCap(text: model.keyText(for: "pilot.green"))
                Text("green").foregroundStyle(Theme.fg3)
                KeyCap(text: model.keyText(for: "pilot.merge"))
                Text("merge").foregroundStyle(Theme.fg3)
                KeyCap(text: model.keyText(for: "pilot.watch"))
                Text(effective.watching ? "stop watching" : "watch").foregroundStyle(Theme.fg3)
                KeyCap(text: model.keyText(for: "pilot.pause"))
                Text(paused ? "resume" : "pause").foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        }
        .font(Theme.ui(12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func delivery(_ pipeline: PullFeedback) -> some View {
        let session = model.sessions.first { $0.trackedPRs.contains(ref) }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Delivery")
                if let session {
                    Text("\(pipeline.queued.count) queued go to \(session.branch) as one prompt, once it is idle.")
                        .font(Theme.ui(12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        StateGlyph(state: session.state.state)
                        Text(session.state.state == .idle || session.state.state == .done
                            ? "Idle: ready to send." : "Now \(session.state.state.rawValue). Waiting.")
                    }
                    .font(Theme.ui(12.5))
                } else {
                    Text("No session tracks this PR, so nothing is sent.").font(Theme.ui(12.5))
                        .foregroundStyle(Theme.fg3)
                }
                Text(
                    "Never sent while the agent is blocked or asking. If you type in its pane first, delivery waits again."
                )
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .shotRegion(.delivery)
            if let prompt = pipeline.prompt() {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Prompt that will be sent")
                    Text(prompt).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(10)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
                .shotRegion(.promptPreview)
            }
            let mentions = model.suggestedLinks(for: ref)
            if !mentions.isEmpty {
                // PRs that link here but are not this session's own: someone else's, or older than the session.
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Also mentions it")
                    ForEach(mentions, id: \.ref) { mention in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(mention.ref.repo.name)#\(mention.ref.number) \(mention.title)")
                                .font(Theme.ui(12)).lineLimit(1)
                            Text(verbatim: "@\(mention.author ?? "ghost") · :pr.track \(mention.ref.url)")
                                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
            VStack(alignment: .leading, spacing: 8) {
                keyRow("space", "queue / unqueue")
                keyRow("s", "send queued now")
                keyRow("x", "dismiss item")
                keyRow("S", "new session from this PR")
                keyRow("gS", "full session view")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}

private struct FeedbackRow: View {
    let item: FeedbackItem
    let isCursor: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status == .new ? "square" : "checkmark.square.fill")
                .foregroundStyle(item.status == .resolved || item.status == .addressed ? Theme.done
                    : item.status == .new ? Theme.fg3 : Theme.block)
            VStack(alignment: .leading, spacing: 4) {
                switch item.kind {
                case let .review(location, author):
                    Text("@\(author) · \(location)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                case let .check(name):
                    Text("check · \(name) failed").font(Theme.mono(11.5)).foregroundStyle(Theme.err)
                case let .conflict(base, behind):
                    Text(behind ? "behind · \(base)" : "conflict · \(base)").font(Theme.mono(11.5))
                        .foregroundStyle(Theme.err)
                }
                Text(item.text).font(Theme.ui(13)).foregroundStyle(item.status == .resolved ? Theme.fg3 : Theme.fg)
                    .lineLimit(3)
                if let log = item.logPath {
                    Text("failed log: \(Paths.abbreviate(log))").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        .lineLimit(1).truncationMode(.head)
                }
                if let sent = item.sentAt {
                    Text(
                        "sent \(sent.formatted(date: .omitted, time: .shortened))\(item.resolvedAt.map { " → resolved \($0.formatted(date: .omitted, time: .shortened))" } ?? "")"
                    )
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.done)
                }
            }
            Spacer()
            Text(item.status.rawValue)
                .font(Theme.ui(11, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(statusColor.opacity(0.16)))
        }
        .padding(14)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var statusColor: Color {
        switch item.status {
        case .new: Theme.fg2
        case .queued: Theme.block
        case .sent: Theme.busy
        case .addressed, .resolved: Theme.done
        }
    }
}

/// The in-app reader for a PR (design/screens/Reader.png).
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.reader {
            let detail = model.pullDetails[ref.description]
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ListScroll {
                        VStack(alignment: .leading, spacing: 14) {
                            header(ref, detail)
                            if let detail {
                                card {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("\(detail.author ?? "someone") opened this").font(Theme.ui(12))
                                            .foregroundStyle(Theme.fg3)
                                        Text(detail.body.isEmpty ? "(no description)" : detail.body).font(Theme.ui(13))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                ForEach(detail.threads.filter { !$0.isResolved }) { thread in
                                    threadCard(
                                        thread,
                                        queued: model.feedback[ref.description]?.items
                                            .first { $0.id == thread.id }?.status == .queued
                                    )
                                }
                                ForEach(detail.failingChecks, id: \.name) { check in
                                    card {
                                        HStack(spacing: 8) {
                                            Text("\(check.name) failed").foregroundStyle(Theme.err)
                                            Text(check.summary).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                                                .lineLimit(1)
                                        }
                                        .font(Theme.ui(12.5))
                                    }
                                }
                                FeedbackPanel(ref: ref, wide: false).padding(-20).padding(.top, 20)
                            } else {
                                Text("Fetching \(ref)…").foregroundStyle(Theme.fg3)
                            }
                        }
                        .padding(24)
                    }
                    if geometry.size.width >= 1000 { side(ref, detail) }
                }
                .background(Theme.bg)
            }
        }
    }

    private func header(_ ref: PullRef, _ detail: PullDetail?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RepoChip(repo: ref.repo)
                Text(verbatim: "#\(ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                if let pull = model.github.pull(ref) { StateTag(state: pull.state, draft: pull.isDraft) }
                Spacer()
                KeyCap(text: "⌃o")
                Text("back").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            Text(detail?.title ?? model.github.pull(ref)?.title ?? "").font(Theme.ui(17, weight: .semibold))
            if let detail {
                Text(
                    "\(detail.headBranch) → \(detail.baseBranch) · \(detail.commitCount) commits · +\(detail.additions) −\(detail.deletions)"
                )
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.fg3)
            }
        }
    }

    private func threadCard(_ thread: ReviewThread, queued: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: queued ? "checkmark.square.fill" : "square")
                    .foregroundStyle(queued ? Theme.block : Theme.fg3)
                Text("@\(thread.author)").fontWeight(.medium)
                Text("commented on").foregroundStyle(Theme.fg3)
                Text(thread.location).font(Theme.mono(12))
                Spacer()
                if queued { Text("queued for session").foregroundStyle(Theme.fg3) }
            }
            .font(Theme.ui(12.5))
            .padding(12)
            if !thread.diff.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(thread.diff.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(line.hasPrefix("-") ? Theme.err : line.hasPrefix("+") ? Theme.done : Theme
                                .fg2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .background(line.hasPrefix("-") ? Theme.err.opacity(0.12)
                                : line.hasPrefix("+") ? Theme.done.opacity(0.12) : .clear)
                    }
                }
                .padding(.vertical, 6)
                .background(Theme.pane)
            }
            Text(thread.body).font(Theme.ui(13)).padding(12).fixedSize(horizontal: false, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(queued ? Theme.fg2 : Theme.line))
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func side(_ ref: PullRef, _ detail: PullDetail?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Linked")
            if let session = model.sessions.first(where: { $0.trackedPRs.contains(ref) }) {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state)
                    Text(session.branch).font(Theme.mono(12))
                }
            }
            ForEach(detail?.closes ?? [], id: \.self) { issue in
                HStack(spacing: 6) {
                    RepoChip(repo: issue.repo)
                    Text(verbatim: "closes #\(issue.number)").font(Theme.mono(12))
                }
            }
            SectionHeader(title: "Reviewers")
            ForEach(detail?.latestReviews ?? [], id: \.author) { review in
                Text("@\(review.author) · \(review.state.lowercased().replacingOccurrences(of: "_", with: " "))")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg2)
            }
            SectionHeader(title: "Checks")
            if let checks = detail?.checks ?? model.github.pull(ref)?.checks {
                Text("\(checks.passed) passed · \(checks.failed) failed · \(checks.pending) pending")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(checks.failed > 0 ? Theme.err : Theme.fg2)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                keyRow("space", "queue comment for session")
                keyRow("s", "send queued to session")
                keyRow("S", "start a new session from this PR")
                keyRow("gB", "open on GitHub")
                keyRow("gS", "jump to its session")
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}
