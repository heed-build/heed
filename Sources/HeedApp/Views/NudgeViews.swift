import HeedCore
import SwiftUI

// heed's own nudges (AppModel+Nudges): "New in heed X" after an update, the settings worth a look, and the title bar
// pill between them. The settings in them are Settings' own rows (drawn as search draws its matches), so a change
// there is the same change, with the same marks and ↺.

extension EnvironmentValues {
    /// Settings rows drawn outside the Settings window: a breadcrumb opens Settings on its page.
    @Entry var settingsOutside = false
}

/// The nudge up, over the window.
struct NudgeView: View {
    @Environment(AppModel.self) private var model
    let nudge: NudgeDialog

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).onTapGesture { model.closeNudge(seen: false) }
                // The list scrolls only past what the window has room for.
                NudgeCard(nudge: nudge, cap: max(geometry.size.height - 320, 240))
                    .frame(width: min(640, max(geometry.size.width - 48, 360)))
                    .frame(maxHeight: max(geometry.size.height - 120, 240))
                    .fixedSize(horizontal: false, vertical: true)
                    .shotRegion(.dialog)
            }
        }
    }
}

/// The dialog itself, without the dimmed window around it.
struct NudgeCard: View {
    let nudge: NudgeDialog
    /// The most its list is before it scrolls.
    var cap: CGFloat = 520

    var body: some View {
        switch nudge {
        case let .whatsNew(content): WhatsNewDialog(content: content, cap: cap)
        case let .gaps(gaps): GapNudgeDialog(gaps: gaps, cap: cap)
        }
    }
}

/// "New in heed 0.37": each feature with Show me, the new settings with their rows, then the settings worth a look.
private struct WhatsNewDialog: View {
    @Environment(AppModel.self) private var model
    let content: WhatsNewContent
    let cap: CGFloat

