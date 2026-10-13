import Foundation
@testable import HeedCore
import Testing

struct LegacyDefaultsTests {
    @Test func preferencesComeAcrossOnceWithoutOverwriting() throws {
        let old = "heed.tests.legacy.\(UUID().uuidString)"
        let new = "heed.tests.current.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: new))
        defer {
            defaults.removePersistentDomain(forName: new)
            defaults.removePersistentDomain(forName: old)
        }
        defaults.setPersistentDomain(
            ["inspectorVisible": false, "tutorProgress": Data([1, 2]), "kept": "old"],
            forName: old
        )
        defaults.set("new", forKey: "kept")

        LegacyDefaults.migrate(into: defaults, from: old, running: "build.heed.Heed")
        #expect(defaults.object(forKey: "inspectorVisible") as? Bool == false)
        #expect(defaults.data(forKey: "tutorProgress") == Data([1, 2]))
        #expect(defaults.string(forKey: "kept") == "new") // already set under the new id: left alone

        // Once only: later changes to the old domain do not come across again.
        defaults.setPersistentDomain(["late": true], forName: old)
        LegacyDefaults.migrate(into: defaults, from: old, running: "build.heed.Heed")
        #expect(defaults.object(forKey: "late") == nil)
    }

    @Test func theOldAppItselfDoesNotMigrate() throws {
        let name = "heed.tests.same.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        LegacyDefaults.migrate(into: defaults, from: LegacyDefaults.oldDomain, running: LegacyDefaults.oldDomain)
        #expect(!defaults.bool(forKey: LegacyDefaults.doneKey))
    }
}
