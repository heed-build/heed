import Foundation
import Testing

/// Folders a test makes under the temporary directory, removed once the test is done. A suite or test with the
/// `.scratch` trait gets a root of its own for each run of a test; `Scratch.folder(_:)` makes a folder under it, so a
/// helper that hands out folders leaves nothing behind however many it makes.
enum Scratch {
    @TaskLocal static var root: URL?

    /// A new, empty folder named `<prefix>-<uuid>` under the running test's root.
    static func folder(_ prefix: String) throws -> URL {
        guard let root else { throw Unscoped() }
        let url = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Outside a `.scratch` test nothing would remove the folder, so there is none.
    struct Unscoped: Error, CustomStringConvertible {
        var description: String { "Scratch.folder outside a test or suite with the .scratch trait" }
    }
}

struct ScratchTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for _: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // A suite passes through: each of its tests gets its own root.
        guard testCase != nil else { return try await function() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heed-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Scratch.$root.withValue(root) { try await function() }
    }
}

extension Trait where Self == ScratchTrait {
    /// The test's folders (`Scratch.folder`) are removed when it is done.
    static var scratch: Self { Self() }
}
