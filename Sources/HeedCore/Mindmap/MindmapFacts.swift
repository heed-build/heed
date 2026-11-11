import Foundation

/// What a node's work adds up to, counted from the ledger each time it is shown (never kept on the node, so it is
/// never stale): pieces of work, PRs, agent time, the span, repos and agents, and the file touched most.
public struct MindmapFacts: Hashable, Sendable {
    public var pieces = 0
    public var pulls = 0
    public var openPulls = 0
    public var agentTime: TimeInterval = 0
    public var from: Date?
    public var to: Date?
    public var repos: [String] = []
    public var agents: [String] = []
    public var mostTouched: (file: String, times: Int)?

    public static func == (lhs: MindmapFacts, rhs: MindmapFacts) -> Bool {
        lhs.pieces == rhs.pieces && lhs.pulls == rhs.pulls && lhs.openPulls == rhs.openPulls
            && lhs.agentTime == rhs.agentTime && lhs.from == rhs.from && lhs.to == rhs.to && lhs.repos == rhs.repos
            && lhs.agents == rhs.agents && lhs.mostTouched?.file == rhs.mostTouched?.file
            && lhs.mostTouched?.times == rhs.mostTouched?.times
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pieces)
        hasher.combine(pulls)
        hasher.combine(mostTouched?.file)
    }

    public init(of id: String, in tree: MindmapTree, ledger: [String: LedgerEntry]) {
        let entries = tree.entries(under: id).compactMap { ledger[$0] }
        pieces = entries.count
        pulls = entries.reduce(0) { $0 + $1.pulls.count }
        openPulls = entries.filter { $0.outcome == "PR open" }.reduce(0) { $0 + $1.pulls.count }
        agentTime = entries.compactMap(\.agentTime).reduce(0, +)
        from = entries.map(\.startedAt).min()
        to = entries.map(\.updatedAt).max()
        repos = Array(Set(entries.flatMap(\.repos).map { String($0.split(separator: "/").last ?? "") })).sorted()
        agents = Array(Set(entries.map(\.agent).filter { !$0.isEmpty })).sorted()
        var touched: [String: Int] = [:]
        for entry in entries {
            for file in Set(entry.files) {
                touched[file, default: 0] += 1
            }
        }
        if let best = touched.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
           best.value > 1
        {
            mostTouched = (best.key, best.value)
        }
    }
}
