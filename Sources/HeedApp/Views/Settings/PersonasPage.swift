import AppKit
import HeedCore
import SwiftUI

/// Settings › Personas: the library, one list for everywhere heed asks someone for a view. Each row: the persona's
/// tile, who it is, the question it asks first, where it came from, where it applies, its last seven verdicts, on or
/// off. The one under the cursor on the right: who they are, why this persona, what it joins, and Try it, Edit, Share.
/// Keys come from the `personas` scope (`PersonaKeys`), read here because the main window never sees Settings' keys.
struct PersonasPage: View {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    var body: some View {
        let ui = model.personaUI
        let rows = model.personaRows
        let selected = model.selectedLibraryEntry
        Group {
            if ui.inSessions {
                // In sessions (s): when personas look at a session's work.
                VStack(alignment: .leading, spacing: 14) {
                    PersonasHeader()
                    PersonasInSessions()
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                library(ui: ui, rows: rows, selected: selected)
            }
        }
        .onAppear(perform: listen)
        .onDisappear(perform: stopListening)
    }

    private func library(
        ui: PersonaLibraryBrowser, rows: [PersonaLibrary.Entry], selected: PersonaLibrary.Entry?
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PersonasHeader()
                PersonaFilters()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(rows) { entry in
                                PersonaRow(
                                    entry: entry, verdicts: model.personaVerdicts[entry.id] ?? [],
                                    cursor: entry.id == selected?.id
                                )
                                .id(entry.id)
                            }
                        }
                    }
                    // The cursor stays in view.
                    .onChange(of: selected?.id, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                PersonasFoot()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Theme.line.frame(width: 1)
            Group {
                if let selected {
                    PersonaDetail(entry: selected, editing: ui.drafting == selected.id ? ui.draft : nil)
                } else {
                    Color.clear
                }
            }
            .frame(width: 360)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.bg2.opacity(0.5))
        }
        .overlay {
            if !ui.defining.isEmpty {
                PersonaSheetBackdrop { DefinePersonaSheet() }
            } else if ui.adding != nil {
                PersonaSheetBackdrop { AddPersonaSheet() }
            }
        }
    }

    /// Keys while the page shows, in the Settings window only: the scope's bindings, or a field's ⎋ and ⌘S.
    private func listen() {
        guard monitor == nil, !ShotMode.active else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
            guard let window = event.window, window.identifier != AppModel.mainWindowID,
                  window.identifier != StartWorkPanelController.identifier, let stroke = KeyStroke(event: event)
            else { return event }
            let typing = window.firstResponder is NSText
            let used = MainActor.assumeIsolated { model.personaSettingsKey(stroke, typing: typing) }
            return used ? nil : event
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A persona's tint: its identity, the same in every row and sheet (the panel's tints for heed's own).
func personaTint(_ id: String) -> Color {
    switch id {
    case "skeptic", "security": return Theme.err
    case "ux", "operator": return Color(hex: 0x4FB8B0)
    case "dx", "performance": return Theme.busy
    case "purist", "accessibility": return Theme.ask
    case "adversary": return Theme.block
    case "newcomer": return Color(hex: 0xC6E07A)
    case "scope-keeper": return Color(hex: 0xE59A6B)
    default:
        let palette = [
            Theme.block, Color(hex: 0x4FB8B0), Color(hex: 0xC6E07A), Color(hex: 0x8FA8F5), Color(hex: 0xF28FB0),
            Theme.ask, Color(hex: 0xE59A6B),
        ]
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// The letter on its tile.
struct PersonaTile: View {
    let name: String
    let id: String
    var size: CGFloat = 40

    var body: some View {
        let tint = personaTint(id)
        Text(String(name.first.map { $0.uppercased() } ?? "?"))
            .font(Theme.ui(size * 0.42, weight: .bold)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.16)))
    }
}

/// The last seven verdicts as bars, the newest right: happy in the persona's tint, a concern dimmed, not in red, none
/// yet as a slot.
struct VerdictBars: View {
    let id: String
    let verdicts: [PanelVerdict.Kind]
    var dim = false

    var body: some View {
        let tint = personaTint(id)
        let slots = Array(repeating: PanelVerdict.Kind?.none, count: max(0, PersonaVerdicts.limit - verdicts.count))
            + verdicts.map(Optional.some)
        HStack(spacing: 2) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, kind in
                let color: Color = switch kind {
                case .happy: tint
                case .concern: tint.opacity(0.45)
                case .not: Theme.err
                case nil: Theme.line
                }
                RoundedRectangle(cornerRadius: 1).fill(dim ? Theme.line : color).frame(width: 6, height: 18)
            }
        }
        .help(verdicts.isEmpty ? "No panel has read a plan with it yet"
            : "Its last \(verdicts.count) verdict\(verdicts.count == 1 ? "" : "s"), newest right: "
            + verdicts.map(\.rawValue).joined(separator: ", "))
    }
}

