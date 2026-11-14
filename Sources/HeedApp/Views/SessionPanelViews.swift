import HeedCore
import SwiftUI

// Personas in sessions (designs ps1–ps3, p5): the faint stack on a session's row, the panel's line at its foot (an
// offer, the look under way, the verdict, a held PR), and the popover over it (gL).

/// The personas who may look, as overlapping tiles: faint on a sidebar row, plain on the line.
struct PersonaStack: View {
    let personas: [(id: String, name: String)]
    var size: CGFloat = 16
    var faint = false

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(personas.enumerated()), id: \.offset) { index, persona in
                let tint = personaTint(persona.id)
                Text(String(persona.name.first.map { $0.uppercased() } ?? "?"))
                    .font(Theme.ui(size * 0.52, weight: .bold)).foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg2))
                    .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.bg, lineWidth: 1))
                    .zIndex(Double(personas.count - index))
            }
        }
        .opacity(faint ? 0.55 : 1)
        .fixedSize()
        .help(personas.map(\.name).joined(separator: ", "))
    }
}

extension PersonaStack {
    init(personas: [Persona], size: CGFloat = 16, faint: Bool = false) {
        self.init(personas: personas.map { ($0.id, $0.name) }, size: size, faint: faint)
    }

    init(seats: [PanelSeat], size: CGFloat = 16, faint: Bool = false) {
        self.init(personas: seats.map { ($0.id, $0.name) }, size: size, faint: faint)
    }
}

/// happy ✓, concern ?, not ⇄ (it argues the other way): the goal panel's glyphs.
struct PanelVerdictGlyph: View {
    let kind: PanelVerdict.Kind?
    var size: CGFloat = 22

    var body: some View {
        let (icon, color) = Self.style(kind)
        Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.16)))
    }

    static func style(_ kind: PanelVerdict.Kind?) -> (String, Color) {
        switch kind {
        case .happy: ("checkmark", Theme.done)
        case .concern: ("questionmark", Theme.block)
        case .not: ("arrow.left.arrow.right", Theme.err)
        case nil: ("ellipsis", Theme.fg3)
        }
    }
}

/// ✓2 ?1 ⇄0, the zeros left out.
private struct VerdictCounts: View {
    let look: SessionLook

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PanelVerdict.Kind.allCases, id: \.self) { kind in
                let count = look.count(kind)
                if count > 0 {
                    let (icon, color) = PanelVerdictGlyph.style(kind)
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                        Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// A button on the line or in the popover: its label and key; the first one filled.
private struct PanelButton: View {
    let label: String
    let key: String
    var primary = false
    var symbol: String?
    let command: CommandInvocation

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(label).fontWeight(primary ? .semibold : .regular).lineLimit(1)
            if !key.isEmpty {
                if primary { KeyCapDark(text: key) } else { KeyCap(text: key) }
            }
        }
        .font(Theme.ui(12.5))
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 11)
        .frame(height: 27)
        .background(RoundedRectangle(cornerRadius: 5).fill(primary ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(primary ? .clear : Theme.line))
        .fixedSize()
        .clickRuns(command)
    }
}

