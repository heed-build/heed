import HeedCore
import SwiftUI

// What every Settings page is made of: sections (a name over a card of rows), rows (label and description on the
// left, the control on the right, the catalog's modified and refused marks on every one), and the controls rows use.

/// Where each section of the page is in the scrolled pane, for the tree's "in view".
struct SectionOffsetsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The page's title and the line under it; under Only modified, how many of its settings are changed and Reset all,
/// which asks first and then removes their keys from config.toml.
struct SettingsPageHeader: View {
    @Environment(AppModel.self) private var model
    let page: SettingsPage
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title).font(Theme.ui(17, weight: .semibold))
            if model.settingsFilter.onlyModified {
                let changes = SettingsCatalog.changes(on: page, in: model.config, problems: model.configProblems)
                HStack(spacing: 4) {
                    Text(Self.summary(changes) + " · showing only those ·").foregroundStyle(Theme.fg2)
                    Button("Reset all \(changes.count)") { confirming = true }
                        .buttonStyle(.link)
                        .disabled(changes.isEmpty)
                }
                .font(Theme.ui(12.5))
                .confirmationDialog(
                    "Reset \(changes.count) setting\(changes.count == 1 ? "" : "s") on \(page.title)?",
                    isPresented: $confirming
                ) {
                    Button("Reset all \(changes.count)", role: .destructive) {
                        model.unsetConfig(all: SettingsCatalog.resetPaths(changes))
                    }
                } message: {
                    Text(Self.removing(SettingsCatalog.resetPaths(changes)))
                }
            } else {
                Text(page.subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `3 modified`, `2 modified · 1 refused`.
    static func summary(_ changes: [SettingState]) -> String {
        let modified = changes.count { $0.isModified }
        let refused = changes.count { !$0.isModified && !$0.problems.isEmpty }
        return refused == 0 ? "\(modified) modified" : "\(modified) modified · \(refused) refused"
    }

    /// What the confirmation says goes: the keys, as config.toml has them.
    static func removing(_ paths: [[String]]) -> String {
        let keys = paths.map(SettingsCatalog.keyText)
        let shown = keys.prefix(8).joined(separator: "\n")
        let more = keys.count > 8 ? "\nand \(keys.count - 8) more" : ""
        return "These keys are removed from config.toml, and heed's defaults apply:\n" + shown + more
    }
}

/// What a line of a card is, for the card: a setting drawn, an advanced one hidden (counted in the card's foot), or
/// anything else (a note, a status, a button row).
enum SettingsLine: Equatable {
    case other, setting, hiddenAdvanced
}

extension ContainerValues {
    @Entry var settingsLine: SettingsLine = .other
}

/// A section of a page: its name, a note under it, then its rows in one card (bg2, a hairline between rows), and when
/// Show advanced hides some of them, "2 advanced hidden · Show" at its foot. Under Only modified it keeps only its
/// setting rows, and draws nothing when none is left. `bare` sections hold something else than rows (a list, a
/// status card) and draw no card; under Only modified one shows only while its section holds a change. The tree
/// scrolls to it by name.
struct SettingsCard<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsPage) private var page
    let title: String
    var note: String?
    var bare = false
    @ViewBuilder let content: Content

    var body: some View {
        let onlyModified = model.settingsFilter.onlyModified
        if bare {
            if !onlyModified || isChanged {
                section { content }
            }
        } else {
            Group(subviews: content) { lines in
                let hidden = lines.count(where: { $0.containerValues.settingsLine == .hiddenAdvanced })
                let rows = lines.filter { line in
                    onlyModified ? line.containerValues.settingsLine == .setting
                        : line.containerValues.settingsLine != .hiddenAdvanced
                }
                if !onlyModified || !rows.isEmpty {
                    section {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                if row.id != rows.first?.id { Theme.line.frame(height: 1) }
                                row
                            }
                            if hidden > 0 {
                                if !rows.isEmpty { Theme.line.frame(height: 1) }
                                AdvancedHiddenNote(count: hidden)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    }
                }
            }
        }
    }

    /// A bare section holds a change: by its name on the page shown.
    private var isChanged: Bool {
        guard let page else { return false }
        return SettingsCatalog.counts(in: model.config, problems: model.configProblems)
            .isChanged(.section(page, title))
    }

    private func section(@ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.leading, 2)
            if let note, !model.settingsFilter.onlyModified {
                Text(note).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(title)
        .background(GeometryReader { geometry in
            Color.clear.preference(
                key: SectionOffsetsKey.self, value: [title: geometry.frame(in: .named(SettingsView.scrollSpace)).minY]
            )
        })
    }
}

