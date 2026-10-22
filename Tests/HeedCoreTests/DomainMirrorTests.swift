import Foundation
@testable import HeedCore
import Testing

/// The window's model (`AppModel`) keeps each part of the domain in a property of its own, and puts them back
/// together as `currentDomain` for everything that reads the domain whole (the sweep, the timeline). A part it does
/// not mirror reaches the store but never what those read: archive refs once did, and the sweep's retention never ran.
/// The app target cannot be linked here, so this reads its source, as `CommandCoverageTests` does.
struct DomainMirrorTests {
    @Test func theAppMirrorsEveryPartOfTheDomain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/HeedApp/Model/AppModel.swift"), encoding: .utf8
        )
        func body(after marker: String, until end: String) throws -> Substring {
            let start = try #require(source.range(of: marker), "\(marker) not found")
            let stop = try #require(source.range(of: end, range: start.upperBound ..< source.endIndex))
            return source[start.upperBound ..< stop.lowerBound]
        }
        let current = try body(after: "var currentDomain: Domain {", until: "\n    }")
        let replace = try body(after: "private func replace(with domain: Domain) {", until: "\n    }\n")
        let commit = try body(after: "func commit(_ changes: [DomainChange]) {", until: "\n    }\n")
        let parts = Mirror(reflecting: Domain()).children.compactMap(\.label)
        #expect(parts.contains("archives"))
        for part in parts {
            #expect(current.contains("\(part): \(part)"), "currentDomain does not pass \(part)")
            #expect(replace.contains("\(part) = "), "replace(with:) does not set \(part)")
            #expect(commit.contains("after.\(part)"), "commit does not update \(part)")
        }
    }
}
