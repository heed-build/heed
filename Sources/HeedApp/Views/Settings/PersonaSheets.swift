import HeedCore
import SwiftUI

/// Add a persona: the repos to look at and what heed reads in them on the left (with a field to describe one
/// yourself), the people they serve on the right, strongest first, each with its evidence and strength; an overlap
/// with one you have asks sharpen or keep both. ⌘↩ defines the picked with an agent, ⌥↩ adds them as drafted.
struct AddPersonaSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let adding = model.personaUI.adding {
            HStack(spacing: 0) {
                AddLeft(adding: adding).frame(width: 330)
                Theme.line.frame(width: 1)
                AddRight(adding: adding)
            }
            .frame(maxWidth: 1180, maxHeight: 820)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shotRegion(.settingsSection, item: "add")
        }
    }
}

private struct AddLeft: View {
    @Environment(AppModel.self) private var model
    let adding: PersonaLibraryBrowser.Adding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Add a persona").padding(.bottom, 12)
            Text("Who should heed ask?").font(Theme.ui(20, weight: .bold)).padding(.bottom, 10)
            Text("heed reads your repos and proposes the people they serve. Pick some, or describe one yourself.")
                .font(Theme.ui(13.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
            DetailHeader(icon: "folder", title: "Look at").padding(.bottom, 10)
            FlowLayout(spacing: 6) {
                ForEach(adding.repos, id: \.self) { repo in
                    let on = adding.looking.contains(repo)
                    HStack(spacing: 5) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        Text(repo).font(Theme.mono(12))
                    }
                    .foregroundStyle(on ? Theme.fg : Theme.fg3)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Theme.selected : Theme.chip))
                    .contentShape(Rectangle())
                    .tap { model.perform(CommandInvocation(name: "personas.repo", arguments: [repo])) }
                    .help(on ? "heed reads it; click to leave it out" : "Read it too (the same org only)")
                }
            }
            .padding(.bottom, 22)
            DetailHeader(icon: "eye", title: "Read").padding(.bottom, 8)
            ForEach(PersonaDigest.Step.allCases, id: \.self) { step in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: step.icon).font(.system(size: 11)).foregroundStyle(Theme.fg3).frame(width: 18)
                    Text(step.title).font(Theme.ui(13.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if adding.done.contains(step), let digest = adding.digest {
                        Text(digest.count(step, now: Clock.now)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                            .fixedSize()
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.done)
                    } else if adding.reading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 16)
            DescribeField(describing: adding.describing)
            if let cost = adding.cost {
                Label(costText(cost), systemImage: "cylinder")
                    .labelStyle(IconLabel()).font(Theme.mono(11)).foregroundStyle(Theme.fg3).padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func costText(_ cost: PersonaCalls.Cost) -> String {
        [cost.model, "\(Int(cost.seconds.rounded())) s", cost.dollars.map(AgentUsage.dollars)].compactMap(\.self)
            .joined(separator: " · ")
    }
}

/// "Or describe one": a quiet line until `i`, then a field; ↩ drafts it.
private struct DescribeField: View {
    @Environment(AppModel.self) private var model
    let describing: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(Theme.fg3)
            if describing != nil {
                TextField("an on-call SRE who hates noisy alerts", text: $text)
                    .textFieldStyle(.plain).font(Theme.ui(13.5)).focused($focused)
                    .onSubmit {
                        model.describePersona(text)
                        text = ""
                    }
            } else {
                Text("Or describe one: “an on-call SRE who hates noisy alerts”…")
                    .font(Theme.ui(13.5)).foregroundStyle(Theme.fg3).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                KeyCap(text: model.keyText(for: "personas.describe", in: "personaadd"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Theme.paneActive : Theme.keyCapBorder))
        .contentShape(Rectangle())
        .onTapGesture { if describing == nil { model.perform(CommandInvocation(name: "personas.describe")) } }
        .onChange(of: describing != nil, initial: true) { _, on in focused = on }
    }
}

private struct AddRight: View {
    @Environment(AppModel.self) private var model
    let adding: PersonaLibraryBrowser.Adding

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.ui(18, weight: .bold))
                Text("how strongly the evidence points at each").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(adding.proposals.enumerated()), id: \.element.id) { index, proposal in
                        ProposalRow(
                            proposal: proposal, picked: adding.picked.contains(proposal.id),
                            cursor: index == adding.cursor
                        )
                    }
                    if let overlapping = adding.overlapping, let id = overlapping.overlaps,
                       let base = model.personaLibrary.entry(id)?.persona
                    {
                        OverlapCallout(proposal: overlapping, base: base)
                    }
                    if let problem = adding.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .labelStyle(IconLabel()).font(Theme.ui(12.5)).foregroundStyle(Theme.err)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Theme.line.frame(height: 1)
            HStack(spacing: 12) {
                let count = adding.picked.count
                SheetButton(
                    label: count == 0 ? "Define with an agent" : "Define \(count) with an agent",
                    command: "personas.define", scope: "personaadd", primary: true
                )
                SheetButton(label: "Add as drafted", command: "personas.drafted", scope: "personaadd")
                Spacer(minLength: 8)
                Text("space pick · i describe one · ⎋ close").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(24)
    }

    private var title: String {
        if adding.reading, adding.proposals.isEmpty { return "Reading your repos…" }
        let count = adding.proposals.count
        return count == 0 ? "No one yet" : "\(count) \(count == 1 ? "person" : "people") your repos serve"
    }
}

private struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    let proposal: PersonaProposal
    let picked: Bool
    let cursor: Bool

    var body: some View {
        let tint = personaTint(proposal.id)
        HStack(spacing: 14) {
            Image(systemName: picked ? "checkmark" : "")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.inverse : Theme.bg3))
            PersonaTile(name: proposal.persona.name, id: proposal.id, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.persona.name).font(Theme.ui(14.5, weight: .semibold)).lineLimit(1)
                Text(proposal.summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            Spacer(minLength: 10)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(width: 96, height: 4)
                Capsule().fill(tint).frame(width: 96 * CGFloat(proposal.strength) / 100, height: 4)
            }
            .help("How strongly the evidence points at them: \(proposal.strength) of 100")
            Text("\(proposal.strength)").font(Theme.mono(12)).foregroundStyle(Theme.fg2).frame(
                width: 26,
                alignment: .trailing
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cursor ? Theme.paneActive : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .tap { model.clickProposal(proposal.id) }
    }
}

private struct OverlapCallout: View {
    let proposal: PersonaProposal
    let base: Persona

    var body: some View {
        let place = proposal.persona.scope.org ?? "you"
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "questionmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.block)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 12) {
                (Text("Already covered: ").bold() + Text(
                    "“\(base.name)” overlaps with \(proposal.persona.name). Keep both, or make "
                        + "\(proposal.persona.name) a sharper \(base.name) for \(place)?"
                ))
                .font(Theme.ui(13.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SheetButton(
                        label: "sharpen \(base.name) for \(place)", command: "personas.overlap", arguments: ["sharpen"],
                        scope: "personaadd", primary: true
                    )
                    SheetButton(
                        label: "keep both",
                        command: "personas.overlap",
                        arguments: ["keep"],
                        scope: "personaadd"
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }
}

/// Defining a persona with an agent: the conversation on the left (its question, your options, your answers), the
/// persona as it stands on the right with what the agent changed marked, and its trial on a real PR.
struct DefinePersonaSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ui = model.personaUI
        if let definition = ui.current {
            VStack(spacing: 0) {
                DefineHeader(definition: definition, index: ui.defineIndex, count: ui.defining.count)
                Theme.line.frame(height: 1)
                HStack(spacing: 0) {
                    DefineConversation(definition: definition, answering: ui.answering)
                    Theme.line.frame(width: 1)
                    DefinePersonaSide(definition: definition).frame(width: 420)
                }
            }
            .frame(maxWidth: 1240, maxHeight: 860)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shotRegion(.settingsSection, item: "define")
        }
    }
}

private struct DefineHeader: View {
    let definition: PersonaDefinition
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            PersonaTile(name: definition.draft.name, id: definition.id, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Defining \(definition.draft.name)").font(Theme.ui(16, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text("\(index + 1) of \(count)").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
            SheetButton(label: "Next", command: "personas.next", scope: "personadefine")
            SheetButton(label: "Close", command: "personas.close", scope: "personadefine")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let seconds = Int(definition.seconds.rounded())
        let time = seconds >= 60 ? "\(seconds / 60) m \(seconds % 60) s" : "\(seconds) s"
        return [
            definition.via, "reads \(definition.repo ?? "its repo"), writes nothing", seconds > 0 ? time : nil,
            definition.cost.map(AgentUsage.dollars),
        ]
        .compactMap(\.self).joined(separator: " · ")
    }
}

private struct DefineConversation: View {
    @Environment(AppModel.self) private var model
    let definition: PersonaDefinition
    let answering: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !definition.reads.isEmpty {
                        Label("read " + definition.reads.joined(separator: ", "), systemImage: "folder")
                            .labelStyle(IconLabel()).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(Array(definition.turns.enumerated()), id: \.offset) { index, turn in
                        if turn.role == .you, Self.isPick(index, in: definition.turns) {
                            EmptyView()
                        } else if turn.role == .you {
                            HStack {
                                Spacer(minLength: 80)
                                Text(turn.text).font(Theme.ui(14)).padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
                            }
                        } else {
                            AgentTurn(turn: turn, open: index == definition.turns.count - 1)
                        }
                    }
                    if definition.working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(definition.agent) is reading…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                        }
                    }
                    if let problem = definition.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").labelStyle(IconLabel())
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.err)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AnswerField(answering: answering).padding(20)
        }
    }
}

