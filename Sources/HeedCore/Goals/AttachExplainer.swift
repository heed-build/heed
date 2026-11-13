import Foundation

/// Whether Goals › Unassigned shows how heed decides (signals, the model only when unsure, acting by confidence). It
/// shows on its own only while nothing waits for you there, no ask and no suggested goal, so the explainer never
/// pushes what needs you down the pane; `goal.unassigned.how` shows or hides it either way.
public struct AttachExplainer: Hashable, Sendable {
    /// What you chose with `goal.unassigned.how`; nil: as the pane is.
    public var chosen: Bool?

    public init(chosen: Bool? = nil) {
        self.chosen = chosen
    }

    /// Shown, with `waiting` asks and suggested goals in the pane.
    public func shows(waiting: Int) -> Bool { chosen ?? (waiting == 0) }

    /// `goal.unassigned.how`: the other way round from how it shows now. Returns whether it shows after.
    public mutating func toggle(waiting: Int) -> Bool {
        let shown = !shows(waiting: waiting)
        chosen = shown
        return shown
    }
}
