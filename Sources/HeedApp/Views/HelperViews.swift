import HeedCore
import SwiftUI

/// A button that runs a command, its key beside its label: what the helper views offer. `primary` is filled.
struct CommandButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    let command: String
    var arguments: [String] = []
    var scope: String?
    var primary = false
    var tint: Color = Theme.fg

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.ui(12.5, weight: .semibold))
            KeyCap(text: scope.map { model.keyText(for: command, in: $0) } ?? model.keyText(for: command))
        }
        .foregroundStyle(primary ? Theme.ink : tint)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : Theme.bg3))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : tint.opacity(0.25)))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command, arguments: arguments))
    }
}

/// `3 m 12 s`, `41 m`, `2 h 5 m`.
enum Elapsed {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        if total < 60 { return "\(total) s" }
        if total <
            3600 { return total < 600 ? "\(total / 60) m \(String(format: "%02d", total % 60)) s" : "\(total / 60) m" }
        return "\(total / 3600) h \(total % 3600 / 60) m"
    }

    /// `12.4k`.
    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000).replacingOccurrences(of: ".0k", with: "k")
            : "\(count)"
    }
}

/// The glyph a helper of each kind wears: ✓ green, ⇄ conflict, ☺ review.
struct HelperGlyph: View {
    let kind: HelperKind
    var size: CGFloat = 30

    var body: some View {
        Text(glyph)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(tint.opacity(0.14)))
    }

    private var glyph: String {
        switch kind {
        case .green: "✓"
        case .conflict: "⇄"
        case .review: "☺"
        }
    }

    var tint: Color {
        switch kind {
        case .green: Theme.busy
        case .conflict: Theme.ask
        case .review: Color(hex: 0x5BC8D8)
        }
    }
}

/// How a helper is doing, as a pill: `● working · 3 m 12 s · $0.04`.
struct HelperMeterPill: View {
    let helper: HelperRun

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(([helper.phase.text, Elapsed.text((helper.endedAt ?? Clock.now).timeIntervalSince(helper.startedAt))]
                    + (helper.usage.cost.map { ["$" + DollarsText.text($0)] } ?? []))
                .joined(separator: " · "))
        }
        .font(Theme.mono(11.5))
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
        .fixedSize()
    }

    private var color: Color {
        switch helper.phase {
        case .working, .starting: Theme.busy
        case .asking, .paused: Theme.block
        case .done, .closed: Theme.done
        case .stopped, .failed: Theme.err
        }
    }
}

// MARK: The split

/// A helper in a split: what it is and how it does on top, then its plan, its story with the diffs it made and what
/// it asks, and what it changed and spent; the steer box at the foot. Once its turn ended, its close-out instead.
struct HelperSplit: View {
    @Environment(AppModel.self) private var model
    let helper: HelperRun
    /// Under Attention's reader the header shows less: the reader above says what the PR is.
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.line.frame(height: 1)
            if helper.phase.awaitsCloseOut, helper.closeOut != nil {
                ListScroll { HelperCloseOutView(helper: helper).padding(20) }
                // Keep going: what you tell it starts another turn.
                if model.helpers.steer != nil { SteerBox(helper: helper) }
            } else {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 0) {
                        HelperPlan(helper: helper).frame(width: min(300, geometry.size.width * 0.24))
                        Theme.line.frame(width: 1)
                        HelperFeed(helper: helper).frame(maxWidth: .infinity)
                        if geometry.size.width > 760 {
                            Theme.line.frame(width: 1)
                            HelperSide(helper: helper).frame(width: min(300, geometry.size.width * 0.24))
                        }
                    }
                    .frame(height: geometry.size.height, alignment: .top)
                }
                if helper.phase.isLive || helper.phase.awaitsCloseOut { SteerBox(helper: helper) }
            }
        }
        .background(Theme.bg)
        .shotRegion(.helperSplit)
    }

    private var header: some View {
        HStack(spacing: 12) {
            HelperGlyph(kind: helper.kind, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(helper.headline).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                        .fixedSize()
                    Text("helper · \(helper.adapter)").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                .lineLimit(1)
                Text(details).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HelperMeterPill(helper: helper)
            if helper.phase.isLive {
                CommandButton(
                    label: helper.phase == .paused ? "Resume" : "Pause", command: "helper.pause", scope: scope
                )
                CommandButton(label: "Stop", command: "helper.stop", scope: scope, tint: Theme.err)
            }
            CommandButton(label: model.helpers.zoomed ? "Unzoom" : "Zoom", command: "helper.zoom", scope: scope)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.busy.opacity(0.05))
    }

    private var details: String {
        var parts = compact ? ["branch \(helper.branch)"] : [tilde(helper.worktree), "branch \(helper.branch)"]
        if helper.sessionID != nil { parts.append("your session was told") }
        if case let .failed(why) = helper.phase { parts = [why] }
        return parts.joined(separator: " · ")
    }

    private var scope: String { model.helperScope ?? "sessionshelper" }

    private func tilde(_ path: String) -> String {
        path.hasPrefix(Paths.home + "/") ? "~" + path.dropFirst(Paths.home.count) : path
    }
}