/// A card's foot while Show advanced is off: how many of its rows it hides, and Show (which turns the switch on).
struct AdvancedHiddenNote: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) advanced hidden ·").foregroundStyle(Theme.fg3)
            Button("Show") { model.settingsFilter.showAdvanced = true }
                .buttonStyle(.link)
                .help("Show advanced settings, on every page (:settings.advanced)")
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// The page Settings shows, for what its cards look up by section.
    @Entry var settingsPage: SettingsPage?
}

extension View {
    /// A row of a card as the card counts it: drawn, or an advanced one Show advanced hides.
    @ViewBuilder func settingsLine(_ visibility: SettingVisibility) -> some View {
        switch visibility {
        case .shown: containerValue(\.settingsLine, .setting)
        case .hiddenAdvanced: Color.clear.frame(width: 0, height: 0).containerValue(\.settingsLine, .hiddenAdvanced)
        case .hidden: EmptyView()
        }
    }
}

/// One setting (or a few shown as one, like a model and its effort): label, description, the control right-aligned.
/// Driven by the catalog: modified is an amber bar on the leading edge, "Default: …" under the description and ↺ (dim
/// when there is nothing to reset); a value config.toml refuses is a red bar, the reason and an example. A setting
/// that only means something while another is on is indented, and hidden while that one is off.
struct SettingRow<Control: View>: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    var target: SettingTarget = .global
    var label: String?
    var detail: String?
    /// What "Default: …" says; nil: the catalog's default, with `unit` after a number.
    var defaultText: String?
    var unit: String?
    /// The control under the text, as wide as the row (instructions, lists, rules).
    var stacked = false
    /// Off for a row whose key cannot go (a custom agent's command).
    var resettable = true
    /// Indented under the row above although the catalog has no parent for it.
    var indented = false
    @ViewBuilder let control: Control

    init(
        _ id: String, _ more: String..., target: SettingTarget = .global, label: String? = nil, detail: String? = nil,
        defaultText: String? = nil, unit: String? = nil, stacked: Bool = false, resettable: Bool = true,
        indented: Bool = false, @ViewBuilder control: () -> Control
    ) {
        ids = [id] + more
        self.target = target
        self.label = label
        self.detail = detail
        self.defaultText = defaultText
        self.unit = unit
        self.stacked = stacked
        self.resettable = resettable
        self.indented = indented
        self.control = control()
    }

    var body: some View {
        let config = model.config
        let entries = ids.compactMap(SettingsCatalog.entry)
        let modified = entries.filter { SettingsCatalog.isModified($0, at: target, in: config) }
        let problems = entries.flatMap { SettingsCatalog.problems(for: $0, at: target, in: model.configProblems) }
        let visibility = SettingsCatalog.visibility(
            ids, at: target, in: config, problems: model.configProblems, filter: model.settingsFilter
        )
        if visibility == .shown {
            // Under Only modified the parent may not show: nothing is indented under what is not there.
            let indent = !model.settingsFilter.onlyModified && (indented || SettingsCatalog.parents[ids[0]] != nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    text(entries, modified: !modified.isEmpty, problems: problems)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !stacked { control.fixedSize() }
                    reset(modified, refused: problems)
                }
                if stacked { control.padding(.trailing, 28) }
            }
            .padding(.leading, indent ? 34 : 14)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if !problems.isEmpty {
                    Theme.err.frame(width: 3)
                } else if !modified.isEmpty {
                    Theme.block.frame(width: 3)
                }
            }
            .opacity(isDimmed ? 0.55 : 1)
            .settingsLine(.shown)
        } else {
            EmptyView().settingsLine(visibility)
        }
    }

    /// Set although its parent is off: shown, but quiet.
    private var isDimmed: Bool {
        guard let parent = SettingsCatalog.parents[ids[0]].flatMap(SettingsCatalog.entry) else { return false }
        return SettingsCatalog.value(parent, in: model.config) == .bool(false)
    }

    private func text(_ entries: [SettingsEntry], modified: Bool, problems: [SettingProblem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label ?? entries.first?.label ?? ids[0]).font(Theme.ui(13)).foregroundStyle(Theme.fg)
            if let detail = detail ?? entries.first?.detail, !detail.isEmpty {
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if modified, problems.isEmpty {
                Text("Default: \(defaultText ?? Self.defaultText(entries, at: target, in: model.config, unit: unit)).")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(problems, id: \.self) { problem in
                Text("config.toml: \(problem.reason). Like \(problem.example)")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func reset(_ modified: [SettingsEntry], refused: [SettingProblem]) -> some View {
        // A refused value is reset too: removing it is what heed already uses.
        let refusedEntries = refused.compactMap { SettingsCatalog.entry($0.entryID) }
        let entries = modified + refusedEntries.filter { entry in !modified.contains { $0.id == entry.id } }
        let canReset = resettable && !entries.isEmpty
        return Button {
            for entry in entries {
                if let path = entry.path(at: target) { model.unsetConfig(path) }
            }
        } label: {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(canReset ? Theme.fg2 : Theme.fg3.opacity(0.3))
        .disabled(!canReset)
        .help(canReset ? "Back to heed's default" : "At heed's default")
        .frame(width: 14)
    }

    /// heed's default as the row says it: `30 s`, `on`, `none`, the agent's own (unset).
    static func defaultText(
        _ entries: [SettingsEntry], at target: SettingTarget, in config: HeedConfig, unit: String?
    ) -> String {
        let parts = entries.map { entry -> String in
            guard let value = SettingsCatalog.defaultValue(entry, at: target, in: config) else { return "unset" }
            switch value {
            case .integer, .number: return unit.map { "\(value) \($0)" } ?? value.description
            case let .text(text) where !text.isEmpty: return text
            default: return value.description
            }
        }
        return parts.count == 2 && parts[0] == parts[1] ? parts[0] : parts.joined(separator: " · ")
    }
}

/// A row with nothing to set: something heed found or keeps (a status, counts), label left, value right.
struct InfoRow<Value: View>: View {
    let label: String
    var detail: String?
    var stacked = false
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    if let detail {
                        Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked { value }
                Color.clear.frame(width: 14, height: 1)
            }
            if stacked { value }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line of a card that is not a setting: a note, a link, a button row.
struct CardNote<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(Theme.ui(12))
            .foregroundStyle(Theme.fg3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Controls

/// On or off: always a switch.
struct ConfigSwitch: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let isOn: Bool

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { model.setConfig(path, .bool($0)) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.done)
            .labelsHidden()
    }
}

/// A number with its unit, at a fixed width: typed (written on return or leaving the field) or stepped. Typed text
/// that is not a number in range goes back to the value.
struct NumberField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: Double
    var unit: String?
    var range: ClosedRange<Double> = 0 ... 1_000_000
    var step: Double = 1
    /// 0 writes an integer; more, a decimal with that many places.
    var places = 0
    var width: CGFloat = 62
    @State private var text = ""
    @FocusState private var focused: Bool

    init(
        path: [String], value: Int, unit: String? = nil, range: ClosedRange<Int> = 0 ... 1_000_000, step: Int = 1,
        width: CGFloat = 62
    ) {
        self.path = path
        self.value = Double(value)
        self.unit = unit
        self.range = Double(range.lowerBound) ... Double(range.upperBound)
        self.step = Double(step)
        self.width = width
    }

    init(
        path: [String], decimal: Double, unit: String? = nil, range: ClosedRange<Double>, step: Double, places: Int,
        width: CGFloat = 62
    ) {
        self.path = path
        value = decimal
        self.unit = unit
        self.range = range
        self.step = step
        self.places = places
        self.width = width
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12.5))
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused($focused)
                .onAppear { text = Self.text(value, places) }
                .onChange(of: value) { if !focused { text = Self.text(value, places) } }
                .onSubmit { save(text) }
                .onChange(of: focused) { if !focused { save(text) } }
            if let unit {
                Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Stepper("", value: Binding(get: { value }, set: { write($0) }), in: range, step: step).labelsHidden()
                .padding(.leading, -4)
        }
    }

    static func text(_ value: Double, _ places: Int) -> String {
        places == 0 ? String(Int(value.rounded())) : String(format: "%.\(places)f", value)
    }

    private func save(_ typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), range.contains(number) else {
            text = Self.text(value, places)
            return
        }
        write(number)
    }

    private func write(_ number: Double) {
        let scale = pow(10, Double(places))
        let rounded = (number * scale).rounded() / scale
        guard rounded != value else { return }
        model.setConfig(path, places == 0 ? .integer(Int(rounded)) : .float(rounded))
    }
}

