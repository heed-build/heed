import HeedCore
import SwiftUI

/// `gy`: every permission request agents wait on, oldest first. The list on the left (the first selected), what it
/// asks on the right; y and n answer the selected one and move on, Y and N all of them. ⎋ closes; they keep waiting.
struct ApprovalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.approvalGroups
        let selected = model.selectedApproval
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 0) {
                header(groups.count)
                Theme.line.frame(height: 1)
                HStack(spacing: 0) {
                    // Plain stacks, not scroll views: the list keeps the selected row in sight by starting there.
                    VStack(spacing: 0) {
                        ForEach(Array(visible(groups, selected: selected)), id: \.element.id) { index, group in
                            ApprovalRow(group: group, selected: group.id == selected?.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.approvals.cursor = index
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 460)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .background(Theme.bg2)
                    Theme.line.frame(width: 1)
                    if let selected { ApprovalDetail(group: selected) } else { Spacer() }
                }
                .frame(height: 360)
                Theme.line.frame(height: 1)
                footer(groups)
            }
            .frame(width: 1040)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(count) waiting for your OK").font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(
                "oldest first · \(key("approvals.allow")) \(key("approvals.deny")) answer the selected one and move on"
                    + " · \(key("approvals.allow.all")) \(key("approvals.deny.all")) all of them"
            )
            .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func footer(_ groups: [ApprovalGroup]) -> some View {
        let answerable = groups.count(where: \.answerable)
        return HStack(spacing: 10) {
            ApprovalButton(label: "Allow all \(answerable)", command: "approvals.allow.all")
            ApprovalButton(label: "Deny all", command: "approvals.deny.all")
            if groups.contains(where: \.safeRead) {
                ApprovalButton(label: "Allow all read only", command: "approvals.allow.read")
            }
            Spacer()
            Text("each answer goes back through the agent's own hook or helper · ⎋ closes, they keep waiting")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func key(_ command: String) -> String { model.keyText(for: command, in: "approvals") }

    /// The rows that fit (six), from one that keeps the selected row among them, with their indexes.
    private func visible(_ groups: [ApprovalGroup], selected: ApprovalGroup?) -> ArraySlice<(
        offset: Int,
        element: ApprovalGroup
    )> {
        let rows = Array(groups.enumerated())
        let index = selected.flatMap { s in groups.firstIndex { $0.id == s.id } } ?? 0
        let start = max(0, min(index - 4, rows.count - 6))
        return rows[start ..< min(rows.count, start + 6)]
    }
}

/// One request in the list: how long it has waited, what it asks, where and who, its worst risk.
private struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    let group: ApprovalGroup
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(group.waited(Clock.now)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(Theme.ui(13.5)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(ApprovalText.who(group, in: model)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let tag = group.tags.first { RiskTag(tag: tag) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(selected ? Theme.selected : Color.clear)
        .overlay(alignment: .leading) { if selected { Theme.block.frame(width: 3) } }
    }
}

/// The selected request whole: its tags, where and in which mode, what it would run or change, why, and the keys.
private struct ApprovalDetail: View {
    @Environment(AppModel.self) private var model
    let group: ApprovalGroup

    var body: some View {
        let ask = group.first
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(group.tags, id: \.self) { RiskTag(tag: $0) }
                Text(ApprovalText.context(
                    group,
                    title: ask.helper.map { "\($0.headline): \($0.title)" }
                        ?? model.sessions.first { $0.id == ask.session }?.title,
                    in: model
                ))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            Text(group.title).font(Theme.ui(17, weight: .semibold)).foregroundStyle(Theme.fg)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(ApprovalText.body(ask).prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(Theme.mono(12)).foregroundStyle(line.color).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            if let why = ApprovalText.why(group) {
                (Text("Why it asks: ").fontWeight(.semibold).foregroundStyle(Theme.fg) + Text(why))
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            FlowLayout(spacing: 8) {
                ApprovalButton(
                    label: group.answerable ? "Allow" : "Allow (Return in its pane)",
                    command: "approvals.allow",
                    primary: true
                )
                ApprovalButton(label: group.answerable ? "Deny" : "Answer in its pane", command: "approvals.deny")
                if group.takesReason {
                    ApprovalButton(label: "Deny and tell it why", command: "approvals.deny.reason")
                }
                if group.canAlways {
                    ApprovalButton(
                        // A helper's agent names its own always ("Always Allow"); a hook's is saved in the repo.
                        label: ask.options.first { $0.kind == .allowAlways }?.name
                            ?? "Always in \(ApprovalText.repo(of: ask, in: model) ?? "this repo")",
                        command: "approvals.always"
                    )
                }
                ApprovalButton(
                    label: ask.channel == .helper ? "Watch the helper" : "Open its session",
                    command: "approvals.session"
                )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A button with its key, which runs what the key runs.
private struct ApprovalButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    let command: String
    var primary = false

    var body: some View {
        KeyHint(command, scope: "approvals") {
            Text(label).fontWeight(primary ? .semibold : .regular)
        }
        .font(Theme.ui(12.5))
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Color.clear : Theme.line))
    }
}

/// A risk tag: red for what reaches outside, amber for the network and GitHub, green for read only.
struct RiskTag: View {
    let tag: PermissionRisk

    var body: some View {
        let color: Color = switch tag {
        case .outsideWorktree: Theme.err
        case .writesGitHub, .network: Theme.block
        case .readOnly: Theme.done
        }
        Text(tag.rawValue).font(Theme.mono(11)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.14)))
            .fixedSize()
    }
}

/// The title bar's pill when agents wait on permission: their avatars, how many, and the key.
struct ApprovalPill: View {
    @Environment(AppModel.self) private var model
    let summary: ApprovalSummary
    let compact: Bool

    var body: some View {
        KeyHint("approvals.open") {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    // One avatar per kind of agent: two claude sessions are one `cl`.
                    let kinds = summary.agentNames.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    ForEach(Array(kinds.prefix(3).enumerated()), id: \.offset) { _, agent in
                        Text(ApprovalSummary.initials(agent)).font(Theme.mono(9, weight: .bold))
                            .foregroundStyle(Theme.fg)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.ink))
                            .overlay(Circle().strokeBorder(Theme.block, lineWidth: 1))
                    }
                }
                Text(compact ? "\(summary.asks)" : summary.text).font(Theme.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.ink).fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.block))
        .help("Agents waiting for your OK: \(model.keyText(for: "approvals.open")) answers them in one place")
    }
}

