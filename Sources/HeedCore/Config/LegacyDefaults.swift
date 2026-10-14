import Foundation

/// Heed's bundle id was `net.nullean.heed` until 0.1.0. macOS keeps preferences per bundle id, so on the first launch
/// under `build.heed.app` the old ones (panel state, tutor progress, window frames) are copied over, once, without
/// overwriting anything already set.
public enum LegacyDefaults {
    public static let oldDomain = "net.nullean.heed"
    static let doneKey = "migratedFromNetNulleanHeed"

    public static func migrate(
        into defaults: UserDefaults = .standard, from oldDomain: String = oldDomain,
        running bundleID: String? = Bundle.main.bundleIdentifier
    ) {
        guard bundleID != oldDomain, !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