/// A short choice, as segments.
struct SegmentedChoice<Value: Hashable>: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: Value
    let options: [(Value, String)]
    /// What config.toml takes for an option.
    let name: (Value) -> String
    var width: CGFloat?

    var body: some View {
        Picker("", selection: Binding(get: { value }, set: { model.setConfig(path, .string(name($0))) })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: width ?? CGFloat(options.count) * 70)
    }
}

/// Several of a list on or off, as chips (a list config.toml writes in this order).
struct ChipToggles: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let options: [(String, String)]
    let chosen: Set<String>
    /// Off: at least one stays on.
    var allowNone = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { name, title in
                let on = chosen.contains(name)
                Button {
                    var next = chosen
                    if on { next.remove(name) } else { next.insert(name) }
                    guard allowNone || !next.isEmpty else { return }
                    model.setConfig(path, .array(options.map(\.0).filter(next.contains).map { .string($0) }))
                } label: {
                    Text(title)
                        .font(Theme.ui(11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.fg : Theme.fg3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.selected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Theme.keyCapBorder : Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A text field that writes to config.toml when you press return or leave it.
struct ConfigTextField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    var placeholder = ""
    var width: CGFloat = 240
    /// Emptied, the key is removed (heed's default) rather than set to "".
    var emptyUnsets = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .frame(width: width)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != value else { return }
        if emptyUnsets, text.trimmingCharacters(in: .whitespaces).isEmpty {
            model.unsetConfig(path)
        } else {
            model.setConfig(path, .string(text))
        }
    }
}

/// A comma separated list written to config.toml as an array.
struct ListField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let values: [String]
    var width: CGFloat = 240
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("comma separated", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .frame(width: width)
            .focused($focused)
            .onAppear { text = values.joined(separator: ", ") }
            .onChange(of: values) { if !focused { text = values.joined(separator: ", ") } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard list != values else { return }
        model.setConfig(path, .array(list.map { .string($0) }))
    }
}

/// A list of lines (questions), one item a line, written as an array when you leave the field.
struct LinesField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let values: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("one a line", text: $text, axis: .vertical)
            .lineLimit(2 ... 8)
            .textFieldStyle(.roundedBorder)
            .font(Theme.ui(12.5))
            .focused($focused)
            .onAppear { text = values.joined(separator: "\n") }
            .onChange(of: values) { if !focused { text = values.joined(separator: "\n") } }
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines != values else { return }
        model.setConfig(path, .array(lines.map { .string($0) }), multiline: true)
    }
}