/// Where a persona came from, as a glyph: ★ built in, a folder from your repos, ⚡ learned, a person yours.
func sourceIcon(_ source: PersonaSource) -> String {
    switch source {
    case .builtIn: "star"
    case .repos: "folder"
    case .learned: "bolt"
    case .yours: "person"
    }
}

private struct PersonasHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Personas").font(Theme.ui(22, weight: .bold))
            Text("the people heed asks for a view: in goal panels, and in sessions when you invite them")
                .font(Theme.ui(13)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            // The library, or when they look at sessions.
            HStack(spacing: 8) {
                Image(systemName: model.personaUI.inSessions ? "person.2" : "rectangle.stack")
                    .font(.system(size: 12, weight: .medium))
                Text(model.personaUI.inSessions ? "Library" : "In sessions").font(Theme.ui(13.5))
                KeyCap(text: model.keyText(for: "personas.sessions", in: "personas"))
            }
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .fixedSize()
            .clickRuns(CommandInvocation(name: "personas.sessions"))
            HStack(spacing: 8) {
                Image(systemName: "star").font(.system(size: 12, weight: .semibold))
                Text("Add a persona").font(Theme.ui(13.5, weight: .semibold))
                KeyCapDark(text: model.keyText(for: "personas.add", in: "personas"))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.inverse))
            .fixedSize()
            .clickRuns(CommandInvocation(name: "personas.add"))
        }
    }
}

/// A key cap on a light button.
struct KeyCapDark: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.mono(10)).foregroundStyle(Theme.inverse)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.ink))
    }
}

private struct PersonaFilters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.personaLibrary
        let sources: [PersonaSource?] = [nil] + PersonaSource.allCases.filter { library.count($0) > 0 }
        HStack(spacing: 8) {
            ForEach(sources, id: \.self) { source in
                let on = model.personaUI.filter == source
                Text("\(source?.label ?? "all") \(library.count(source))")
                    .font(Theme.mono(12))
                    .foregroundStyle(on ? Theme.ink : Theme.fg2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Theme.inverse : Theme.chip))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.personaUI.filter = source
                        model.personaUI.setCursor(0, count: model.personaRows.count)
                    }
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text("last 7 verdicts").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
        }
    }
}

private struct PersonaRow: View {
    @Environment(AppModel.self) private var model
    let entry: PersonaLibrary.Entry
    let verdicts: [PanelVerdict.Kind]
    let cursor: Bool

    var body: some View {
        let persona = entry.persona
        HStack(spacing: 14) {
            PersonaTile(name: persona.name, id: entry.id)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(persona.name).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                    if !persona.who.isEmpty {
                        Text(persona.who).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
                Text(persona.asksFirst.first.map { "“\($0)”" } ?? "asks nothing first yet")
                    .font(Theme.ui(13)).foregroundStyle(persona.asksFirst.isEmpty ? Theme.fg3 : Theme.fg2)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            Label(persona.source.label, systemImage: sourceIcon(persona.source))
                .labelStyle(IconLabel())
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1).fixedSize()
            Label(persona.on ? persona.scope.label : "—", systemImage: "folder")
                .labelStyle(IconLabel())
                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            VerdictBars(id: entry.id, verdicts: verdicts, dim: !persona.on)
            Toggle("", isOn: Binding(get: { persona.on }, set: { _ in
                model.clickLibraryPersona(entry.id)
                model.perform(CommandInvocation(name: "personas.toggle"))
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.done)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .opacity(persona.on ? 1 : 0.45)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cursor ? Theme.paneActive : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { model.clickLibraryPersona(entry.id) }
    }
}

/// An SF Symbol and its words, close together.
struct IconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 10.5))
            configuration.title
        }
    }
}

/// What the keys do here, and heed's last word (the main window's status line is not in this window).
private struct PersonasFoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let flash = model.flash {
                Text(flash).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(hints).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).fixedSize()
        }
    }

    private var hints: String {
        let keys: [(String, String)] = [
            ("personas.add", "add"), ("personas.move 1", "persona"), ("personas.toggle", "on/off"),
            ("personas.try", "try it on a PR"), ("personas.edit", "edit"), ("personas.share", "share"),
        ]
        return keys.map { command, words in
            let key = switch command {
            case "personas.move 1": "j k"
            case "personas.toggle": "space"
            default: model.keyText(for: command, in: "personas")
            }
            return "\(key) \(words)"
        }
        .joined(separator: " · ")
    }
}

