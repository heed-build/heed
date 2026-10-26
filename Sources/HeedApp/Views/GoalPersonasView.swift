import HeedCore
import SwiftUI

/// Personas (`goal.personas`, P in Goals): who should be in the room. On the left the experts the goal needs, worked
/// out from its board, each with why now, how much of its work it has looked at, and its state, gaps first; on the
/// right the one under the cursor: what asked for it, its file (editable), and how to put it to work.
struct GoalPersonasPane: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal

    var body: some View {
        let rows = model.goals.personaRows
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                PersonaTable(rows: rows).frame(maxWidth: .infinity, alignment: .topLeading)
                    .shotRegion(.goalPersonaList)
                VStack(alignment: .leading, spacing: 14) {
                    if let row = model.goals.selectedPersona {
                        PersonaWhy(row: row).shotRegion(.goalPersonaWhy)
                        PersonaFile(goal: goal, row: row).shotRegion(.goalPersonaFile)
                    }
                    Text("Personas are plain files you can edit, share with the team and reuse across goals. "
                        + "Spawning one starts a chat, a session or a reviewer with the persona, the goal, and the "
                        + "evidence above.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                }
                .frame(width: 400)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("How the list is built").font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.fg2)
                Text("Each persona comes with the evidence that asked for it, and a coverage bar: how much of the "
                    + "related work it has looked at. Gaps are shown first.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shotRegion(.goalPersonas)
    }
}

// MARK: The table

private struct PersonaTable: View {
    @Environment(AppModel.self) private var model
    let rows: [PersonaRow]

    var body: some View {
        let goals = model.goals
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Experts this goal needs").font(Theme.ui(14, weight: .semibold))
                Spacer()
                Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            HStack(spacing: 12) {
                Text("PERSONA").frame(width: 190, alignment: .leading)
                Text("WHY NOW").frame(maxWidth: .infinity, alignment: .leading)
                Text("COVERAGE").frame(width: 110, alignment: .leading)
                Text("STATE").frame(width: 76, alignment: .leading)
                Text("").frame(width: 64)
            }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            .padding(.horizontal, 14).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if rows.isEmpty {
                Text(empty).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            ListScroll {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let isCursor = goals.focus == .personas && index == goals.personas.cursor
                        PersonaTableRow(row: row)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(isCursor ? Theme.bg3 : .clear)
                            .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
                            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                            .hint(goals.focus == .personas ? model.hintLabel(for: .row(.goals, index)) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickPersona(index) }
                            .rightClickMenu {
                                guard model.clicksReachLists else { return false }
                                model.clickPersona(index)
                                return true
                            } _: { model.personaMenu(index) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var note: String {
        guard let goal = model.goals.selected, let at = model.goals.personas.boards[goal.id]?.derivedAt else {
            return "from work planned and done · updates as the board changes"
        }
        return "from work planned and done · " + Clock.relative(at)
    }

    private var empty: String {
        "Nobody yet: heed works out who the goal needs once it has items, objections or open questions. "
            + model.keyText(for: "persona.derive", in: "goalpersonas") + " asks now."
    }
}

private struct PersonaTableRow: View {
    @Environment(AppModel.self) private var model
    let row: PersonaRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.persona.name).font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.coverage.state == .gap ? "gap" : row.need.when.text).font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fg3)
            }
            .frame(width: 190, alignment: .leading)
            Text(row.need.why).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CoverageBar(coverage: row.coverage).frame(width: 110).padding(.top, 5)
                .help(row.coverage.text)
            PersonaStateTag(state: row.coverage.state).frame(width: 76, alignment: .leading)
            Group {
                if !row.coverage.spawned.isEmpty {
                    Text(row.coverage.spawned).foregroundStyle(Theme.fg2)
                } else if row.coverage.state == .gap || row.coverage.state == .notYet {
                    Text(model.keyText(for: "persona.session", in: "goalpersonas") + " spawn")
                        .foregroundStyle(Theme.fg3)
                }
            }
            .font(Theme.mono(11)).frame(width: 64, alignment: .trailing)
        }
    }
}