/// Instructions added to a prompt: several lines, written when you leave the field (⌘↩ too).
struct InstructionsField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    /// nil: as wide as the row allows.
    var width: CGFloat?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("none", text: $text, axis: .vertical)
            .lineLimit(2 ... 6)
            .textFieldStyle(.roundedBorder)
            .font(Theme.ui(12.5))
            .frame(maxWidth: width ?? .infinity)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != value else { return }
        model.setConfig(path, .string(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// A duration from a short list, written as text (`"1h"`): a value set in config.toml outside the list shows too.
struct DurationPicker: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let options: [String]
    let current: String

    var body: some View {
        Picker("", selection: Binding(get: { current }, set: { model.setConfig(path, .string($0)) })) {
            ForEach(options.contains(current) ? options : options + [current], id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 160)
    }
}

/// A choice from a menu; the empty tag is the key removed (heed's default).
struct MenuChoice: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    let options: [(String, String)]
    var width: CGFloat = 200

    var body: some View {
        Picker("", selection: Binding(
            get: { value },
            set: { $0.isEmpty ? model.unsetConfig(path) : model.setConfig(path, .string($0)) }
        )) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            if !options.contains(where: { $0.0 == value }) { Text(value).tag(value) }
        }
        .labelsHidden()
        .frame(width: width)
    }
}

/// A dollar amount, written as a TOML number when it is one (0 or more); anything else is said, not written.
struct DollarsField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: Double
    var unit = "a day"
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Text("$").font(Theme.mono(12.5)).foregroundStyle(Theme.fg3)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12.5))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                    .focused($focused)
                    .onAppear { text = Self.text(value) }
                    .onChange(of: value) { if !focused { text = Self.text(value) } }
                    .onSubmit(save)
                    .onChange(of: focused) { if !focused { save() } }
                Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.fg3).frame(width: 34 + 22, alignment: .leading)
            }
            FieldNoteView(note: problem.map { FieldNote("value", $0) })
        }
    }

    static func text(_ value: Double) -> String { String(format: "%.2f", value) }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let dollars = Double(trimmed), dollars >= 0 else {
            problem = "a number of dollars, 0 or more"
            return
        }
        problem = nil
        guard dollars != value else { return }
        model.setConfig(path, .float(dollars))
    }
}

/// "Edit in config.toml", for what Settings only shows.
struct EditInConfigButton: View {
    @Environment(AppModel.self) private var model
    var title = "Edit in config.toml"

    var body: some View {
        Button(title) { NSWorkspace.shared.open(model.configFile) }
            .buttonStyle(.link)
            .font(Theme.ui(12))
    }
}

/// A link to another page of Settings (`General ›`).
struct PageLink: View {
    @Environment(AppModel.self) private var model
    let page: SettingsPage
    var title: String?
    var before: () -> Void = {}

    var body: some View {
        Button("\(title ?? page.title) ›") {
            before()
            model.settingsPage = page
        }
        .buttonStyle(.link)
        .font(Theme.ui(12))
    }
}

extension View {
    /// A card's look, for what a bare section draws itself.
    func settingsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}
