import Foundation

/// What a model or effort picker offers and what it stores, for every place heed lets you choose one (the swarm
/// form, Start work, Settings): the agent's default (stored as nothing), the catalogue's models, and Custom… for any
/// other id. The views draw these; the logic lives here so it is tested once.
public enum ModelPicker {
    /// One entry of a picker: the tag the view selects by, and what it shows.
    public struct Option: Hashable, Sendable {
        public var tag: String
        public var label: String
        /// The model id shown beside the label, when it differs from it.
        public var detail: String?
    }

    /// The tag of "Custom…": never a model id (ids have no spaces).
    public static let customTag = " custom"
    /// The tag of the agent's default: nothing stored.
    public static let defaultTag = ""

    /// The model picker's entries: the agent's default, the catalogue's models newest first, and Custom….
    public static func models(_ catalog: AgentModelCatalog) -> [Option] {
        [Option(tag: defaultTag, label: catalog.configuredModel.map { "default (\($0))" } ?? "agent's default")]
            + catalog.models.map { Option(tag: $0.id, label: $0.label, detail: $0.label == $0.id ? nil : $0.id) }
            + [Option(tag: customTag, label: "Custom…")]
    }

    /// The tag a stored model selects: the default for none, its own for a known id, Custom… for any other.
    public static func selection(_ value: String?, in catalog: AgentModelCatalog) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return defaultTag }
        return catalog.model(value) != nil ? value : customTag
    }

    /// What picking `tag` stores, given what is stored now: nil for the default, the id for a model, and for Custom…
    /// the current value kept (it is typed next) or nil when there is none yet.
    public static func value(picking tag: String, current: String?, in catalog: AgentModelCatalog) -> String? {
        switch tag {
        case defaultTag: return nil
        case customTag:
            guard let current, !current.isEmpty, catalog.model(current) == nil else { return nil }
            return current
        default: return tag
        }
    }

    /// Why a typed custom id cannot be stored; nil when it can.
    public static func problem(custom text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespaces)
        if id.isEmpty { return "type a model id" }
        if id.contains(where: \.isWhitespace) { return "a model id has no spaces" }
        return nil
    }

    /// The model picked `delta` steps from `value` (default, models…, wrapping), for keys that step through the list.
    /// A custom value steps from where the list ends.
    public static func step(_ value: String?, by delta: Int, in catalog: AgentModelCatalog) -> String? {
        let ids: [String?] = [nil] + catalog.models.map(\.id)
        let current = ids.firstIndex(of: value?.isEmpty == true ? nil : value)
            ?? (delta > 0 ? ids.count - 1 : 0)
        let next = ((current + delta) % ids.count + ids.count) % ids.count
        return ids[next]
    }

    /// The effort picker's entries with `model` chosen: the default (saying which level that is when known), then
    /// the levels. A stored level the model does not list stays offered, so nothing configured disappears. Empty when
    /// the agent takes no effort.
    public static func efforts(_ catalog: AgentModelCatalog, model: String?, current: String? = nil) -> [Option] {
        var levels = catalog.efforts(for: model)
        guard !levels.isEmpty || current?.isEmpty == false else { return [] }
        if let current, !current.isEmpty, !levels.contains(current) { levels.append(current) }
        let fallback = catalog.defaultEffort(for: model).map { "default (\($0))" } ?? "agent's default"
        return [Option(tag: defaultTag, label: fallback)] + levels.map { Option(tag: $0, label: $0) }
    }

    /// The effort kept when the model changes to `model`: kept while that model lists it, else the default (nil).
    public static func effort(_ effort: String?, after model: String?, in catalog: AgentModelCatalog) -> String? {
        guard let effort, catalog.efforts(for: model).contains(effort) else { return nil }
        return effort
    }

    /// The effort `delta` steps from `value` (default, levels…, wrapping); nil when there are none.
    public static func stepEffort(_ value: String?, by delta: Int, in catalog: AgentModelCatalog, model: String?)
        -> String?
    {
        let levels: [String?] = [nil] + catalog.efforts(for: model).map(Optional.some)
        guard levels.count > 1 else { return nil }
        let current = levels.firstIndex(of: value?.isEmpty == true ? nil : value) ?? 0
        return levels[((current + delta) % levels.count + levels.count) % levels.count]
    }

    /// `opus · high`, `default model`: a model and effort in one short line.
    public static func line(model: String?, effort: String?, in catalog: AgentModelCatalog) -> String {
        let name = model.flatMap { id in id.isEmpty ? nil : catalog.model(id)?.label ?? id } ?? "default model"
        guard let effort, !effort.isEmpty else { return name }
        return "\(name) · \(effort)"
    }
}
