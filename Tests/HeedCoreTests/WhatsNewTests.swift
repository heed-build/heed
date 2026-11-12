import Foundation
@testable import HeedCore
import Testing

/// What's new: versions, what a range holds, and that every Show me goes somewhere real.
struct WhatsNewTests {
    @Test func versionsParseAndCompare() throws {
        #expect(HeedVersion("0.37.0") == HeedVersion(0, 37, 0))
        #expect(HeedVersion("v0.37.1") == HeedVersion(0, 37, 1))
        #expect(HeedVersion("0.37") == HeedVersion(0, 37, 0))
        #expect(HeedVersion("0.1.0-dev") == nil)
        #expect(HeedVersion("dev") == nil)
        #expect(HeedVersion("1.2.3.4") == nil)
        #expect(try #require(HeedVersion("0.9.0")) < #require(HeedVersion("0.10.0")))
        #expect(try #require(HeedVersion("0.37.1")) > #require(HeedVersion("0.37.0")))
        #expect(HeedVersion(0, 37).short == "0.37")
        #expect(HeedVersion(0, 37, 2).short == "0.37.2")
    }

    @Test func itemsAreWhatShippedAfterLastSeenUpToNow() {
        let content = WhatsNew.items(since: "0.35.0", upTo: "0.37.0")
        #expect(content.version == HeedVersion(0, 37))
        #expect(content.since == HeedVersion(0, 35))
        #expect(content.features.contains { $0.version == HeedVersion(0, 36) })
        #expect(content.features.contains { $0.version == HeedVersion(0, 37) })
        // Newest first.
        #expect(content.features.first?.version == HeedVersion(0, 37))
        #expect(zip(content.features, content.features.dropFirst()).allSatisfy { $0.version >= $1.version })
        // New settings come from the catalog's since: the standup ones shipped in 0.36, the nudges in 0.37.
        let ids = content.settings.map(\.id)
        #expect(ids.contains("standup.enabled"))
        #expect(ids.contains("nudges.gaps"))
        #expect(!ids.contains("notifications.enabled"))
        #expect(ids.firstIndex(of: "nudges.gaps")! < ids.firstIndex(of: "standup.enabled")!)

        let one = WhatsNew.items(since: "0.36.0", upTo: "0.37.0")
        #expect(one.features.allSatisfy { $0.version == HeedVersion(0, 37) })
        #expect(!one.settings.map(\.id).contains("standup.enabled"))
        #expect(!one.isEmpty)
        // Nothing ahead of the version running.
        let old = WhatsNew.items(since: "0.35.0", upTo: "0.36.0")
        #expect(old.features.allSatisfy { $0.version == HeedVersion(0, 36) })
        #expect(!old.settings.map(\.id).contains("nudges.gaps"))
    }

    @Test func withoutLastSeenItIsThisMinorVersionsOwn() {
        let content = WhatsNew.items(since: nil, upTo: "0.37.1")
        #expect(content.since == nil)
        #expect(!content.features.isEmpty)
        #expect(content.features.allSatisfy { $0.version.minor == 37 })
    }

    @Test func aDevBuildShowsTheNewestFeatures() {
        #expect(WhatsNew.items(since: nil, upTo: "0.1.0-dev").version == WhatsNew.newest)
    }

    @Test func everyFeatureHasAVersionAndAShowMeThatExists() {
        for feature in WhatsNew.features {
            #expect(feature.version > HeedVersion(0, 0), "\(feature.title): no version")
            #expect(!feature.title.isEmpty && !feature.line.isEmpty)
            switch feature.showMe {
            case let .command(line):
                let name = CommandInvocation(parsing: line).name
                #expect(Commands.spec(name) != nil, "\(feature.title): no command \(name)")
            case let .setting(id):
                #expect(SettingsCatalog.entry(id) != nil, "\(feature.title): no setting \(id)")
            case nil:
                break
            }
        }
        #expect(Commands.spec(WhatsNew.configureCommand) != nil)
    }

    /// The next version gets the settings redesign: release-drafter bumps the minor for every feature/ branch.
    @Test func theNewestVersionHasTheSettingsRedesign() {
        let newest = WhatsNew.items(since: nil, upTo: WhatsNew.newest.description).features.map(\.title)
        #expect(newest.contains("Settings as a tree"))
        #expect(newest.contains("Search every setting"))
        #expect(newest.contains("Configure…"))
    }
}
