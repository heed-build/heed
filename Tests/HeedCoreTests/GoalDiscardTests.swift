import Foundation
@testable import HeedCore
import Testing

struct GoalDiscardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ops() throws -> (GoalOps, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-discard-\(UUID().uuidString)")
        let ops = try GoalOps(
            path: dir.appendingPathComponent("goals.sqlite").path,
            files: GoalFiles(root: dir.appendingPathComponent("goals"))
        )
        return (ops, dir)
    }

    @Test func nothingAttachedDeletes() {
        #expect(GoalDiscard().outcome == .delete)
        #expect(GoalDiscard().attached.isEmpty)
    }

    @Test func anythingAttachedArchives() {
        #expect(GoalDiscard(links: 1).outcome == .archive)
        #expect(GoalDiscard(swarms: 1).outcome == .archive)
        #expect(GoalDiscard(wentGo: true).outcome == .archive)
        #expect(GoalDiscard(mirrored: true).outcome == .archive)
        #expect(GoalDiscard(links: 2, wentGo: true).attached == "2 sessions, chats or PRs, a started plan")
    }

    @Test func deleteLeavesNoOrphans() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = try await ops.create(title: "Keep me", statement: "stays", now: now)
        let goal = try await ops.create(title: "Throw away", statement: "gone", now: now)
        try await ops.addItem(goal: goal.id, title: "doomed item", source: .you, now: now)
        try await ops.addItem(goal: keep.id, title: "kept item", source: .you, now: now)
        try await ops.save(wizard: GoalWizard(goal: goal.id, at: now))
        try await ops.save(wizard: GoalWizard(goal: keep.id, at: now))
        #expect(FileManager.default.fileExists(atPath: ops.files.doc(goal.id).path))

        #expect(try await ops.discard(goal: goal.id, now: now) == .delete)

        let snapshot = try await ops.snapshot()
        #expect(snapshot.goals.map(\.id) == [keep.id])
        #expect(snapshot.items.map(\.goal) == [keep.id])
        #expect(try await ops.wizards().keys.sorted() == [keep.id])
        #expect(try await ops.versions(of: goal.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ops.files.folder(goal.id).path))
        #expect(FileManager.default.fileExists(atPath: ops.files.doc(keep.id).path))
    }

    @Test func attachedGoalIsArchivedWithEverythingKept() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "Has a session", statement: "x", now: now)
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "s1", at: now))
        try await ops.save(wizard: GoalWizard(goal: goal.id, at: now))

        #expect(try await ops.discard(goal: goal.id, now: now) == .archive)

        let snapshot = try await ops.snapshot()
        #expect(snapshot.goal(goal.id)?.status == .archived)
        #expect(snapshot.links.count == 1)
        #expect(try await ops.wizards()[goal.id] != nil)
        #expect(FileManager.default.fileExists(atPath: ops.files.doc(goal.id).path))
    }

    @Test func aWizardThatWentGoIsArchived() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "Started", statement: "x", now: now)
        var wizard = GoalWizard(goal: goal.id, at: now)
        wizard.swarm = "\(goal.id)/swarm-1"
        try await ops.save(wizard: wizard)
        #expect(try await ops.discard(goal: goal.id, now: now) == .archive)
        #expect(try await ops.snapshot().goal(goal.id)?.status == .archived)
    }

    @Test func aGoalWithASwarmIsArchivedAndNeverDeletedByTheStore() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "Swarmed", statement: "x", now: now)
        try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(repos: []), now: now)
        #expect(try await ops.discard(goal: goal.id, now: now) == .archive)
        #expect(try await ops.snapshot().goal(goal.id) != nil)
    }

    @Test func unknownGoalThrows() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: GoalOpError.unknownGoal("nope")) { try await ops.discard(goal: "nope", now: now) }
    }
}