private struct PersonaDetail: View {
    @Environment(AppModel.self) private var model
    let entry: PersonaLibrary.Entry
    let editing: String?

    var body: some View {
        let persona = entry.persona
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                PersonaTile(name: persona.name, id: entry.id, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(persona.name).font(Theme.ui(19, weight: .bold)).lineLimit(2)
                    Label(origin(persona), systemImage: sourceIcon(persona.source))
                        .labelStyle(IconLabel())
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)
            if let editing {
                FileEditor(text: editing)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        WhoTheyAre(persona: persona)
                        Evidence(persona: persona, builtIn: entry.isBuiltIn)
                        Joins(persona: persona)
                        if let trial = model.personaUI.trials[entry.id] {
                            TrialCard(id: entry.id, name: persona.name, trial: trial)
                        } else if model.personaUI.trying.contains(entry.id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("reading a merged PR…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                SheetButton(
                    label: "Try it on a PR",
                    icon: "arrow.left.arrow.right",
                    command: "personas.try",
                    scope: "personas"
                )
                SheetButton(label: editing == nil ? "Edit" : "Save", command: "personas.edit", scope: "personas")
                SheetButton(label: "Share", command: "personas.share", scope: "personas")
            }
        }
        .padding(22)
    }

    private func origin(_ persona: Persona) -> String {
        let source = switch persona.source {
        case .builtIn: "built into heed"
        case .repos: "from \(persona.scope.label)"
        case .learned: "learned"
        case .yours: "yours"
        }
        guard let added = persona.added else { return source }
        let days = Int(Clock.now.timeIntervalSince(added) / 86400)
        let when = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return "\(source) · added \(when)"
    }
}

/// The file in place: e again, ⎋ or ⌘S saves.
private struct FileEditor: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { text }, set: { model.personaUI.draft = $0 }))
                .font(Theme.mono(12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.keyCapBorder))
            Text("e, ⎋ or ⌘S saves it").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
        }
    }
}

/// A detail section's header: an SF Symbol and small caps.
struct DetailHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.fg3).frame(width: 16)
            SectionHeader(title: title)
        }
    }
}

