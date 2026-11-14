import Foundation
@testable import HeedCore
import Testing

/// Add a persona against real Claude Code on haiku: one proposal call over the fake world's digest of acme's three
/// repos, through heed's model calls. One call. What it answered is kept in the capture folder.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LivePersonaTests {
    @Test(.timeLimit(.minutes(3))) func proposesPeopleTheReposServe() async throws {
        let runner = LLMRunner(agents: AgentProfile.builtIn.filter { $0.name == "claude" })
        let calls = PersonaCalls { request in
            let response = try await runner.run(request)
            Live.keep("personas-\(request.operation ?? "call").out", response.text)
            return response
        }
        let now = Date()
        let library = PersonaLibrary(files: [:]).personas
        let (proposals, cost) = try await calls.propose(
            digest: PersonaLibraryFixtures.digest(now: now), library: library, now: now
        )
        #expect(!proposals.isEmpty)
        #expect(proposals.count <= PersonaProposals.limit)
        #expect(proposals.allSatisfy { !$0.persona.evidence.isEmpty })
        #expect(proposals.allSatisfy { $0.persona.scope.applies(to: PersonaLibraryFixtures.repos) })
        #expect(proposals.map(\.strength) == proposals.map(\.strength).sorted(by: >))
        #expect(cost.model?.contains("haiku") == true)
    }
}
