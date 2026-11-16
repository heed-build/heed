import Foundation

/// Make it a goal, from the popover to the goal: what it would be, and the handoff asked of the session's agent while
/// the popover waits. There is no handoff without a promotion, and one for another session is refused.
public struct PromotionFlow: Equatable, Sendable {
    public private(set) var promotion: GoalPromotion
    public private(set) var handoff: HandoffAsk?

    public init(_ promotion: GoalPromotion) {
        self.promotion = promotion
    }

    public var session: String { promotion.session }

    /// The promotion edited (what it found, its title): the same session, so the ask stays.
    public mutating func edit(_ change: (inout GoalPromotion) -> Void) {
        let session = promotion.session
        change(&promotion)
        if promotion.session != session { handoff = nil }
    }

    /// Asks the session's agent for a handoff; false when the ask is for another session.
    @discardableResult
    public mutating func ask(_ ask: HandoffAsk) -> Bool {
        guard ask.session == promotion.session else { return false }
        handoff = ask
        return true
    }

    /// Applies `change` to the ask `id`; false (and nothing changes) when that ask is no longer the one waiting, as
    /// for a delivery that ends after the popover closed and another ask began.
    @discardableResult
    public mutating func updateAsk(_ id: UUID, _ change: (inout HandoffAsk) -> Void) -> Bool {
        guard var ask = handoff, ask.id == id else { return false }
        change(&ask)
        handoff = ask
        return true
    }
}