/// The agent's plan, step by step, with the one under way lit; honest when the agent sends none.
private struct HelperPlan: View {
    let helper: HelperRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = helper.planProgress {
                SectionHeader(title: "Plan · \(progress.step) of \(progress.of)")
            } else {
                SectionHeader(title: "Plan")
            }
            if helper.plan.isEmpty {
                Text("\(helper.agent) sends no plan; its story is on the right.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(helper.plan.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 10) {
                    mark(entry.status).padding(.top, 1)
                    Text(entry.content)
                        .font(Theme.ui(12.5, weight: entry.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(entry.status == .inProgress ? Theme.block : entry.status == .completed
                            ? Theme.fg2 : Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !helper.plan.isEmpty {
                Text("The plan is the agent's own and updates as it goes.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func mark(_ status: ACPPlanEntry.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.done).font(.system(size: 14))
        case .inProgress:
            Image(systemName: "circle.dotted").foregroundStyle(Theme.busy).font(.system(size: 14, weight: .bold))
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.fg3).font(.system(size: 14))
        }
    }
}

/// What the helper said and did, in order, newest last: messages, tool calls with their small diffs, and a
/// permission it waits on with its answers inline.
private struct HelperFeed: View {
    let helper: HelperRun

    var body: some View {
        if ShotMode.active {
            // Shots draw the story's end, where it is now, as the live view scrolls to it.
            GeometryReader { geometry in
                story.frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                    .clipped()
            }
        } else {
            ScrollView { story.frame(maxWidth: .infinity, alignment: .leading) }.defaultScrollAnchor(.bottom)
        }
    }

    private var story: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The last of a long story: what fits shows, the newest at the foot.
            ForEach(helper.feed.suffix(12)) { entry in
                HStack(alignment: .top, spacing: 14) {
                    Text(Self.time(entry.at)).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        .frame(width: 40, alignment: .leading).padding(.top, 2)
                    line(entry)
                }
            }
            if let permission = helper.permission { PermissionCard(helper: helper, permission: permission) }
            if helper.feed.isEmpty {
                Text("Starting \(helper.adapter)…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(16)
    }

    @ViewBuilder private func line(_ entry: HelperEntry) -> some View {
        switch entry.body {
        case let .message(text):
            Text(text).font(Theme.ui(13)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .tool(tool):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(Self.glyph(tool.kind)).foregroundStyle(Theme.fg3)
                    Text(tool.title).foregroundStyle(tool.status == .failed ? Theme.err : Theme.fg2).lineLimit(1)
                    if tool.status == .inProgress || tool.status == .pending {
                        Text("…").foregroundStyle(Theme.busy)
                    }
                }
                .font(Theme.mono(11.5))
                ForEach(Array(tool.diffs.prefix(2).enumerated()), id: \.offset) { _, diff in SmallDiff(diff: diff) }
                if let output = tool.output, tool.diffs.isEmpty {
                    Text(output).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(3)
                }
            }
        case let .permission(title, answer):
            Text("asked to run \(title)" + (answer.map { ": \($0)" } ?? ""))
                .font(Theme.mono(11.5)).foregroundStyle(answer == nil ? Theme.block : Theme.fg3)
        case let .steer(text):
            (Text("you › ").foregroundStyle(Theme.busy) + Text(text).foregroundStyle(Theme.fg))
                .font(Theme.ui(12.5))
        case let .note(text):
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func glyph(_ kind: ACPToolKind) -> String {
        switch kind {
        case .read: "▤"
        case .edit: "✎"
        case .delete: "✕"
        case .move: "⇢"
        case .search: "⌕"
        case .execute: "▸"
        case .think: "…"
        case .fetch: "⇣"
        case .switchMode, .other: "•"
        }
    }

    static func time(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

/// One edit's diff, small: its file, +/−, and its changed lines (context dropped), at most eight.
struct SmallDiff: View {
    let diff: HelperDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.path).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(diff.added)").foregroundStyle(Theme.done)
                Text("−\(diff.removed)").foregroundStyle(Theme.err)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            ForEach(Array(changed.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(line.kind == .added ? "+" : "−").foregroundStyle(line.kind == .added ? Theme.done : Theme.err)
                    Text(line.text).foregroundStyle(Theme.terminalText).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.mono(11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 1.5)
                .background((line.kind == .added ? Theme.done : Theme.err).opacity(0.08))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var changed: [DiffLine] { Array(diff.lines.filter { $0.kind != .context }.prefix(4)) }
}

/// What the helper waits on, with its answers: Allow, Always (when the agent offers it), Deny.
private struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let helper: HelperRun
    let permission: HelperPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("Wants to run ").foregroundStyle(Theme.block).font(Theme.ui(13.5, weight: .semibold))
                + Text(permission.command ?? permission.title).font(Theme.mono(13)).foregroundStyle(Theme.fg))
                .fixedSize(horizontal: false, vertical: true)
            if permission.command != nil, permission.title != permission.command {
                Text(permission.title).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            HStack(spacing: 10) {
                if permission.option(.allowOnce) != nil {
                    CommandButton(label: "Allow", command: "helper.allow", scope: scope, primary: true)
                }
                if permission.option(.allowAlways) != nil {
                    CommandButton(label: "Always", command: "helper.allow.always", scope: scope)
                }
                CommandButton(label: "Deny", command: "helper.deny", scope: scope)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.block.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.5)))
        .padding(.leading, 54)
    }

    private var scope: String { model.helperScope ?? "sessionshelper" }
}

/// What it used and changed: tokens and cost against its cap, the files with their lines, and what happens next.
private struct HelperSide: View {
    let helper: HelperRun

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                meter(
                    helper.usage.tokens > 0 ? Elapsed.tokens(helper.usage.tokens) : "–",
                    helper.usage.window > 0 ? "tokens of \(Elapsed.tokens(helper.usage.window))" : "tokens"
                )
                meter(
                    helper.usage.cost.map { "$" + DollarsText.text($0) } ?? "–",
                    helper.usage.cost == nil ? "cost not reported"
                        : helper.cap > 0 ? "so far · cap $\(DollarsText.text(helper.cap))" : "so far · no cap"
                )
            }
            SectionHeader(title: "Files · +\(helper.addedLines) −\(helper.removedLines)")
            if helper.files.isEmpty {
                Text("Nothing changed yet.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            ForEach(helper.files, id: \.path) { file in
                HStack(spacing: 8) {
                    Text((file.path as NSString).lastPathComponent).font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    Spacer()
                    if file.added > 0 { Text("+\(file.added)").font(Theme.mono(11)).foregroundStyle(Theme.done) }
                    if file.removed > 0 { Text("−\(file.removed)").font(Theme.mono(11)).foregroundStyle(Theme.err) }
                }
            }
            SectionHeader(title: "When it's done")
            Text(then).font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var then: String {
        switch helper.kind {
        case .review:
            "heed shows you the comments it drafted. Nothing is posted until you send it."
        case .green, .conflict:
            "heed shows you the change, then pushes to \(helper.prBranch) and replies on the threads once you "
                + "approve." + (helper.sessionID != nil ? " Your session gets a note to pull." : "")
        }
    }

    private func meter(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
    }
}

/// `i`: what you tell the helper. Typing goes here while it is open; ↩ sends, ⎋ closes.
private struct SteerBox: View {
    @Environment(AppModel.self) private var model
    let helper: HelperRun

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(text: model.keyText(for: "helper.steer", in: model.helperScope ?? "sessionshelper"))
            Group {
                if let box = model.helpers.steer {
                    CaretText(input: box, caret: Theme.busy).font(Theme.ui(13))
                } else {
                    Text(helper.phase.awaitsCloseOut ? "Keep going: tell it what else to do…"
                        : "Tell it something… e.g. \"keep the old overload for compatibility\"")
                        .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                model.helpers.steer != nil ? Theme.busy.opacity(0.6) : Theme.line
            ))
            .clickRuns(model.helpers.steer == nil ? CommandInvocation(name: "helper.steer") : nil)
            if model.helpers.steer != nil { KeyHint(keys: "<CR>", label: "send") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}

// MARK: Close-out

/// A helper whose turn ended: what it did, what heed will post, and what you do with it.
struct HelperCloseOutView: View {
    @Environment(AppModel.self) private var model
    let helper: HelperRun

    var body: some View {
        let closeOut = helper.closeOut ?? HelperCloseOut()
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                head(closeOut)
                Theme.line.frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    did(closeOut).frame(maxWidth: .infinity, alignment: .topLeading)
                    Theme.line.frame(width: 1)
                    posts(closeOut).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Theme.line.frame(height: 1)
                actions(closeOut)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            if model.helpers.showDiff { diff }
            if helper.sessionID != nil, helper.kind != .review { sessionStrip(closeOut) }
        }
        .frame(maxWidth: 1100, alignment: .leading)
        .shotRegion(.helperCloseOut)
    }

    private func head(_ closeOut: HelperCloseOut) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: stopped ? "pause.circle.fill" : "checkmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(stopped ? Theme.block : Theme.done)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill((stopped ? Theme.block : Theme.done).opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(17, weight: .semibold))
                Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            }
            Spacer()
            Text(closeOut.pushedSHA
                .map { "pushed \($0.prefix(7))" } ?? "nothing \(helper.kind == .review ? "posted" : "pushed") yet")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
        }
        .padding(18)
    }

    private var stopped: Bool {
        if case .stopped = helper.phase { return true }
        return false
    }

    private var title: String {
        if case let .stopped(why) = helper.phase { return "\(helper.headline) stopped: \(why)" }
        switch helper.kind {
        case .green: return "#\(helper.ref.number) is ready on the helper's branch"
        case .conflict: return "#\(helper.ref.number)'s conflict is resolved on the helper's branch"
        case .review: return "Your review of #\(helper.ref.number) is drafted"
        }
    }

    private var subtitle: String {
        var parts = [helper.adapter, Elapsed.text((helper.endedAt ?? Clock.now).timeIntervalSince(helper.startedAt))]
        if helper.usage.tokens > 0 { parts.append("\(Elapsed.tokens(helper.usage.tokens)) tokens") }
        if let cost = helper.usage.cost { parts.append("$" + DollarsText.text(cost)) }
        if helper
            .approvals > 0 { parts.append("\(helper.approvals) approval\(helper.approvals == 1 ? "" : "s") from you") }
        return parts.joined(separator: " · ")
    }

    private func did(_ closeOut: HelperCloseOut) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What it did")
            if closeOut.did.isEmpty {
                Text(closeOut.summary.isEmpty ? "It said nothing about what it did." : closeOut.summary)
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(8)
            }
            ForEach(Array(closeOut.did.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    Text("✓").foregroundStyle(Theme.done)
                    Text(line).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.ui(13))
            }
            if helper.kind != .review {
                HStack(spacing: 10) {
                    (Text("\(helper.files.count) file\(helper.files.count == 1 ? "" : "s") · ")
                        .foregroundStyle(Theme.fg2)
                        + Text("+\(helper.addedLines) ").foregroundStyle(Theme.done)
                        + Text("−\(helper.removedLines)").foregroundStyle(Theme.err))
                        .font(Theme.mono(11.5))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                    CommandButton(label: "See the diff", command: "helper.diff", scope: scope)
                }
                .padding(.top, 4)
                if closeOut.dirty {
                    Text("Some changes are not committed: pushing commits them first.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(18)
    }

    private func posts(_ closeOut: HelperCloseOut) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What heed will post")
            if closeOut.replies.isEmpty {
                Text(helper.kind == .review ? "No comments: the review is its summary." : "No replies drafted.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            }
            ForEach(closeOut.replies) { reply in
                VStack(alignment: .leading, spacing: 4) {
                    Text((reply.threadID != nil ? "reply on " : "comment on ") + reply.place)
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    Text(reply.text).font(Theme.ui(13)).foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
            if helper.kind == .review, let verdict = closeOut.verdict {
                Text("As one review: \(verdict).").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(18)
    }

    private func actions(_: HelperCloseOut) -> some View {
        HStack(spacing: 10) {
            if helper.kind == .review {
                CommandButton(label: "Post the review", command: "helper.push", scope: scope, primary: true)
            } else {
                CommandButton(label: "Push and reply", command: "helper.push", scope: scope, primary: true)
                CommandButton(label: "Push only", command: "helper.push.only", scope: scope)
            }
            CommandButton(label: "Keep going", command: "helper.steer", scope: scope)
            CommandButton(label: "Throw away", command: "helper.throwaway", scope: scope)
            Spacer()
            if helper.kind != .review {
                Text("Always push when it's green → Autopilot › Green").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .clickRuns(CommandInvocation(name: "autopilot.cando"))
            }
        }
        .padding(16)
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 10) {
            let files = model.helpers.diff[helper.id] ?? []
            if files.isEmpty {
                // Until git answers (and in the fake world): the diffs the agent reported, edit by edit.
                let reported = helper.feed.compactMap { entry -> HelperTool? in
                    if case let .tool(tool) = entry.body, !tool.diffs.isEmpty { return tool }
                    return nil
                }.flatMap(\.diffs)
                ForEach(reported.indices, id: \.self) { SmallDiff(diff: reported[$0]) }
            }
            ForEach(files) { file in
                SmallDiff(diff: HelperDiff(path: file.path, lines: file.hunks.flatMap(\.lines)))
            }
        }
    }

    private func sessionStrip(_ closeOut: HelperCloseOut) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("IN YOUR\nSESSION").font(Theme.ui(10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.fg3)
            HelperGlyph(kind: helper.kind, size: 26)
            let title = model.sessions.first { $0.id == helper.sessionID }?.title ?? "your session"
            (Text("After pushing, heed tells ") + Text(title).bold() + Text(": ")
                +
                Text(
                    "\"\(HelperPrompt.pushedNote(helper, sha: closeOut.pushedSHA ?? "a3f9c1d", did: closeOut.did))\""
                )
                .font(Theme.mono(12)))
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("as a band on the session,\nnever typed").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private var scope: String { model.helperScope ?? "sessionshelper" }
}

// MARK: Attention

/// heed's next step in the reader: the one proposal, its steps, and its keys (D, Y, .).
struct NextStepProposal: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem
    let step: NextStep

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "play.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.busy)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.busy.opacity(0.14)))
            VStack(alignment: .leading, spacing: 8) {
                Text("Heed's next step: \(step.title)").font(Theme.ui(14.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if step.steps.isEmpty {
                    Text(note).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(step.steps, id: \.self) { text in
                            Text(text).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                                .padding(.horizontal, 8).frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            if let button = step.button {
                CommandButton(label: button, command: "helper.do", scope: scope, primary: true)
            }
            if step.capability != nil, let repo = item.repo {
                CommandButton(label: "Always in \(repo.name)", command: "helper.always", scope: scope)
            }
            CommandButton(label: "Other", command: "helper.other", scope: scope)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.busy.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.busy.opacity(0.35)))
        .shotRegion(.nextStep)
    }

    /// What it promises, and when helpers cannot run, why not and what fixes it.
    private var note: String {
        if case .review = step, let availability = model.helpers.availability, !availability.isReady {
            return availability.text
        }
        return step.note
    }

    private var scope: String { model.helperScope ?? "attention" }
}

/// The reader's actions when heed has no step to propose (or a helper's split is open): one slim line, each with its
/// key, so they stay a click away. Why there is nothing to do leads it.
struct ReaderActionsLine: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem
    let step: NextStep?

    var body: some View {
        HStack(spacing: 12) {
            if case let .nothing(why) = step {
                Text("\(why) · nothing to do").font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(1).fixedSize()
            }
            FlowLayout(spacing: 4) {
                ForEach(OtherMenu.actions(item), id: \.self) { action in
                    HStack(spacing: 5) {
                        Text(action.label).foregroundStyle(Theme.fg2)
                        KeyCap(text: key(action))
                    }
                    .font(Theme.ui(12))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .clickRuns(CommandInvocation(name: action.command))
                }
            }
        }
        .padding(.vertical, 2)
        .shotRegion(.nextStep)
    }

    private func key(_ action: OtherMenu.Action) -> String {
        model.keyText(for: action.command, asIn: action.scope ?? "attention")
    }
}

/// Other (`.`): the item's other next steps (picking one proposes it), then what else you can do with it, each with
/// its key. `j` `k` move, `↩` or a click does the row, `⎋` or `.` closes it.
struct OtherMenuView: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    var body: some View {
        let entries = model.otherMenuEntries(for: item)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                let on = index == model.helpers.otherRow
                HStack(spacing: 10) {
                    Text(entry.label).font(Theme.ui(12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(isStep(entry) ? Theme.busy : Theme.fg)
                    Spacer(minLength: 16)
                    if case let .action(action) = entry {
                        KeyCap(text: model.keyText(for: action.command, asIn: action.scope ?? "attention"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(on ? Theme.bg3 : .clear)
                .contentShape(Rectangle())
                .clickRuns(CommandInvocation(name: "helper.menu.pick", arguments: ["\(index)"]))
                if index + 1 < entries.count, isStep(entry), !isStep(entries[index + 1]) {
                    Theme.line.frame(height: 1).padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .shotRegion(.otherMenu)
    }

    private func isStep(_ entry: OtherMenu.Entry) -> Bool {
        if case .action = entry { return false }
        return true
    }
}

// MARK: Autopilot › Now

/// A helper at work, as a tile in Now: what it is, what it does now, its plan as pips, the files it touched, its
/// last tool calls, and what it asks.
struct HelperTile: View {
    @Environment(AppModel.self) private var model
    let helper: HelperRun
    let isCursor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HelperGlyph(kind: helper.kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(helper.headline).font(Theme.ui(13.5, weight: .semibold)).lineLimit(1)
                    Text("\(helper.ref.repo.name) · \(helper.agent) · \(Ages.short(helper.startedAt))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle().fill(HelperGlyph(kind: helper.kind).tint).frame(width: 8, height: 8).padding(.top, 4)
            }
            (Text("NOW ").font(Theme.ui(10.5, weight: .bold)).foregroundStyle(Theme.fg3)
                + Text(nowText).font(Theme.ui(12.5)).foregroundStyle(Theme.fg))
                .lineLimit(1)
            if !helper.plan.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(helper.plan.enumerated()), id: \.offset) { _, entry in
                        Capsule().fill(entry.status == .pending ? Theme.line : HelperGlyph(kind: helper.kind).tint
                            .opacity(entry.status == .completed ? 1 : 0.55))
                            .frame(height: 4)
                    }
                }
            }
            if !helper.files.isEmpty {
                Text(helper.files.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: " · "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            if let permission = helper.permission {
                HStack {
                    Text("wants to run \(permission.command ?? permission.title)").font(Theme.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.block).lineLimit(1)
                    Spacer()
                    KeyCap(text: "y")
                    Text("allow").font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.block.opacity(0.5)))
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(helper.recentTools(3), id: \.id) { tool in
                    Text("\(HelperTileGlyph.of(tool.kind)) \(tool.title)").font(Theme.mono(11))
                        .foregroundStyle(Theme.fg3)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 270, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            isCursor ? Theme.busy : Theme.line,
            lineWidth: isCursor ? 1.5 : 1
        ))
        .clickRuns(CommandInvocation(name: "helper.watch"))
    }

    private var nowText: String {
        if helper.phase.awaitsCloseOut { return "done: waiting for your close-out" }
        if case let .failed(why) = helper.phase { return why }
        // What it asks has its own box below: the line says the step it is on.
        if helper.permission != nil, let step = helper.plan.first(where: { $0.status == .inProgress }) {
            return step.content
        }
        return helper.now ?? helper.phase.text
    }
}

enum HelperTileGlyph {
    static func of(_ kind: ACPToolKind) -> String {
        switch kind {
        case .edit: "✎"
        case .execute: "▸"
        case .read: "▤"
        case .search: "⌕"
        default: "•"
        }
    }
}

/// Now's top: the helpers at work, one tile each (h l move, ↩ opens one in a split under them).
struct HelperTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.helpers.active
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(active.count) helper\(active.count == 1 ? "" : "s") at work")
                    .font(Theme.ui(17, weight: .semibold))
                Text("each in its own worktree, beside your sessions · ↩ opens one in a split")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                Spacer()
                if let availability = model.helpers.availability, !availability.isReady {
                    Text(availability.text).font(Theme.ui(11.5)).foregroundStyle(Theme.block).lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(active.prefix(4).enumerated()), id: \.element.id) { index, helper in
                    HelperTile(helper: helper, isCursor: model.helpers.tile == index)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .shotRegion(.helperTiles)
    }
}

// MARK: Sessions

/// The one line at the foot of a session's panes while helpers work on its PRs, however many: what needs you
/// first, then what works, then what waits, and finished runs until you have seen them. Quiet by default, amber when
/// one needs you, lit briefly when a run moves a step or finishes. A click (or `gW`) watches the one run, or lists
/// them. Nothing is typed into the session.
struct SessionHelperLineView: View {
    @Environment(AppModel.self) private var model
    let line: SessionHelperLine
    @State private var lit = false

    var body: some View {
        HStack(spacing: 10) {
            sentence.lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if !line.finished.isEmpty {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.fg3)
                    .frame(width: 18, height: 18)
                    .clickRuns(CommandInvocation(name: "helper.dismiss"))
                    .help("Take the finished helpers off the line")
            }
            if line.asks {
                // What it asks is in the approvals with every other agent's: gy answers it there.
                HStack(spacing: 6) {
                    Text("answer").foregroundStyle(Theme.block)
                    KeyCap(text: model.keyText(for: "approvals.open"))
                }
                .font(Theme.ui(11.5))
                .clickRuns(CommandInvocation(name: "approvals.open"))
            }
            HStack(spacing: 6) {
                Text(hint).foregroundStyle(Theme.fg3)
                KeyCap(text: model.keyText(for: "helper.watch"))
            }
            .font(Theme.ui(11.5))
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(line.needsYou ? Theme.block.opacity(0.09) : lit ? Theme.busy.opacity(0.14) : Theme.bg2)
        .overlay(alignment: .top) { (line.needsYou ? Theme.block.opacity(0.55) : Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: "helper.watch"))
        .onChange(of: line.signature) {
            guard !ShotMode.active else { return }
            withAnimation(.easeIn(duration: 0.15)) { lit = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.6)) { lit = false }
            }
        }
        .shotRegion(.helperLine)
    }

    /// The parts, each in its standing's colour, joined by dots.
    private var sentence: Text {
        line.parts.enumerated().reduce(Text("")) { text, part in
            let piece = Text(part.element.text).foregroundStyle(color(part.element.standing))
                .fontWeight(part.element.standing == nil ? .semibold : .regular)
            return part.offset == 0 ? piece : text + Text(" · ").foregroundStyle(Theme.fg3) + piece
        }
    }

    private func color(_ standing: SessionHelperLine.Standing?) -> Color {
        switch standing {
        case nil: line.needsYou ? Theme.block : Theme.fg2
        case .needsYou: Theme.block
        case .working: Theme.fg2
        case .waiting: Theme.fg3
        case .finished: Theme.done
        }
    }

    private var hint: String {
        if line.entries.count > 1 { return model.helpers.listOpen ? "close" : "list" }
        return model.visibleHelper?.id == line.entries.first?.id ? "hide" : "watch"
    }
}

/// `gW` with more than one helper on the session's PRs: one row per run over the helper line, Watch (`↩`) and Take
/// it over (`gO`) on the row under the cursor, `x` takes a finished one off the line.
struct SessionHelperList: View {
    @Environment(AppModel.self) private var model
    let line: SessionHelperLine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(line.entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, index: index, on: index == model.helpers.listRow)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.bg2)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .shotRegion(.helperList)
    }

    private func row(_ entry: SessionHelperLine.Entry, index: Int, on: Bool) -> some View {
        let run = model.helpers.run(entry.id)
        return HStack(spacing: 10) {
            HelperGlyph(kind: entry.kind, size: 20)
            Text(verbatim: entry.headline).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.fg)
                .lineLimit(1)
            Text(entry.status).font(Theme.ui(12)).lineLimit(1)
                .foregroundStyle(entry.standing == .needsYou ? Theme.block
                    : entry.standing == .finished ? Theme.done : Theme.fg2)
            if entry.standing == .finished, let delivery = delivery(entry) {
                Text(delivery).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if on {
                CommandButton(
                    label: "Watch", command: "helper.menu.pick", arguments: ["\(index)"], scope: "sessionshelpers"
                )
                if let run, run.phase.isLive || run.phase.awaitsCloseOut {
                    CommandButton(label: "Take it over", command: "helper.takeover", arguments: ["\(index)"])
                }
                if entry.standing == .finished {
                    CommandButton(label: "Dismiss", command: "helper.dismiss", scope: "sessionshelpers")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(on ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if on { Theme.busy.frame(width: 2) } }
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: "helper.menu.pick", arguments: ["\(index)"]))
    }

    /// How the session's agent got heed's note about this one: through its channel, or the line only.
    private func delivery(_ entry: SessionHelperLine.Entry) -> String? {
        guard let session = model.currentSession, let notice = model.helpers.notices[session.id],
              notice.helperID == entry.id, let outcome = notice.outcome
        else { return nil }
        return outcome.sent ? "its agent was told \(outcome.summary)" : "shown here only"
    }
}