    var body: some View {
        let inline = content.settings.filter { $0.scope == .global && $0.level == .basic }
        let elsewhere = content.settings.count - inline.count
        NudgeFrame(
            title: "New in heed \(content.version.short)",
            subtitle: content.since.map { "Since \($0.short), the version you last opened." }
                ?? "What this version brought."
        ) {
            CappedScroll(cap: cap) {
                VStack(alignment: .leading, spacing: 16) {
                    if !content.features.isEmpty { features }
                    if !inline.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "New settings").padding(.leading, 2)
                            NudgeRows(entries: inline)
                        }
                    }
                    if elsewhere > 0 {
                        Text("And \(elsewhere) more new setting\(elsewhere == 1 ? "" : "s") (advanced, or per agent, "
                            + "org or repo) on their pages in Settings.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                }
            }
            NudgeGapsLink().padding(.top, 14)
        } footer: {
            Toggle("Don't show what's new", isOn: Binding(get: { false }, set: { if $0 { model.turnOffWhatsNew() } }))
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.done)
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                .fixedSize()
                .help("[nudges] whats_new = false; :whatsnew.show still opens it")
            Spacer(minLength: 12)
            NudgeButton(title: "Not now", key: "⎋", help: "Close; it shows again at the next launch") {
                model.closeNudge(seen: false)
            }
            NudgeButton(title: "Done", key: "↩", primary: true, help: "Seen") { model.closeNudge(seen: true) }
        }
    }

    private var features: some View {
        VStack(spacing: 0) {
            ForEach(Array(content.features.enumerated()), id: \.offset) { index, feature in
                if index > 0 { Theme.line.frame(height: 1) }
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(feature.title).font(Theme.ui(13, weight: .medium))
                            if content.since != nil, feature.version != content.version {
                                Text(feature.version.short).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3)
                            }
                        }
                        Text(feature.line).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let target = feature.showMe {
                        Button("Show me") { model.showMe(target) }
                            .buttonStyle(.link)
                            .font(Theme.ui(12.5))
                            .help(Self.help(target))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .background(Theme.bg3.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private static func help(_ target: WhatsNewTarget) -> String {
        switch target {
        case let .command(line): ":\(line)"
        case let .setting(id):
            SettingsCatalog.entry(id).map { "Settings › \($0.page.title) › \($0.section)" } ?? id
        }
    }
}

/// The settings that add the most and are still at their default: their rows, and for the two that need something
/// done first (zmx installed, model calls set up) what to do, as Configure… has it.
private struct GapNudgeDialog: View {
    @Environment(AppModel.self) private var model
    let gaps: [SettingsGap]
    let cap: CGFloat

    var body: some View {
        let actions = gaps.filter { $0.action != nil }
        let rows = gaps.filter { $0.action == nil }.map(\.entry)
        NudgeFrame(
            title: "\(gaps.count) setting\(gaps.count == 1 ? "" : "s") worth a look",
            subtitle: "Still at heed's defaults, and each adds a lot. Change one here, or go through them all."
        ) {
            CappedScroll(cap: cap) {
                VStack(alignment: .leading, spacing: 12) {
                    if !actions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Needs doing").padding(.leading, 2)
                            VStack(spacing: 0) {
                                ForEach(actions) { gap in
                                    if gap.id != actions.first?.id { Theme.line.frame(height: 1) }
                                    GapActionRow(gap: gap)
                                }
                            }
                            .background(Theme.bg2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                        }
                    }
                    if !rows.isEmpty { NudgeRows(entries: rows) }
                }
            }
        } footer: {
            Button("Configure…") { model.configureFromNudge() }
                .buttonStyle(.link)
                .help("Go through every setting worth a look (:settings.configure)")
            Spacer(minLength: 12)
            Button("Don't remind me") { model.turnOffGapNudge() }
                .buttonStyle(.link)
                .foregroundStyle(Theme.fg3)
                .help("[nudges] gaps = \"off\"")
            NudgeButton(title: "Not now", key: "⎋", primary: true, help: "Close") { model.closeNudge(seen: false) }
        }
        .font(Theme.ui(12.5))
    }
}

/// A gap that needs something done before it is a choice: what, and the button that does it.
private struct GapActionRow: View {
    @Environment(AppModel.self) private var model
    let gap: SettingsGap

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(gap.action == .setUpModelCalls ? "Model calls" : gap.entry.label).font(Theme.ui(13))
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch gap.action {
            case .installZmx:
                Button("Check again") { model.checkZmxAgain() }
                    .buttonStyle(DialogButtonStyle())
                    .help("Look for zmx and check it, as Settings › Tools does")
            case .setUpModelCalls:
                Button("Set up & test") { model.setUpModelCallsFromNudge() }
                    .buttonStyle(DialogButtonStyle())
                    .disabled(model.inferenceSetup.suggestedAgent == nil)
                    .help("Writes [llm] agent and [decisions] decider from what is logged in, then tests both")
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String {
        switch gap.action {
        case let .installZmx(commands):
            let health = model.zmxHealth
            if let problem = health?.problem, health?.path != nil {
                return "Agents keep running when heed quits or updates. zmx does not work: \(problem)."
            }
            return "Agents keep running when heed quits or updates. zmx is not installed: "
                + commands.joined(separator: "; ") + ", then Check again."
        case .setUpModelCalls:
            let agent = model.inferenceSetup.suggestedAgent.map { "\($0) is logged in" } ?? "No agent is logged in yet"
            return "Summaries, goal matching and decisions, through your agent's cheap model. \(agent)."
        case nil:
            return gap.entry.detail
        }
    }
}

/// Settings' own rows for these entries, page by page in the order given.
private struct NudgeRows: View {
    let entries: [SettingsEntry]

    var body: some View {
        let pages = entries.map(\.page).reduce(into: [SettingsPage]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(pages) { page in
                VStack(alignment: .leading, spacing: 12) {
                    SettingsPageBody(page: page)
                }
                .environment(\.settingsPage, page)
                .environment(\.settingsCrumbs, [page.title])
            }
        }
        .environment(\.settingsSearch, SettingsSearch.only(entries))
        .environment(\.settingsOutside, true)
    }
}

/// "Also N settings worth a look · Configure…", while there are any.
private struct NudgeGapsLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.highImpactGaps.count
        if count > 0, model.config.nudges.gaps != .off {
            HStack(spacing: 4) {
                Text("Also \(count) setting\(count == 1 ? "" : "s") worth a look ·").foregroundStyle(Theme.fg3)
                Button("Configure…") { model.configureFromNudge() }
                    .buttonStyle(.link)
                    .help(":settings.configure")
            }
            .font(Theme.ui(12.5))
            .fixedSize()
        }
    }
}

/// A nudge's frame: title and line, the body, then the footer's buttons.
private struct NudgeFrame<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(17, weight: .semibold))
                Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)
            content
            HStack(spacing: 10) { footer }
                .padding(.top, 16)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }
}

/// A dialog button: outlined, or filled for the main one, with its key.
private struct NudgeButton: View {
    let title: String
    var key: String?
    var primary = false
    let help: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(primary ? .medium : .regular)
            if let key { KeyCap(text: key) }
        }
        .font(Theme.ui(12.5))
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .pointerStyle(.link)
        .help(help)
        .fixedSize()
    }
}

/// The title bar's pill while high-impact settings are at their default: click for Configure…, × hides it until the
/// next launch; right-click for good.
struct NudgePillView: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let compact: Bool

    var body: some View {
        let tint = Theme.block
        HStack(spacing: 6) {
            Button { model.configureFromNudge() } label: {
                Text(compact ? "\(count) to look at" : "\(count) setting\(count == 1 ? "" : "s") worth a look")
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Go through them (:settings.configure)")
            Button { model.hideNudgePill(always: false) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Hide until the next launch (:nudges.hide; :nudges.hide always for good)")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .contextMenu {
            Button("Configure…") { model.configureFromNudge() }
            Button("Hide until the next launch") { model.hideNudgePill(always: false) }
            Button("Don't remind me") { model.hideNudgePill(always: true) }
        }
        .shotRegion(.nudgePill)
    }
}