/// A line with its glyph: `?` asks first, ⇄ skeptical about, a shield for may / may not.
struct GlyphLine<Content: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            content.font(Theme.ui(13.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WhoTheyAre: View {
    let persona: Persona

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(icon: "eye", title: "Who they are")
            Text(about).font(Theme.ui(13.5)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
            if let asks = persona.asksFirst.first {
                GlyphLine(icon: "questionmark", tint: Theme.block) {
                    Text("asks first: ").foregroundStyle(Theme.fg2) + Text(asks).bold()
                }
            }
            if !persona.skepticalAbout.isEmpty {
                GlyphLine(icon: "arrow.left.arrow.right", tint: Theme.err) {
                    Text("skeptical about: " + persona.skepticalAbout.joined(separator: ", "))
                        .foregroundStyle(Theme.fg2)
                }
            }
            GlyphLine(icon: "checkmark.shield", tint: Theme.fg3) {
                Text(permissions).foregroundStyle(Theme.fg2)
            }
        }
    }

    private var about: String {
        if !persona.about.isEmpty { return persona.about }
        let who = persona.who.isEmpty ? persona.name : persona.who.prefix(1).uppercased() + persona.who.dropFirst()
        return persona.knows.isEmpty ? "\(who)." : "\(who). Knows \(persona.knows.joined(separator: ", "))."
    }

    private var permissions: String {
        var parts: [String] = []
        if !persona.may.isEmpty { parts.append("may: " + persona.may.joined(separator: ", ")) }
        if !persona.mayNot.isEmpty { parts.append("may not: " + persona.mayNot.joined(separator: ", ")) }
        return parts.isEmpty ? "may and may not: not said" : parts.joined(separator: " · ")
    }
}

/// An evidence line's glyph, from what it is about.
func evidenceIcon(_ text: String) -> String {
    let lower = text.lowercased()
    if lower.contains("codeowners") || lower.contains("owns") { return "arrow.triangle.branch" }
    if lower.contains("comment") || lower.contains("issue") || lower.contains("review") { return "questionmark" }
    if lower.contains("ci") || lower.contains("check") || lower.contains("workflow") { return "checkmark" }
    if lower.contains("people") || lower.contains("merge") || lower.contains("contributor") { return "person.2" }
    return "doc.text"
}

private struct Evidence: View {
    let persona: Persona
    let builtIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DetailHeader(icon: "folder", title: "Evidence · why this persona")
            if persona.evidence.isEmpty {
                Text(builtIn ? "One of heed's own: it sits on goal panels by what the plan touches."
                    : "None written down.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            }
            ForEach(persona.evidence, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: evidenceIcon(line)).font(.system(size: 10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 16)
                    Text(line).font(Theme.ui(13)).foregroundStyle(Theme.fg2).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
        }
    }
}

private struct Joins: View {
    @Environment(AppModel.self) private var model
    let persona: Persona

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(icon: "person.2", title: "Joins")
            ForEach(PersonaJoin.allCases, id: \.self) { join in
                HStack(spacing: 12) {
                    Image(systemName: icon(join)).font(.system(size: 11)).foregroundStyle(Theme.fg2).frame(width: 18)
                    Text(join.label(persona.scope)).font(Theme.ui(13.5)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Toggle("", isOn: Binding(get: { persona.joins.contains(join) }, set: { _ in
                        model.perform(CommandInvocation(name: "personas.join", arguments: [word(join)]))
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.done)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
                .help(join == .goalPanels ? "Sits on the panel of goals whose repos are in its scope"
                    : "Stored now; sessions ask it once inviting personas into sessions is built")
            }
        }
    }

    private func icon(_ join: PersonaJoin) -> String {
        switch join {
        case .goalPanels: "square.3.layers.3d"
        case .beforePR: "play"
        case .everyPlan: "eye"
        }
    }

    private func word(_ join: PersonaJoin) -> String {
        switch join {
        case .goalPanels: "panels"
        case .beforePR: "pr"
        case .everyPlan: "plans"
        }
    }
}

/// A trial's result: what the persona would have said on a real PR, the lines it points at, and how that compares
/// with what review said.
struct TrialCard: View {
    let id: String
    let name: String
    let trial: PersonaTrial

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(icon: "arrow.left.arrow.right", title: "Try it · on PR #\(trial.number)")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    PersonaTile(name: name, id: id, size: 28)
                    Text("“\(trial.quote)”").font(Theme.ui(13.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    VerdictMark(kind: trial.verdict)
                }
                if !trial.lines.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(trial.lines, id: \.self) { line in
                            Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.block)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.block.opacity(0.12)))
                        }
                    }
                    .padding(.leading, 40)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        let when = trial.mergedAt.map { date in
            let days = Int(Clock.now.timeIntervalSince(date) / 86400)
            return days < 8 ? "from last week" : "merged \(days) days ago"
        } ?? "merged"
        switch trial.agrees {
        case true?:
            Label("a real PR \(when) · it pointed where review did", systemImage: "checkmark")
                .labelStyle(IconLabel()).font(Theme.mono(11)).foregroundStyle(Theme.done.opacity(0.9))
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("a real PR \(when) in \(trial.repo)", systemImage: "arrow.triangle.pull")
                    .labelStyle(IconLabel()).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                if let said = trial.reviewSaid {
                    Text("what review actually said: “\(said)”").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        .lineLimit(3)
                }
            }
        }
    }
}

/// happy ✓, concern ?, not ⇄.
struct VerdictMark: View {
    let kind: PanelVerdict.Kind

    var body: some View {
        let (icon, color): (String, Color) = switch kind {
        case .happy: ("checkmark", Theme.done)
        case .concern: ("questionmark", Theme.block)
        case .not: ("arrow.left.arrow.right", Theme.err)
        }
        Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(color.opacity(0.16)))
            .help(kind.rawValue)
    }
}

/// A sheet's or the detail's button: its words, its key, a click runs the command.
struct SheetButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    var icon: String?
    let command: String
    var arguments: [String] = []
    let scope: String
    var primary = false

    var body: some View {
        let invocation = CommandInvocation(name: command, arguments: arguments)
        let key = model.keyText(
            for: arguments.isEmpty ? command : "\(command) \(arguments.joined(separator: " "))",
            in: scope
        )
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 11)) }
            Text(label).font(Theme.ui(13.5, weight: primary ? .semibold : .regular)).lineLimit(1)
            if primary { KeyCapDark(text: key) } else { KeyCap(text: key) }
        }
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(primary ? Theme.inverse : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(primary ? .clear : Theme.keyCapBorder))
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { model.perform(invocation) }
        .pointerStyle(.link)
        .help(Clicks.help(invocation))
    }
}

/// The dimmed window behind a sheet; nothing behind it takes a click.
struct PersonaSheetBackdrop<Sheet: View>: View {
    @ViewBuilder let sheet: Sheet

    var body: some View {
        ZStack {
            Theme.bg.opacity(0.82).contentShape(Rectangle()).onTapGesture {}
            sheet.padding(28)
        }
    }
}
