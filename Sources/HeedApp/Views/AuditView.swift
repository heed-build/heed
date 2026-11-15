import HeedCore
import SwiftUI

/// Insights' Audit (`history.audit`): what heed and the agents did outside this Mac, newest first, with the cause of
/// each; ⇥ switches to the grants heed gave for good. The row under the cursor in full on the right.
struct AuditView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let audit = model.audit
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if let broken = audit.book.broken { ChainWarning(broken: broken) }
                    switch audit.section {
                    case .actions:
                        ListBody(
                            count: audit.rows.count, cursor: audit.cursor, ids: audit.rows.map(\.id),
                            empty: emptyActions, hintView: .audit
                        ) { index in
                            AuditRow(row: audit.rows[index], isCursor: index == audit.cursor)
                        }
                        .shotRegion(.auditList)
                    case .grants:
                        ListBody(
                            count: audit.grantRows.count, cursor: audit.grantCursor, ids: audit.grantRows.map(\.id),
                            empty: emptyGrants, hintView: .audit
                        ) { index in
                            GrantRow(row: audit.grantRows[index], isCursor: index == audit.grantCursor)
                        }
                        .shotRegion(.auditGrants)
                    }
                }
                .frame(width: wide ? 460 : geometry.size.width)
                .frame(height: geometry.size.height, alignment: .top)
                .clipped()
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                if wide {
                    Group {
                        switch audit.section {
                        case .actions:
                            if let row = audit.selected { ActionDetail(row: row) } else { Color.clear }
                        case .grants:
                            if let row = audit.selectedGrant { GrantDetail(row: row) } else { Color.clear }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg2)
                    .shotRegion(.auditDetail)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var emptyActions: String {
        if !model.audit.book.actions.isEmpty { return "Nothing matches." }
        return "Nothing left this Mac yet. A push, a merge, a comment, a review or a release heed or an agent makes "
            + "is listed here with what caused it."
    }

    private var emptyGrants: String {
        if !model.audit.book.grants.isEmpty || !model.audit.before.isEmpty { return "Nothing matches." }
        return "No grants yet. An Always rule, trust in a repo, a trusted reviewer or a kept memory is listed here."
    }

    private var header: some View {
        let audit = model.audit
        return HStack(spacing: 8) {
            SectionToggle(section: audit.section)
            Spacer(minLength: 8)
            FilterPill(view: .audit)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// `ACTIONS 7 · GRANTS 3`, the one shown lit, ⇥ between them.
private struct SectionToggle: View {
    @Environment(AppModel.self) private var model
    let section: AuditBrowser.Section

    var body: some View {
        HStack(spacing: 14) {
            item("Actions", count: model.audit.weekCount(), suffix: "in 7 days", lit: section == .actions)
            item(
                "Grants",
                count: model.audit.book.grantRows(before: model.audit.before).count { $0.revoked == nil },
                suffix: "standing",
                lit: section == .grants
            )
            KeyCap(text: model.keyText(for: "audit.grants", in: "audit"))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.perform(CommandInvocation(name: "audit.grants")) }
    }

    private func item(_ title: String, count: Int, suffix: String, lit: Bool) -> some View {
        HStack(spacing: 6) {
            SectionHeader(title: title, tint: lit ? Theme.fg : Theme.fg3)
            Text("\(count) \(suffix)").font(Theme.mono(11)).foregroundStyle(lit ? Theme.fg2 : Theme.fg3)
        }
    }
}

/// The record's chain does not hold from a row on: said quietly, under the header.
private struct ChainWarning: View {
    let broken: AuditChain.Break

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 10)).foregroundStyle(Theme.block)
            Text("The record's chain breaks at row \(broken.seq): \(broken.reason).")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The class of an action, in its color.
struct AuditTag: View {
    let tag: AuditClass

    var body: some View {
        Text(tag.rawValue)
            .font(Theme.mono(11))
            .foregroundStyle(color)
            .frame(width: 62, height: 19)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch tag {
        case .publish: Theme.block
        case .merge: Theme.done
        case .push: Theme.busy
        case .comment, .review: Theme.ask
        case .write: Theme.fg2
        }
    }
}

/// Who wrote text that reached the prompt, by how far heed trusts them.
struct TrustChip: View {
    let author: ExternalText.Author

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(author.trust.rawValue) \(ExternalText.strip(author.handle))")
                .foregroundStyle(author.trust == .stranger ? Theme.fg : Theme.fg2)
        }
        .font(Theme.mono(10.5))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
        .fixedSize()
    }

    private var color: Color {
        switch author.trust {
        case .stranger: Theme.err
        case .bot: Theme.block
        case .collaborator: Theme.done
        case .owner: Theme.fg3
        }
    }
}

private struct AuditRow: View {
    let row: AuditBook.Row
    let isCursor: Bool

    var body: some View {
        let action = row.action
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(action.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    .frame(width: 44, alignment: .leading)
                Text(action.what)
                    .font(Theme.mono(12.5, weight: .semibold))
                    .foregroundStyle(action.outcome == .done ? Theme.fg : Theme.fg2)
                    .strikethrough(action.outcome == .held, color: Theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if action.outcome != .done {
                    Text(action.outcome.rawValue).font(Theme.mono(11))
                        .foregroundStyle(action.outcome == .failed ? Theme.err : Theme.block)
                }
                AuditTag(tag: action.tag)
            }
            HStack(spacing: 6) {
                Text(cause).font(Theme.mono(11)).foregroundStyle(action.actor == .outside ? Theme.block : Theme.fg3)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // The least trusted first: one is enough to read the row; the detail lists them all.
                ForEach(row.authors.filter { $0.trust != .owner }.prefix(1), id: \.self) { TrustChip(author: $0) }
            }
            .padding(.leading, 52)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    /// `Autopilot · Fix broken anchors · claude`.
    private var cause: String {
        [row.trigger, row.action.sessionTitle, row.action.actor == .agent ? row.action.agent : nil]
            .compactMap(\.self).joined(separator: " · ")
    }
}

private struct ActionDetail: View {
    @Environment(AppModel.self) private var model
    let row: AuditBook.Row

    var body: some View {
        let action = row.action
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    [action.repo, action.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())]
                        .compactMap(\.self).joined(separator: " · ")
                )
                .font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                HStack(spacing: 10) {
                    Text(action.what).font(Theme.ui(18, weight: .semibold))
                    AuditTag(tag: action.tag)
                }
                section("Cause") { CauseChain(row: row) }
                section("Command") { CommandBlock(text: action.command) }
                if let approval = action.approval {
                    section("Allowed by") {
                        Text(approval.text + (action.outcome == .held ? ": it did not run" : ""))
                            .font(Theme.ui(12.5))
                            .foregroundStyle(action.outcome == .held ? Theme.block : Theme.fg)
                    }
                }
                section("Whose text or approval it rests on") {
                    if row.authors.isEmpty {
                        Text(action.actor == .outside ? "None: nothing in heed led to it."
                            : "Only yours and heed's.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                    } else {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(row.authors, id: \.self) { TrustChip(author: $0) }
                        }
                    }
                }
                section("Facts") {
                    VStack(spacing: 7) {
                        fact("By", actor)
                        fact("Outcome", action.outcome.rawValue)
                        if let title = action.sessionTitle { fact("Session", title) }
                        if let url = action
                            .url { fact("On GitHub", url.replacingOccurrences(of: "https://", with: "")) }
                    }
                }
                Theme.line.frame(height: 1).padding(.top, 4)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    if action.url != nil { keyHint("open.browser", "on GitHub") }
                    if action.session != nil { keyHint("audit.session", "its session") }
                    keyHint("audit.grants", "grants")
                    keyHint("audit.export", "export")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actor: String {
        switch row.action.actor {
        case .heed: "heed itself"
        case .agent: "the agent" + (row.action.agent.map { " (\($0))" } ?? "")
        case .outside: "GitHub" + (row.action.agent.map { ", by \($0)" } ?? "") + ": outside heed"
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.fg3)
            Spacer()
            Text(value).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.ui(12.5))
    }

    private func keyHint(_ command: String, _ text: String) -> some View {
        KeyHint(command, scope: "audit", label: text, color: Theme.fg2)
    }
}

/// From the trigger down to the action, one step a line.
private struct CauseChain: View {
    let row: AuditBook.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(index == steps.count - 1 ? Theme.fg : Theme.fg3).frame(width: 7, height: 7)
                        .padding(.top, 5)
                        .frame(width: 8, alignment: .top)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                        Text(step.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, index < steps.count - 1 ? 10 : 0)
                }
                // The thread from this step down to the next, as tall as the step's own text.
                .background(alignment: .topLeading) {
                    if index < steps.count - 1 {
                        Theme.line.frame(width: 1).padding(.top, 14).padding(.leading, 3.5)
                    }
                }
            }
        }
    }

    private var steps: [(label: String, detail: String)] {
        var steps = row.chain.map { cause in
            (label: cause.trigger.label, detail: ExternalText.strip(cause.detail))
        }
        if row.action.actor == .outside { steps = [("GitHub", "no recorded cause in heed explains it")] }
        if steps.isEmpty { steps = [("heed", "no cause was recorded with it")] }
        steps.append((label: row.action.actor == .agent ? "agent" : "action", detail: row.action.what))
        return steps
    }
}

