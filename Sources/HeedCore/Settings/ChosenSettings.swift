import Foundation

/// The settings you decided on in the setup wizard, Keep default included: they are no longer gaps, whatever their
/// value. Separate from modified (a value that differs from heed's default) and kept with heed's other UI state in
/// its preferences, never in config.toml.
public struct ChosenSettings: Hashable, Sendable, Codable {
    /// Catalog entry ids (`SettingsEntry.id`).
    public private(set) var ids: Set<String>

    public init(_ ids: Set<String> = []) {
        self.ids = ids
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func choose(_ id: String) { ids.insert(id) }

    public mutating func forget(_ id: String) { ids.remove(id) }

    /// Written as a sorted list, so the same choices always save the same bytes.
    public init(from decoder: Decoder) throws {
        ids = try Set(decoder.singleValueContainer().decode([String].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ids.sorted())
    }

    /// The preferences key.
    public static let defaultsKey = "settingsChosen"

    /// What was saved; none when nothing was, or it cannot be read.
    public static func load(from defaults: UserDefaults = .standard) -> ChosenSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let chosen = try? JSONDecoder().decode(ChosenSettings.self, from: data)
        else { return ChosenSettings() }
        return chosen
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
