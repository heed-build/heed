import Foundation
import HeedCore

/// `HEED_SEED_WORLD=1`: writes the fake world's ledger and the `acme` Mindmap (campaigns, decisions, work placed in
/// them,
/// as `Fixtures` draws them, every name invented) into this Heed's own stores, dated from now, and quits. Used by
/// `docs/reels/demo/launch.sh` so a film starts with a believable history and no model call writes it. Run against a
/// throwaway home (`CFFIXED_USER_HOME`), never a real one.
enum WorldSeed {
    static var requested: Bool { ProcessInfo.processInfo.environment["HEED_SEED_WORLD"] != nil }

    static let instance = "acme"

    static func run() async -> Int32 {
        let nodes = Fixtures.mindmap[instance] ?? []
        let wanted = Set(nodes.compactMap(\.entry))
        let entries = Fixtures.ledger.filter { wanted.contains($0.id) }
        guard let log = await EventLog.open(at: EventLog.defaultFile()) else {
            FileHandle.standardError.write(Data("seed: cannot open the event log\n".utf8))
            return 1
        }
        await log.write(entries.map { .ledger($0) })
        guard let store = await MindmapStore.open(instance, in: MindmapStore.defaultDirectory()) else {
            FileHandle.standardError.write(Data("seed: cannot open the Mindmap\n".utf8))
            return 1
        }
        do { try await store.upsert(nodes) } catch {
            FileHandle.standardError.write(Data("seed: \(error)\n".utf8))
            return 1
        }
        print("seeded \(entries.count) ledger entries and \(nodes.count) Mindmap nodes for \(instance)")
        return 0
    }
}