private struct CommandBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.fg)
            .textSelection(.enabled)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

private struct GrantRow: View {
    let row: AuditBook.GrantRow
    let isCursor: Bool

    var body: some View {
        let grant = row.grant
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(grant.subject)
                    .font(Theme.mono(12.5, weight: .semibold))
                    .foregroundStyle(row.revoked == nil ? Theme.fg : Theme.fg3)
                    .strikethrough(row.revoked != nil, color: Theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if row.revoked != nil { Text("revoked").font(Theme.mono(11)).foregroundStyle(Theme.fg3) }
                Text(grant.kind.label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                    .fixedSize()
            }
            Text([grant.scope, when].joined(separator: " · "))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var when: String {
        row.grant.beforeAudit ? "before Audit" : Clock.relative(row.grant.at, named: true)
    }
}

private struct GrantDetail: View {
    @Environment(AppModel.self) private var model
    let row: AuditBook.GrantRow

    var body: some View {
        let grant = row.grant
        ListScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text(grant.kind.label + " · " + (grant.beforeAudit ? "before Audit"
                        : grant.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())))
                    .font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                Text(grant.subject).font(Theme.mono(17, weight: .semibold))
                section("Where") { CommandBlock(text: grant.scope) }
                section("Why") {
                    Text(ExternalText.strip(grant.why)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.chain.isEmpty {
                    section("Cause") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(row.chain, id: \.id) { cause in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(cause.trigger.label).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                                        .frame(width: 70, alignment: .leading)
                                    Text(ExternalText.strip(cause.detail)).font(Theme.ui(12.5))
                                        .foregroundStyle(Theme.fg)
                                }
                            }
                        }
                    }
                }
                if let revoked = row.revoked {
                    section("Revoked") {
                        Text("\(Clock.relative(revoked.at, named: true)): \(revoked.result)")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    }
                }
                Theme.line.frame(height: 1).padding(.top, 4)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    if row.revoked == nil, grant.kind.revocable {
                        KeyHint("audit.revoke", scope: "audit", label: "revoke", color: Theme.fg2)
                    }
                    KeyHint("audit.grants", scope: "audit", label: "actions", color: Theme.fg2)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            content()
        }
    }
}
