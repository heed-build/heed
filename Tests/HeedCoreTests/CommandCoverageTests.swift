import Foundation
@testable import HeedCore
import Testing

/// Every command is a promise: `:` completes it, `?` lists it, config can bind it. The app's `perform` must answer
/// each one, or it falls through to "not built yet" (as `gU` and VISUAL pin once did). The app target cannot be
/// linked here, so this reads its source.
struct CommandCoverageTests {
    @Test func theAppHandlesEveryCommand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/HeedApp/Model/AppModel.swift"), encoding: .utf8
        )
        let start = try #require(source.range(of: "func perform(_ command: CommandInvocation) {"))
        let end = try #require(source.range(of: "not built yet", range: start.upperBound ..< source.endIndex))
        let perform = source[start.upperBound ..< end.lowerBound]
        for spec in Commands.all {
            #expect(perform.contains("\"\(spec.name)\""), "\(spec.name) is not handled by AppModel.perform")
        }
    }

    @Test func aliasesNameRealCommands() {
        for line in ["start", "agent codex", "pr 12", "track https://x", "import ~/x", "back", "skip", "help", "q"] {
            let name = CommandAliases.resolve(line).name
            #expect(Commands.spec(name) != nil, "\(line) → \(name)")
        }
        #expect(CommandAliases.resolve("agent codex").arguments == ["--agent", "codex"])
    }
}
