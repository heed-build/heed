import HeedCore
import SwiftUI

// Model and effort pickers: every place heed lets you choose a model offers the agent's default, the models it knows
// for that agent (`AgentModels`, with what the CLI lists laid over them), and Custom… with a text field for any other
// id; an effort picker beside it when the agent takes one. What they offer and store is `ModelPicker`.

/// A model dropdown in Settings' style (a native menu), with the custom id's field beside it once Custom… is picked.
/// `set(nil)` stores nothing: the agent's default.
struct ModelMenuPicker: View {
    let catalog: AgentModelCatalog
    let value: String?
    let set: (String?) -> Void
    var width: CGFloat = 220
    /// What the default entry says, when it is more than the agent's default ("the run model").
    var defaultLabel: String?
    @State private var customPicked = false

    var body: some View {
        let selection = customPicked ? ModelPicker.customTag : ModelPicker.selection(value, in: catalog)
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { selection },
                set: { tag in
                    customPicked = tag == ModelPicker.customTag
                    let next = ModelPicker.value(picking: tag, current: value, in: catalog)
                    if tag != ModelPicker.customTag || next != nil { set(next) }
                }
            )) {
                ForEach(ModelPicker.models(catalog), id: \.tag) { option in
                    Text(option.tag == ModelPicker.defaultTag ? defaultLabel ?? option.label : Self.text(option))
                        .tag(option.tag)
                }
            }
            .labelsHidden()
            .frame(width: width)
            .help(catalog.source.isEmpty ? "Models of \(catalog.agent)" : "Models from \(catalog.source)")
            if selection == ModelPicker.customTag {
                CustomModelField(value: catalog.model(value) == nil ? value ?? "" : "", set: set)
            }
        }
        .onChange(of: catalog.agent) { customPicked = false }
    }

    /// `Opus 5.5 · claude-opus-5-5`, or the id alone.
    static func text(_ option: ModelPicker.Option) -> String {
        option.detail.map { "\(option.label) · \($0)" } ?? option.label
    }
}

/// The custom model id: written when you press return or leave the field, refused (and said why) when empty.
struct CustomModelField: View {
    let value: String
    let set: (String?) -> Void
    var width: CGFloat = 200
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if ShotMode.active {
                Text(value.isEmpty ? "model id" : value).font(Theme.mono(12))
                    .foregroundStyle(value.isEmpty ? Theme.fg3 : Theme.fg)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(width: width, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            } else {
                TextField("model id", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .frame(width: width)
                    .focused($focused)
                    .onAppear {
                        text = value
                        if value.isEmpty { focused = true }
                    }
                    .onChange(of: value) { if !focused { text = value } }
                    .onSubmit(save)
                    .onChange(of: focused) { if !focused { save() } }
            }
            FieldNoteView(note: problem.map { FieldNote("model", $0) })
        }
    }

    private func save() {
        problem = ModelPicker.problem(custom: text)
        guard problem == nil else { return }
        let id = text.trimmingCharacters(in: .whitespaces)
        if id != value { set(id) }
    }
}

/// An effort dropdown for the agent and model picked; nothing when the agent takes no effort.
struct EffortMenuPicker: View {
    let catalog: AgentModelCatalog
    let model: String?
    let value: String?
    let set: (String?) -> Void
    var width: CGFloat = 160
    var defaultLabel: String?

    var body: some View {
        let options = ModelPicker.efforts(catalog, model: model, current: value)
        if !options.isEmpty {
            Picker("", selection: Binding(
                get: { value ?? ModelPicker.defaultTag },
                set: { set($0 == ModelPicker.defaultTag ? nil : $0) }
            )) {
                ForEach(options, id: \.tag) { option in
                    Text(option.tag == ModelPicker.defaultTag ? defaultLabel ?? option.label : option.label)
                        .tag(option.tag)
                }
            }
            .labelsHidden()
            .frame(width: width)
        }
    }
}

/// A model and effort picker over config keys (Settings): picking writes the key, the default removes it.
struct ConfigModelPicker: View {
    @Environment(AppModel.self) private var model
    let agent: String
    let modelPath: [String]
    let modelValue: String?
    /// nil: no effort key here.
    var effortPath: [String]?
    var effortValue: String?
    var defaultLabel: String?
    var effortDefaultLabel: String?
    /// The default writes "" instead of removing the key (keys the default config.toml lists empty).
    var emptyIsDefault = false

    var body: some View {
        let catalog = model.modelCatalog(agent)
        HStack(alignment: .top, spacing: 8) {
            ModelMenuPicker(
                catalog: catalog,
                value: modelValue,
                set: { write(modelPath, $0) },
                defaultLabel: defaultLabel
            )
            if let effortPath {
                EffortMenuPicker(
                    catalog: catalog, model: modelValue, value: effortValue, set: { write(effortPath, $0) },
                    defaultLabel: effortDefaultLabel
                )
            }
        }
    }

    private func write(_ path: [String], _ value: String?) {
        if let value { model.setConfig(path, .string(value)) } else if emptyIsDefault {
            model.setConfig(path, .string(""))
        } else {
            model.unsetConfig(path)
        }
    }
}

/// A model and effort as chips with menus, for heed's own overlays (the swarm form): the chip says what is picked,
/// a click opens the list. Custom… shows the id's field under them.
struct ModelChips: View {
    let catalog: AgentModelCatalog
    let model: String?
    let effort: String?
    let setModel: (String?) -> Void
    let setEffort: (String?) -> Void
    @State private var customPicked = false

    var body: some View {
        let selection = customPicked ? ModelPicker.customTag : ModelPicker.selection(model, in: catalog)
        let efforts = ModelPicker.efforts(catalog, model: model, current: effort)
        HStack(spacing: 6) {
            if catalog.takesModel {
                chip(modelText(selection)) {
                    ForEach(ModelPicker.models(catalog), id: \.tag) { option in
                        Button(ModelMenuPicker.text(option)) {
                            customPicked = option.tag == ModelPicker.customTag
                            let next = ModelPicker.value(picking: option.tag, current: model, in: catalog)
                            if option.tag != ModelPicker.customTag || next != nil { setModel(next) }
                        }
                    }
                }
                .help(catalog.source.isEmpty ? "Models of \(catalog.agent)" : "Models from \(catalog.source)")
            }
            if !efforts.isEmpty {
                chip(effort.map { "effort \($0)" } ?? "default effort") {
                    ForEach(efforts, id: \.tag) { option in
                        Button(option.label) { setEffort(option.tag == ModelPicker.defaultTag ? nil : option.tag) }
                    }
                }
                .help("Reasoning effort")
            }
            if selection == ModelPicker.customTag {
                CustomModelField(value: catalog.model(model) == nil ? model ?? "" : "", set: setModel, width: 150)
            }
        }
        .onChange(of: catalog.agent) { customPicked = false }
    }

    private func modelText(_ selection: String) -> String {
        switch selection {
        case ModelPicker.defaultTag: "default model"
        case ModelPicker.customTag: "custom"
        default: catalog.model(selection)?.label ?? selection
        }
    }

    @ViewBuilder private func chip(_ text: String, @ViewBuilder items: () -> some View) -> some View {
        let label = Text(text + " ▾").font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
        if ShotMode.active {
            label
        } else {
            Menu { items() } label: { label }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}
