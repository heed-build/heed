import Foundation

public extension Fixtures {
    /// History's Mindmap in the fake world, one tree per instance, placed from `Fixtures.ledger`. Every name and
    /// sentence is invented.
    static var mindmap: [String: [MindNode]] {
        let now = Clock.now
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let entries = Dictionary(ledger.map { ($0.id, $0) }) { first, _ in first }
        func work(_ id: String, in parent: String, suggested: Bool = false) -> MindNode? {
            guard let entry = entries[id] else { return nil }
            var node = MindNode.work(entry, parent: parent, now: entry.updatedAt)
            node.suggested = suggested
            node.placement = .init(confidence: suggested ? 0.62 : 0.91, route: "hunch")
            return node
        }
        var acme = MindmapTree([
            MindNode(
                id: "area:docs",
                kind: .area,
                title: "Docs",
                synopsis: "The docs builder and the website it "
                    + "publishes: navigation, links and redirects.",
                createdAt: ago(40)
            ),
            MindNode(
                id: "campaign:docs-nav", parent: "area:docs", kind: .campaign, title: "Make the docs nav trustworthy",
                intent: "Readers find a page where the folder's index file says it is.", stage: .landing,
                synopsis: "The flat model was tried and dropped as too slow; the tree stayed, and its order now "
                    + "follows each folder's index file, title order without one.", createdAt: ago(34)
            ),
            MindNode(
                id: "campaign:links", parent: "area:docs", kind: .campaign, title: "Stop broken links shipping",
                intent: "A redirect or anchor that points nowhere fails the build.", stage: .building,
                synopsis: "Redirect targets are checked against real headings; moved pages on the website are next.",
                createdAt: ago(7)
            ),
        ])
        for node in [
            work("h-docs-nav-spike-v1", in: "campaign:docs-nav"), work("h-fix-toc-ordering", in: "campaign:docs-nav"),
            work("s1", in: "campaign:links", suggested: true).map { node in
                var node = node
                node.open.append(.init(kind: .threads, text: "docs-toolkit#2841: 2 review threads open", source: "s1"))
                return node
            },
        ].compactMap(\.self) {
            acme.upsert(node)
        }
        var globex = MindmapTree([
            MindNode(
                id: "campaign:flowcharts", kind: .campaign, title: "Flowcharts that read cleanly",
                intent: "Long labels wrap without breaking the layout.", stage: .stalled,
                synopsis: "Wrapping before measuring broke edge routing; the work stopped there.", createdAt: ago(30)
            ),
        ])
        if let node = work("h-flowchart-label-wrapping", in: "campaign:flowcharts") { globex.upsert(node) }
        var initech = MindmapTree([
            MindNode(
                id: "campaign:upkeep", kind: .campaign, title: "Upkeep", stage: .done,
                synopsis: "Spec tests follow upstream releases.", createdAt: ago(50)
            ),
        ])
        if let node = work("h-bump-spec-tests-0-17", in: "campaign:upkeep") { initech.upsert(node) }
        return [
            "acme": Array(acme.nodes.values), "globex": Array(globex.nodes.values),
            "initech": Array(initech.nodes.values),
        ]
    }
}
