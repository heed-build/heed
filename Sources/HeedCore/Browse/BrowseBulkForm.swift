import Foundation

/// The step a bulk action is on: typing what to write, choosing how to close, the confirm step that lists every
/// write, the run, and the report. Pure state over the picked items; the app writes through `BrowseBulk.run` when
/// the form says `.run`, and keeps the report here when it lands.
public struct BrowseBulkForm: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case label, comment }

    public enum Stage: Equatable, Sendable {
        case typing(Kind)
        case closeReason
        case confirm(BrowsePlan)
        /// More than `BrowseBulk.eachCap` sessions: asks first.
        case confirmEach
        case running
        case report(BrowseReport)
    }

    public enum Action: Equatable, Sendable {
        case none, changed, close
        case run(BrowsePlan)
        case startEach
    }

    public private(set) var stage: Stage
    public private(set) var text = ""
    public private(set) var reason = BrowseBulkAction.CloseReason.completed
    /// Why the step cannot go on (an empty label, no login): said on the card.
    public private(set) var problem: String?
    public let items: [BrowseItem]
    public let viewer: String?

    public init(typing kind: Kind, items: [BrowseItem], viewer: String?) {
        stage = .typing(kind)
        self.items = items
        self.viewer = viewer
    }

    public init(closing items: [BrowseItem], viewer: String?) {
        stage = .closeReason
        self.items = items
        self.viewer = viewer
    }

    public init(assigning items: [BrowseItem], viewer: String?) {
        self.items = items
        self.viewer = viewer
        stage = .confirm(BrowseBulk.plan(.assignMe(viewer), items: items))
    }

    public init(each items: [BrowseItem], viewer: String?) {
        self.items = items
        self.viewer = viewer
        stage = .confirmEach
    }

    public mutating func started() { stage = .running }

    public mutating func finished(_ report: BrowseReport) { stage = .report(report) }

    /// The words typed so far, split into label names at commas.
    public var labels: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public mutating func handle(_ stroke: KeyStroke) -> Action {
        switch stage {
        case let .typing(kind):
            if stroke == .escape { return .close }
            if stroke == KeyStroke("CR") {
                let plan = BrowseBulk.plan(kind == .label ? .label(labels) : .comment(text), items: items)
                if let blocked = plan.blocked {
                    problem = blocked
                    return .changed
                }
                problem = nil
                stage = .confirm(plan)
                return .changed
            }
            if stroke == KeyStroke("BS") {
                guard !text.isEmpty else { return .none }
                text.removeLast()
            } else if stroke == KeyStroke("Space") {
                text += " "
            } else if stroke.key.count == 1, stroke.modifiers.isEmpty {
                text += stroke.key
            } else { return .none }
            problem = nil
            return .changed
        case .closeReason:
            switch stroke {
            case .escape: return .close
            case KeyStroke("1"), KeyStroke("c"): reason = .completed
            case KeyStroke("2"), KeyStroke("n"): reason = .notPlanned
            case KeyStroke("j"), KeyStroke("Down"), KeyStroke("k"), KeyStroke("Up"), KeyStroke("Tab"):
                reason = reason == .completed ? .notPlanned : .completed
                return .changed
            case KeyStroke("CR"):
                stage = .confirm(BrowseBulk.plan(.close(reason), items: items))
                return .changed
            default: return .none
            }
            stage = .confirm(BrowseBulk.plan(.close(reason), items: items))
            return .changed
        case let .confirm(plan):
            if stroke == .escape || stroke == KeyStroke("n") { return .close }
            guard stroke == KeyStroke("CR") || stroke == KeyStroke("y") else { return .none }
            if plan.writes.isEmpty {
                problem = "nothing would change"
                return .changed
            }
            stage = .running
            return .run(plan)
        case .confirmEach:
            if stroke == .escape || stroke == KeyStroke("n") { return .close }
            return stroke == KeyStroke("CR") || stroke == KeyStroke("y") ? .startEach : .none
        case .running:
            return .none
        case .report:
            return stroke == .escape || stroke == KeyStroke("CR") ? .close : .none
        }
    }
}