/// The panel's line at the foot of the session's panes: quiet unless a milestone happened.
struct SessionPanelLineView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let line: SessionPanelLine

    var body: some View {
        let amber = line.urgency == .needsYou
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 5).fill(amber ? Theme.block.opacity(0.07) : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(amber ? Theme.block.opacity(0.55) : Theme.line))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .shotRegion(.panelLine)
    }

    @ViewBuilder private var content: some View {
        switch line {
        case let .offer(milestone):
            let personas = model.panelAvatars(for: session)
            PersonaStack(personas: personas, size: 22)
            lead(milestone.kind.title, details: milestone.details.joined(separator: " · "))
            Spacer(minLength: 8)
            Text("Ask \(personas.count) persona\(personas.count == 1 ? "" : "s") for a look?")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1).fixedSize()
            PanelButton(
                label: "Yes", key: model.keyText(for: "panel.ask"), primary: true,
                command: CommandInvocation(name: "panel.ask")
            )
            PanelButton(
                label: "Not now", key: model.keyText(for: "panel.notnow", in: "sessionsoffer"),
                command: CommandInvocation(name: "panel.notnow")
            )
            PanelButton(
                label: "Never here", key: "", symbol: "eye.slash", command: CommandInvocation(name: "panel.never")
            )
            .help("No more offers in this session; \(model.keyText(for: "panel.ask")) still asks")
        case let .looking(milestone):
            PersonaStack(personas: model.panelAvatars(for: session), size: 22)
            lead("The panel is reading", details: milestone.kind == .asked ? "" : milestone.kind.title.lowercased())
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Spacer(minLength: 8)
        case let .verdict(look):
            PersonaStack(seats: look.seats, size: 22)
            Text("Panel").font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            VerdictCounts(look: look)
            if let top = look.topLine {
                Text("· " + top).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
            } else {
                Text("· everyone is happy").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            if look.sent {
                Text("sent").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).fixedSize()
            }
            Spacer(minLength: 8)
            PanelButton(
                label: "Open",
                key: model.keyText(for: "panel.ask"),
                command: CommandInvocation(name: "panel.ask")
            )
        case let .holding(hold):
            Image(systemName: "person.2").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.block)
            Text("Panel before the PR").font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if let look = hold.look {
                VerdictCounts(look: look)
            } else {
                Text("reading…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).fixedSize()
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer(minLength: 8)
            // Redrawn every second: how long the PR is held.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = hold.remaining(ShotMode.active ? hold.since.addingTimeInterval(28) : Date())
                Text("held \(left / 60):\(String(format: "%02d", left % 60))")
                    .font(Theme.mono(11)).foregroundStyle(Theme.block).fixedSize()
            }
            if hold.look != nil {
                PanelButton(
                    label: "Open",
                    key: model.keyText(for: "panel.ask"),
                    command: CommandInvocation(name: "panel.ask")
                )
            }
        }
    }

    private func lead(_ title: String, details: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if !details.isEmpty {
                Text("· " + details).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// The verdict's popover over the line (gL): each persona's line, Send to the agent, Talk to one, Dismiss; on a held
/// PR, Let it open, Send the concern first, Hold the PR.
struct SessionPanelPopover: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let look: SessionLook
    let held: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(look.verdicts.enumerated()), id: \.offset) { index, verdict in
                    row(verdict, index: index)
                }
            }
            if let chat = model.sessionPanel.chat {
                PanelChat(chat: chat)
            }
            buttons.padding(.top, 2)
            if held {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 10.5))
                    Text(
                        "heed holds the agent's gh pr create through its permission hook for up to "
                            + "\(holdText); then it goes on as it would have."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 18)
        .shotRegion(.panelPopover)
    }

    private var holdText: String {
        let seconds = model.config.personas.holdSeconds
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.2").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.block)
            Text(title).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
            Spacer(minLength: 8)
            Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).fixedSize()
        }
    }

    private var title: String {
        switch look.milestone.kind {
        case .beforePR: look.worried ? "Before this PR opens: the panel has a concern" : "Before this PR opens"
        case .built: "The panel on what's built"
        case .saysDone: "The panel on what's done"
        case .asked: "The panel's look"
        case .secondRepo: "The panel on a second repo"
        case .long: "The panel, after a long stretch"
        }
    }

    private var meta: String {
        if held, let diff = look.diff { return "diff +\(diff.added) −\(diff.removed) · \(diff.files) files" }
        var parts = [look.model ?? "model"]
        if look.seconds > 0 { parts.append("\(Int(look.seconds.rounded())) s") }
        if let dollars = look.dollars { parts.append(String(format: "$%.3f", dollars)) }
        return parts.joined(separator: " · ")
    }

    private func row(_ verdict: PanelVerdict, index: Int) -> some View {
        let seat = look.seat(verdict.seat)
        let name = seat?.name ?? verdict.seat
        let cursor = model.sessionPanel.row == index
        return HStack(alignment: .top, spacing: 10) {
            PersonaTile(name: name, id: verdict.seat, size: 26)
            (Text(name + " ").fontWeight(.semibold).foregroundColor(Theme.fg)
                + Text(verdict.quote).foregroundColor(Theme.fg)
                + Text(verdict.fix.map { "  \($0)" } ?? "").foregroundColor(Theme.fg3))
                .font(Theme.ui(12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PanelVerdictGlyph(kind: verdict.kind)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(cursor ? Theme.selected.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.sessionPanel.row = index }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if held {
                PanelButton(
                    label: "Let it open", key: model.keyText(for: "panel.pr open", in: "sessionspanelpr"),
                    primary: true, command: CommandInvocation(name: "panel.pr", arguments: ["open"])
                )
                PanelButton(
                    label: "Send the concern first", key: model.keyText(for: "panel.pr concern", in: "sessionspanelpr"),
                    command: CommandInvocation(name: "panel.pr", arguments: ["concern"])
                )
                PanelButton(
                    label: "Hold the PR", key: model.keyText(for: "panel.pr hold", in: "sessionspanelpr"),
                    command: CommandInvocation(name: "panel.pr", arguments: ["hold"])
                )
            } else {
                PanelButton(
                    label: "Send to \(session.agent)", key: model.keyText(for: "panel.send", in: "sessionspanel"),
                    primary: look.worried, command: CommandInvocation(name: "panel.send")
                )
                PanelButton(
                    label: "Talk to one", key: model.keyText(for: "panel.talk", in: "sessionspanel"),
                    command: CommandInvocation(name: "panel.talk")
                )
                PanelButton(
                    label: "Dismiss", key: model.keyText(for: "panel.dismiss", in: "sessionspanel"),
                    command: CommandInvocation(name: "panel.dismiss")
                )
            }
        }
    }
}

/// Talking to one persona, under its line in the popover: what was said, and a field.
private struct PanelChat: View {
    @Environment(AppModel.self) private var model
    let chat: PersonaChat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10.5))
                Text("Talking to \(chat.seat.name)").font(Theme.ui(11.5, weight: .semibold))
                Spacer()
                KeyHint(keys: "<Esc>", label: "close")
            }
            .foregroundStyle(Theme.fg3)
            ForEach(Array(chat.lines.enumerated()), id: \.offset) { _, line in
                HStack {
                    if line.fromYou { Spacer(minLength: 60) }
                    Text(line.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(line.fromYou ? Theme.bg3 : personaTint(chat.seat.id).opacity(0.1)))
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.fromYou { Spacer(minLength: 60) }
                }
            }
            if model.sessionPanel.replying {
                Text("\(chat.seat.name) is answering…").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
            field
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }

    @ViewBuilder private var field: some View {
        let typing = model.sessionPanel.typing
        HStack(spacing: 8) {
            if typing != nil, !ShotMode.active {
                TextField("Ask \(chat.seat.name)…", text: Binding(
                    get: { model.sessionPanel.typing ?? "" }, set: { model.sessionPanel.typing = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.submitPanelTyping() }
                .onAppear { focused = true }
            } else {
                Text(typing?.isEmpty == false ? typing ?? "" : "Ask \(chat.seat.name)…")
                    .foregroundStyle(typing?.isEmpty == false ? Theme.fg : Theme.fg3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            KeyCap(text: typing == nil ? model.keyText(for: "panel.say", in: "sessionspanelchat") : "↩")
        }
        .font(Theme.ui(12.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(typing == nil ? Theme.line : Theme.paneActive))
        .contentShape(Rectangle())
        .onTapGesture { if typing == nil { model.perform(CommandInvocation(name: "panel.say")) } }
    }
}

/// Settings › Personas › In sessions (design ps4): the milestones with their thresholds and switches, who looks, and
/// when it offers.
struct PersonasInSessions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.config.personas
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Personas in sessions").font(Theme.ui(20, weight: .semibold)).foregroundStyle(Theme.fg)
                Text("quiet by default: heed only offers a look when one of these happens")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            VStack(spacing: 6) {
                ForEach(Array(SessionMilestone.Kind.signals.enumerated()), id: \.element) { index, kind in
                    signal(kind, index: index, settings: settings)
                }
            }
            section("WHO LOOKS", symbol: "person.2")
            HStack(spacing: 10) {
                PersonaStack(personas: whoLooks, size: 24)
                Text(
                    "the personas whose scope covers the session's repo and that join sessions (the library's "
                        + "\"before a PR\" or \"every session's plan\"), at most 3, most relevant first"
                )
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
            section("WHEN IT OFFERS", symbol: "eye")
            HStack(spacing: 2) {
                ForEach(SessionPanelSettings.Offers.allCases, id: \.self) { offers in
                    let on = settings.offers == offers
                    Text(offers.label)
                        .font(Theme.ui(12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.fg2)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.inverse : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.setConfig(["personas", "offers"], .string(offers.rawValue)) }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.shield").font(.system(size: 10.5))
                Text(
                    "They read the agent's last turn and the diff; they never type into your session. \"Not now\" "
                        + "waits for the next milestone; \"Never here\" is per session. "
                        + "\(model.keyText(for: "panel.ask")) on a session asks them any time."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            Spacer(minLength: 0)
        }
    }

    /// Who would look at the session under the cursor in the main window, else at any acme-like scope: the library's
    /// relevant ones for every repo heed knows.
    private var whoLooks: [Persona] {
        if let session = model.currentSession, !session.isChat {
            let relevant = model.panelAvatars(for: session)
            if !relevant.isEmpty { return relevant }
        }
        return Array(model.personaLibrary.personas.filter { $0.on && SessionPanelInvites.joinsSessions($0) }.prefix(3))
    }

    private func section(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(title).font(Theme.ui(11.5, weight: .semibold)).tracking(0.8)
        }
        .foregroundStyle(Theme.fg3)
        .padding(.top, 4)
    }

    private func signal(_ kind: SessionMilestone.Kind, index: Int, settings: SessionPanelSettings) -> some View {
        let cursor = model.personaUI.signal == index
        let (symbol, detail, threshold): (String, String, String?) = switch kind {
        case .built: (
                "square.stack.3d.up", "files or lines changed since the last look",
                "\(settings.builtFiles) files · \(settings.builtLines) lines"
            )
        case .saysDone: ("checkmark", "\"done\", \"ready for review\" in its turn's end", nil)
        case .beforePR: (
                "arrow.triangle.pull", "holds gh pr create for up to \(settings.holdSeconds / 60) min",
                "asks first"
            )
        case .secondRepo: ("folder", "the session starts changing another repo", nil)
        case .long: ("clock", "hours of work since the panel last looked", "\(settings.longHours) h")
        case .asked: ("", "", nil)
        }
        return HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.fg2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let threshold {
                Text(threshold).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).fixedSize()
            }
            if let key = kind.configKey {
                ConfigSwitch(path: ["personas", key], isOn: settings.isOn(kind))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cursor ? Theme.paneActive : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.personaUI.signal = index }
    }
}