extension DefineConversation {
    /// Your turn is the option you picked, already shown checked on the agent's turn above it.
    static func isPick(_ index: Int, in turns: [PersonaDefinition.Turn]) -> Bool {
        guard index > 0, let picked = turns[index - 1].picked, turns[index - 1].options.indices.contains(picked)
        else { return false }
        return turns[index - 1].options[picked] == turns[index].text
    }
}

private struct AgentTurn: View {
    let turn: PersonaDefinition.Turn
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.text).font(Theme.ui(14.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
            if !turn.options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(turn.options.enumerated()), id: \.offset) { index, option in
                        let picked = turn.picked == index
                        HStack(spacing: 7) {
                            if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            if turn
                                .picked ==
                                nil { Text("\(index + 1)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3) }
                            Text(option).font(Theme.ui(13.5)).lineLimit(1)
                        }
                        .foregroundStyle(picked ? Theme.ink : turn.picked == nil ? Theme.fg : Theme.fg3)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.inverse : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(picked ? .clear : Theme.keyCapBorder))
                        .clickRuns(turn.picked == nil && open
                            ? CommandInvocation(name: "personas.option", arguments: [String(index + 1)]) : nil)
                    }
                }
            }
        }
    }
}

private struct AnswerField: View {
    @Environment(AppModel.self) private var model
    let answering: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(Theme.fg3)
            if answering != nil {
                TextField("Tell it more about this person…", text: $text)
                    .textFieldStyle(.plain).font(Theme.ui(14)).focused($focused)
                    .onSubmit {
                        model.answerPersonaAgent(text)
                        text = ""
                    }
            } else {
                Text("Tell it more about this person…").font(Theme.ui(14)).foregroundStyle(Theme.fg3)
                Spacer(minLength: 4)
                KeyCap(text: model.keyText(for: "personas.answer", in: "personadefine"))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Theme.paneActive : Theme.keyCapBorder))
        .contentShape(Rectangle())
        .onTapGesture { if answering == nil { model.perform(CommandInvocation(name: "personas.answer")) } }
        .onChange(of: answering != nil, initial: true) { _, on in focused = on }
    }
}

private struct DefinePersonaSide: View {
    let definition: PersonaDefinition

    var body: some View {
        let persona = definition.draft
        let marked = definition.changed
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DetailHeader(icon: "star", title: "The persona")
                    GlyphLine(icon: "eye", tint: Theme.fg3) {
                        Text(persona.about.isEmpty ? persona.who : persona.about)
                            .foregroundStyle(marked.contains(persona.about) ? Theme.done : Theme.fg)
                    }
                    if let asks = persona.asksFirst.first {
                        GlyphLine(icon: "questionmark", tint: Theme.block) {
                            Text("asks first: ").foregroundStyle(Theme.fg2)
                                + Text(asks).foregroundStyle(marked.contains(asks) ? Theme.done : Theme.fg)
                        }
                    }
                    if !persona.skepticalAbout.isEmpty {
                        GlyphLine(icon: "arrow.left.arrow.right", tint: Theme.err) {
                            Text("skeptical about: ").foregroundStyle(Theme.fg2) + listed(
                                persona.skepticalAbout,
                                marked
                            )
                        }
                    }
                    GlyphLine(icon: "checkmark.shield", tint: Theme.fg3) {
                        Text("may: ").foregroundStyle(Theme.fg2) + listed(persona.may, marked)
                            + (persona.mayNot.isEmpty ? Text("") : Text(" · may not: ").foregroundStyle(Theme.fg2)
                                + listed(persona.mayNot, marked))
                    }
                    if let trial = definition.trial {
                        TrialCard(id: definition.id, name: persona.name, trial: trial).padding(.top, 8)
                    } else if definition.trying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("reading a merged PR…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                        }
                    }
                }
                .padding(24)
            }
            HStack(spacing: 10) {
                SheetButton(label: "Save persona", command: "personas.save", scope: "personadefine", primary: true)
                SheetButton(
                    label: definition.trial == nil ? "Try it on a PR" : "Try another PR", command: "personas.try",
                    scope: "personadefine"
                )
            }
            .padding(22)
        }
    }

    /// The items, comma separated, the agent's new ones marked.
    private func listed(_ items: [String], _ marked: Set<String>) -> Text {
        items.enumerated().reduce(Text("")) { text, element in
            let piece = Text(element.element).foregroundStyle(marked.contains(element.element) ? Theme.done : Theme.fg2)
            return element.offset == 0 ? piece : text + Text(", ").foregroundStyle(Theme.fg2) + piece
        }
    }
}
