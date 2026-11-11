/// How placement does, from what you did with it: per route (hunch, local, model), the placements heed asked about,
/// how many you answered (accepted or moved), and how many of those it had right. What decides whether heed may
/// place work on its own (`[mindmap] shadow = false`).
public struct MindmapStats: Hashable, Sendable {
    public struct Route: Hashable, Sendable {
        public var asked = 0
        public var answered = 0
        public var right = 0

        /// The share it had right of those you answered; nil before any.
        public var rate: Double? { answered == 0 ? nil : Double(right) / Double(answered) }
    }

    public var routes: [String: Route] = [:]

    public init(_ trees: [MindmapTree]) {
        for tree in trees {
            for node in tree.nodes.values where node.kind == .work {
                guard let placement = node.placement, placement.state != nil else { continue }
                var route = routes[placement.route] ?? Route()
                route.asked += 1
                if let verdict = placement.verdict {
                    route.answered += 1
                    if verdict == placement.chose { route.right += 1 }
                }
                routes[placement.route] = route
            }
        }
    }

    public var total: Route {
        routes.values.reduce(into: Route()) { sum, route in
            sum.asked += route.asked
            sum.answered += route.answered
            sum.right += route.right
        }
    }
}