/// The slim amber strip on top of a waiting agent's pane: what it asks, Allow and Deny, and the key for all of them.
struct ApprovalStrip: View {
    @Environment(AppModel.self) private var model
    let group: ApprovalGroup

    var body: some View {
        let ask = group.first
        HStack(spacing: 10) {
            Text("\(ask.agent) wants to \(ask.title.prefix(1).lowercased() + ask.title.dropFirst())")
                .font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.block).lineLimit(1)
                .layoutPriority(1)
            Text(ask.subject).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if group.answerable {
                stripButton("Allow") { model.answer(group, PermissionAnswer(.allow)) }
                stripButton("Deny") { model.answer(group, PermissionAnswer(.deny)) }
            } else {
                Text("answer in the pane below").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
            KeyHint("approvals.open") {
                Text(model.approvalGroups.count > 1 ? "all \(model.approvalGroups.count)" : "approvals")
                    .foregroundStyle(Theme.fg3).fixedSize()
            }
            .font(Theme.ui(11.5))
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.block.opacity(0.10))
        .overlay(alignment: .bottom) { Theme.block.opacity(0.4).frame(height: 1) }
    }

    private func stripButton(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label).font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// The words the approvals views show, from the domain.
@MainActor
enum ApprovalText {
    struct Line {
        var text: String
        var color: Color
    }

    /// `ingest · codex`, `docs-toolkit · claude ×2`, `markgraph · Explore · claude`.
    static func who(_ group: ApprovalGroup, in model: AppModel) -> String {
        let ask = group.first
        if let helper = ask.helper, ask.channel == .helper {
            // `docs-toolkit #2841 · helper · claude`: the PR it works on, then who.
            let agents = group.asks.count
            return "\(helper.repo) #\(helper.number) · \(ask.agent)" + (agents > 1 ? " ×\(agents)" : "")
        }
        let session = model.sessions.first { $0.id == ask.session }
        let place = ask.cwd.map { ($0 as NSString).lastPathComponent }
            ?? session.map { $0.branch.isEmpty ? $0.title : $0.branch } ?? ask.session
        var parts = [place]
        if let subagent = ask.subagent { parts.append(subagent) }
        let agents = group.asks.map(\.agent)
        parts.append(agents.count > 1 ? "\(ask.agent) ×\(agents.count)" : ask.agent)
        return parts.joined(separator: " · ")
    }

    /// The line over the title: where, who, the session, the agent's mode.
    static func context(_ group: ApprovalGroup, title: String?, in model: AppModel) -> String {
        var parts = [who(group, in: model)]
        if let title { parts.append(title) }
        if let mode = group.first.mode { parts.append("mode: \(mode)") }
        if !group.answerable { parts.append("asks in its pane") }
        return parts.joined(separator: " · ")
    }

    /// What it would run or change: the command, the files with the patch, the page.
    static func body(_ ask: PermissionAsk) -> [Line] {
        var lines: [Line] = []
        if let command = ask.command {
            lines += command.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(text: String($0), color: Theme.terminalText) }
        }
        for path in ask.paths {
            lines.append(Line(text: Paths.tilde(path), color: Theme.fg2))
        }
        if let patch = ask.patch {
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                let color = text.hasPrefix("+") ? Theme.done : text.hasPrefix("-") ? Theme.err : Theme.fg3
                lines.append(Line(text: text, color: color))
            }
        }
        if let url = ask.url { lines.append(Line(text: url, color: Theme.terminalText)) }
        if lines.isEmpty { lines.append(Line(text: ask.tool, color: Theme.terminalText)) }
        return lines
    }

    /// The agent's reason, and whether you said no to the same request before.
    static func why(_ group: ApprovalGroup) -> String? {
        var parts: [String] = []
        if let why = group.first.why { parts.append("\"\(why)\".") }
        if group.deniedBefore { parts.append("It asked this before and you said no.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func repo(of ask: PermissionAsk, in model: AppModel) -> String? {
        if let helper = ask.helper { return helper.repo }
        return model.sessions.first { $0.id == ask.session }?.repos.first?.name
    }
}
