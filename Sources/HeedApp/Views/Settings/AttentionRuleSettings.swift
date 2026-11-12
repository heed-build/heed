import HeedCore
import SwiftUI

/// Settings › Attention: the rules in order, each in plain words; an editor that builds a rule from choices, so only
/// a rule the grammar accepts can be added; what an edit would have changed over the last 30 days before it is saved;
/// and quiet hours. Nothing is written until Save. Lines the editor cannot build stay as written, read-only.
struct AttentionRuleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AttentionRuleDraft(lines: [])
    @State private var form = AttentionRuleForm(weight: .unchanged)
    /// The line being changed (0-based); nil while adding. The list is locked meanwhile.
    @State private var editing: Int?
    @State private var loaded = false

    var body: some View {
        let saved = model.config.attention.rules
        let preview = model.attentionPreview(draft.rules)
        VStack(alignment: .leading, spacing: 16) {
            Text("Attention").font(Theme.ui(17, weight: .semibold))
            Text(
                "What matters in Attention. Each rule matches some items and boosts, lowers, mutes, pins or notifies "
                    + "about them; the first rule that matches an item decides. Muted items stay under Muted for 30 days."
            )
            .font(Theme.ui(12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            GroupLabel(title: "Rules")
            VStack(alignment: .leading, spacing: 6) {
                if draft.saved.isEmpty {
                    Text("No rules yet: every item keeps its normal weight. Add one below.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
                ForEach(Array(draft.readings.enumerated()), id: \.offset) { index, reading in
                    if reading != .blank {
                        row(index, reading, matches: preview.matches[index + 1] ?? 0)
                    }
                }
                if let removed = draft.removed, editing == nil {
                    HStack(spacing: 8) {
                        Text("Removed \(removed.line.trimmingCharacters(in: .whitespaces))")
                            .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.middle)
                        Button("Undo") { draft.undoRemove() }
                    }
                    .padding(.leading, 8)
                }
            }
            RuleEditor(
                form: $form, editing: editing, conflict: draft.conflict(form, replacing: editing),
                items: model.attentionRuleItems, viewer: model.github.viewer,
                suggestions: model.attentionRuleSuggestions, commit: commit, cancel: reset
            )
            GroupLabel(title: "Try before you save")
            VStack(alignment: .leading, spacing: 8) {
                if draft.saved == saved {
                    Text("These are the rules in use. Edit them to see what would change over the last 30 days.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                } else if preview.changed == 0 {
                    Text("Would have changed none of the \(preview.items) items of the last 30 days.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                } else {
                    Text("Would have changed \(preview.changed) of the \(preview.items) items of the last 30 days:")
                        .font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    FlowLayout(spacing: 6) {
                        ForEach(preview.moves, id: \.self) { move in
                            ReasonTag(
                                text: "\(move.from.rawValue) → \(move.to.rawValue): \(move.count)",
                                tint: move.to < move.from ? Theme.block : Theme.busy
                            )
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Save to config.toml") {
                        model.setConfig(
                            ["attention", "rules"], .array(draft.saved.map { .string($0) }), multiline: true
                        )
                    }
                    .disabled(draft.saved == saved)
                    Button("Revert") { load(saved) }.disabled(draft.saved == saved)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            GroupLabel(title: "Weights")
            VStack(alignment: .leading, spacing: 5) {
                weight("boost 3", "top of the feed when sorted by weight; notifies")
                weight("boost 1-2", "higher when sorted by weight")
                weight("lower", "dimmed, lower, never notifies")
                weight("mute", "ignore: out of the feed, under Muted for 30 days")
                weight("pin", "always at the top")
            }
            GroupLabel(title: "Notifications")
            Field(
                label: "Notify",
                detail: "Items a rule says to notify about (notify, or boost 3); several from one sync come as one."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.notifications.attention },
                    set: { model.setConfig(["notifications", "attention"], .bool($0)) }
                )).labelsHidden()
            }
            Field(label: "Quiet hours", detail: "Local time, 24-hour (\"22:00-07:00\"); empty for none.") {
                ConfigTextField(path: ["attention", "quiet"], value: model.config.attention.quiet?.description ?? "")
                    .frame(width: 160)
            }
        }
        .onAppear {
            if !loaded {
                load(model.attention.ruleDraftSeed ?? saved)
                if let seed = model.attention.ruleFormSeed { form = seed }
            }
        }
        .onChange(of: saved) { _, new in if draft.saved == new || !loaded { load(new) } }
    }

    private func load(_ lines: [String]) {
        draft = AttentionRuleDraft(lines: lines)
        reset()
        loaded = true
    }

    private func reset() {
        form = AttentionRuleForm(weight: .unchanged)
        editing = nil
    }

    private var canCommit: Bool { form.isValid && draft.conflict(form, replacing: editing) == nil }

    private func commit() {
        guard canCommit else { return }
        if let editing {
            // An edit that changed nothing leaves the line as it was written.
            if case let .form(original) = AttentionRuleForm.read(draft.lines[editing]), original == form {} else {
                draft.edit(editing, to: form.line)
            }
        } else {
            draft.add(form.line)
        }
        reset()
    }

    private func row(_ index: Int, _ reading: AttentionRuleForm.Reading, matches: Int) -> some View {
        let line = draft.lines[index].trimmingCharacters(in: .whitespaces)
        let locked = editing != nil
        return HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                .frame(width: 18, alignment: .trailing).padding(.top, 1)
            switch reading {
            case let .form(rule):
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(line).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Spacer(minLength: 6)
                ReasonTag(
                    text: rule.action.text, tint: rule.action.ignore ? Theme.err : rule.action.lower ? Theme.busy
                        : Theme.block, filled: true
                )
                Text("\(matches) / 30d").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .frame(width: 58, alignment: .trailing)
                Button { editing = index
                    form = rule
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Change this rule").disabled(locked)
            case .comment:
                Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                Spacer(minLength: 6)
            case let .readOnly(why):
                let problem = draft.problem(line: index + 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(Theme.mono(12)).foregroundStyle(problem == nil ? Theme.fg2 : Theme.err)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(problem.map { "Not used: \($0)." } ?? "The editor cannot build this rule (\(why)).")
                            .font(Theme.ui(11)).foregroundStyle(problem == nil ? Theme.fg3 : Theme.err)
                        Button("Edit in config.toml") { NSWorkspace.shared.open(model.configFile) }
                            .buttonStyle(.link).font(Theme.ui(11))
                    }
                }
                Spacer(minLength: 6)
            case .blank:
                EmptyView()
            }
            Button { draft.move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(locked || index == 0).help("Move up: earlier rules decide first")
            Button { draft.move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(locked || index == draft.lines.count - 1).help("Move down")
            Button { draft.remove(at: index) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).disabled(locked).help("Remove (Undo brings it back)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(editing == index ? Theme.selected : Theme.bg2))
    }

    private func weight(_ action: String, _ meaning: String) -> some View {
        HStack(spacing: 10) {
            Text(action).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2).frame(width: 80, alignment: .leading)
            Text(meaning).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
    }
}

/// Builds one rule from choices: conditions, each a kind and a value, then what to do. Text is typed only for a
/// value the grammar needs (a repo, a label, a login), checked as it is typed; Add stays off until the rule is valid
/// and does not repeat or hide behind another.
private struct RuleEditor: View {
    @Binding var form: AttentionRuleForm
    let editing: Int?
    let conflict: String?
    let items: [AttentionItem]
    let viewer: String?
    let suggestions: AttentionRuleSuggestions
    let commit: () -> Void
    let cancel: () -> Void

    /// Kinds a rule needs at most once.
    private static let once: Set<AttentionClause.Category> = [
        .mentionedMe, .requested, .draft, .turn, .agent, .kind, .author, .team,
    ]

    var body: some View {
        let problems = form.problems
        let valid = problems.isEmpty && conflict == nil
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: editing.map { "Change rule \($0 + 1)" } ?? "Add a rule")
            label("When")
            if form.clauses.isEmpty {
                Text("Every item: add a condition to narrow it.").font(Theme.ui(12))
                    .foregroundStyle(Theme.block).padding(.leading, 8)
            }
            ForEach(Array(form.clauses.enumerated()), id: \.offset) { index, _ in
                ClauseRow(
                    clause: clause(index), problem: problems.first { $0.clause == index }?.message,
                    suggestions: suggestions, submit: commit, remove: { form.clauses.remove(at: index) }
                )
            }
            Menu("Add a condition") {
                ForEach(AttentionClause.Category.allCases.filter { category in
                    !Self.once.contains(category) || !form.clauses.contains { $0.category == category }
                }, id: \.self) { category in
                    Button(category.title) { form.clauses.append(category.initial) }
                }
            }
            .fixedSize()
            label("Then")
            HStack(spacing: 14) {
                Picker("", selection: $form.weight) {
                    ForEach(AttentionRuleForm.Weight.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Toggle("Pin to the top", isOn: $form.pin).disabled(form.weight == .ignore)
                Toggle("Notify me", isOn: $form.notify).disabled(form.weight == .ignore)
                if form.weight == .ignore {
                    Text("A muted item takes no other action.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.leading, 8)
            Theme.line.frame(height: 1)
            Text(form.summary).font(Theme.ui(13, weight: .medium))
                .foregroundStyle(valid ? Theme.fg : Theme.fg3).fixedSize(horizontal: false, vertical: true)
            matchLine
            ForEach(problems.filter { $0.clause == nil }, id: \.self) { problem in
                FieldNoteView(note: FieldNote("rule", problem.message))
            }
            if let conflict {
                FieldNoteView(note: FieldNote("rule", conflict))
            }
            HStack(spacing: 10) {
                Button(editing == nil ? "Add rule" : "Update rule", action: commit).disabled(!valid)
                if editing != nil || form != AttentionRuleForm(weight: .unchanged) {
                    Button(editing == nil ? "Clear" : "Cancel", action: cancel)
                }
                if valid {
                    Text(form.line).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// How many of the last 30 days' items the rule matches on its own: a rule that catches most of them says so.
    @ViewBuilder private var matchLine: some View {
        if form.problems.isEmpty, !items.isEmpty {
            let count = form.matchCount(in: items, viewer: viewer, now: Clock.now)
            let broad = count * 2 > items.count
            Text(
                "Matches \(count) of the \(items.count) items of the last 30 days"
                    + (broad ? ": most of them. Narrow it with another condition?" : ".")
            )
            .font(Theme.ui(12)).foregroundStyle(broad ? Theme.block : Theme.fg2)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.fg2)
    }

    private func clause(_ index: Int) -> Binding<AttentionClause> {
        Binding(
            get: { form.clauses.indices.contains(index) ? form.clauses[index] : .mentionedMe },
            set: { if form.clauses.indices.contains(index) { form.clauses[index] = $0 } }
        )
    }
}

/// One condition: what kind it is, then its value, then its problem underneath.
private struct ClauseRow: View {
    @Binding var clause: AttentionClause
    let problem: String?
    let suggestions: AttentionRuleSuggestions
    let submit: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("", selection: Binding(
                    get: { clause.category },
                    set: { if $0 != clause.category { clause = $0.initial } }
                )) {
                    ForEach(AttentionClause.Category.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                value
                Spacer(minLength: 6)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this condition")
            }
            if let problem {
                FieldNoteView(note: FieldNote("condition", problem)).padding(.leading, 198)
            }
        }
        .padding(.leading, 8)
    }

    @ViewBuilder private var value: some View {
        switch clause {
        case let .reason(word):
            Picker("", selection: Binding(get: { word }, set: { clause = .reason($0) })) {
                ForEach(AttentionReasonWord.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
        case let .reasons(reasons):
            Chips(options: AttentionReason.allCases, selected: reasons, title: \.text) { clause = .reasons($0) }
        case .mentionedMe:
            hint("you yourself were @-mentioned")
        case .team, .teamUnknown:
            let unknown = clause == .teamUnknown
            Picker("", selection: Binding(
                get: { unknown },
                set: { clause = $0 ? .teamUnknown : .team("") }
            )) {
                Text("named").tag(false)
                Text("heed could not work out which").tag(true)
            }
            .labelsHidden().fixedSize()
            if case let .team(glob) = clause {
                GlobField(text: glob, placeholder: "acme/docs-eng", suggestions: suggestions.teams, submit: submit) {
                    clause = .team($0)
                }
            }
        case let .requestedOfMe(me):
            Picker("", selection: Binding(get: { me }, set: { clause = .requestedOfMe($0) })) {
                Text("you").tag(true)
                Text("one of your teams").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case let .author(author):
            AuthorValue(author: author, suggestions: suggestions, submit: submit) { clause = .author($0) }
        case let .label(label):
            GlobField(text: label, placeholder: "blocker", suggestions: suggestions.labels, submit: submit) {
                clause = .label($0)
            }
        case let .repo(glob):
            GlobField(text: glob, placeholder: "acme/api", suggestions: suggestions.repos, submit: submit) {
                clause = .repo($0)
            }
        case let .branch(glob):
            GlobField(text: glob, placeholder: "main", suggestions: suggestions.branches, submit: submit) {
                clause = .branch($0)
            }
        case let .agent(states):
            Chips(options: AgentState.allCases, selected: states, title: \.rawValue) { clause = .agent($0) }
            if states.isEmpty { hint("none picked: any agent") }
        case let .kind(kinds):
            Chips(options: AttentionClause.kindOrder, selected: kinds, title: \.rawValue) { clause = .kind($0) }
        case let .draft(draft):
            Picker("", selection: Binding(get: { draft }, set: { clause = .draft($0) })) {
                Text("a draft").tag(true)
                Text("ready for review").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case let .size(greater, lines):
            Picker("", selection: Binding(get: { greater }, set: { clause = .size(greater: $0, lines: lines) })) {
                Text("more than").tag(true)
                Text("fewer than").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField(
                "",
                value: Binding(get: { lines }, set: { clause = .size(greater: greater, lines: $0) }),
                format: .number
            )
            .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 70).onSubmit(submit)
            hint("lines changed")
        case let .age(greater, amount, unit):
            Picker("", selection: Binding(
                get: { greater }, set: { clause = .age(greater: $0, amount: amount, unit: unit) }
            )) {
                Text("over").tag(true)
                Text("within").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField("", value: Binding(
                get: { amount }, set: { clause = .age(greater: greater, amount: $0, unit: unit) }
            ), format: .number)
                .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 56).onSubmit(submit)
            Picker("", selection: Binding(
                get: { unit }, set: { clause = .age(greater: greater, amount: amount, unit: $0) }
            )) {
                ForEach(AttentionClause.AgeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            hint("since its last update")
        case let .turn(mine):
            Picker("", selection: Binding(get: { mine }, set: { clause = .turn(mine: $0) })) {
                Text("yours (someone else spoke last)").tag(true)
                Text("theirs (you spoke last)").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
    }
}

/// Who opened it: a choice, and a login only for "someone" or "a bot named".
private struct AuthorValue: View {
    let author: AttentionClause.Author
    let suggestions: AttentionRuleSuggestions
    let submit: () -> Void
    let set: (AttentionClause.Author) -> Void

    private enum Choice: String, CaseIterable {
        case me = "you", human = "a person", anyBot = "any bot", bot = "the bot", login = "the login"
    }

    private var choice: Choice {
        switch author {
        case .me: .me
        case .human: .human
        case .anyBot: .anyBot
        case .bot: .bot
        case .login: .login
        }
    }

    var body: some View {
        Picker("", selection: Binding(get: { choice }, set: { picked in
            switch picked {
            case .me: set(.me)
            case .human: set(.human)
            case .anyBot: set(.anyBot)
            case .bot: set(.bot(suggestions.bots.first ?? ""))
            case .login: set(.login(""))
            }
        })) {
            ForEach(Choice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().fixedSize()
        switch author {
        case let .bot(name):
            GlobField(text: name, placeholder: "dependabot", suggestions: suggestions.bots, submit: submit) {
                set(.bot($0))
            }
        case let .login(login):
            GlobField(text: login, placeholder: "maria", suggestions: suggestions.authors, submit: submit) {
                set(.login($0))
            }
        default:
            EmptyView()
        }
    }
}

/// A value typed or picked from what heed has seen: return adds the rule (when it is valid).
private struct GlobField: View {
    let text: String
    let placeholder: String
    let suggestions: [String]
    let submit: () -> Void
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: Binding(get: { text }, set: { set($0) }))
                .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(minWidth: 140, maxWidth: 240)
                .onSubmit(submit)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { value in Button(value) { set(value) } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pick one heed has seen")
            }
        }
    }
}

/// Several of a fixed set, each a toggle.
private struct Chips<Option: Hashable>: View {
    let options: [Option]
    let selected: Set<Option>
    let title: KeyPath<Option, String>
    let set: (Set<Option>) -> Void

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(options, id: \.self) { option in
                Toggle(option[keyPath: title], isOn: Binding(
                    get: { selected.contains(option) },
                    set: { on in set(on ? selected.union([option]) : selected.subtracting([option])) }
                ))
                .toggleStyle(.button).controlSize(.small)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