/// One segment per item it is about (at most eight): the ones it looked at lit, blue while it is at work, green after.
struct CoverageBar: View {
    let coverage: PersonaCoverage

    var body: some View {
        let segments = max(min(coverage.total, 8), 4)
        let lit = coverage.total == 0 ? 0 : Int((coverage.share * Double(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0 ..< segments, id: \.self) { index in
                Capsule().fill(index < lit ? tint : Theme.line).frame(height: 5)
            }
        }
    }

    private var tint: Color { coverage.state == .active ? Theme.busy : Theme.done }
}

struct PersonaStateTag: View {
    let state: PersonaState

    var body: some View {
        Text(state.text).font(Theme.mono(10.5, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.6)))
            .fixedSize()
    }

    private var tint: Color {
        switch state {
        case .gap: Theme.block
        case .active: Theme.busy
        case .consulted: Theme.done
        case .notYet: Theme.fg3
        }
    }
}

// MARK: The detail

/// Why it is needed now, and the evidence that asked for it.
private struct PersonaWhy: View {
    let row: PersonaRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PersonaStateTag(state: row.coverage.state)
                Text(row.persona.name).font(Theme.ui(15, weight: .semibold))
            }
            Text(row.need.why).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.need.evidence.isEmpty ? "evidence: none cited"
                : "evidence: " + row.need.evidence.map(\.text).joined(separator: ", "))
                .font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            Text("coverage: " + row.coverage.text).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            row.coverage.state == .gap ? Theme.block.opacity(0.6) : Theme.line
        ))
    }
}

/// The persona's file, as text you can edit, and the spawn controls.
private struct PersonaFile: View {
    @Environment(AppModel.self) private var model
    let goal: HeedGoal
    let row: PersonaRow

    var body: some View {
        let goals = model.goals
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Persona").font(Theme.ui(14, weight: .semibold))
                Spacer()
                Text("\(row.id).md").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .help(goals.files.persona(row.id, goal: goal.id).path)
            }
            Group {
                if let draft = goals.personas.draft, !ShotMode.active {
                    TextEditor(text: Binding(
                        get: { model.goals.personas.draft ?? draft },
                        set: { model.goals.personas.draft = $0 }
                    ))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 170)
                } else {
                    Text(goals.personas.draft ?? row.persona.render().trimmingCharacters(in: .newlines))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.editPersona() }
                }
            }
            .font(Theme.mono(12)).foregroundStyle(Theme.fg)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if ShotMode.active {
                    Picked(text: agent + " ▾")
                    Picked(text: tier + " ▾")
                } else {
                    Menu {
                        Button("The goal's sessions' agent") { model.goals.personas.spawn.agent = nil }
                        ForEach(model.settings.agents.map(\.name), id: \.self) { name in
                            Button(name) { model.goals.personas.spawn.agent = name }
                        }
                    } label: { Picked(text: agent + " ▾") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        ForEach(ModelTier.allCases, id: \.self) { tier in
                            Button(tier.rawValue) { model.goals.personas.spawn.tier = tier }
                        }
                    } label: { Picked(text: tier + " ▾") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                KeyHint("persona.session", scope: "goalpersonas", label: "spawn as session")
                KeyHint("persona.chat", scope: "goalpersonas", label: "as chat")
                KeyHint("persona.reviewer", scope: "goalpersonas", label: "as reviewer")
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                KeyHint(
                    "persona.edit",
                    scope: "goalpersonas",
                    label: goals.personas.draft == nil ? "edit" : "⌘S save",
                    color: Theme.fg2
                )
                KeyHint("persona.share", scope: "goalpersonas", label: "share to the library", color: Theme.fg2)
                KeyHint("persona.derive", scope: "goalpersonas", label: "work out again", color: Theme.fg2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var agent: String { model.goals.personas.spawn.agent ?? "session's agent" }
    private var tier: String { model.goals.personas.spawn.tier.rawValue }
}

private struct Picked: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.fg)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}
