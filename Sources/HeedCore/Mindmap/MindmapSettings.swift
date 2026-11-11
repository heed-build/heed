/// `[mindmap]`.
public struct MindmapSettings: Equatable, Sendable {
    /// Finished work is grouped into the Mindmap. Off by default until the view ships.
    public var enabled = false
    /// Every placement waits for you, so how often heed is right can be measured before it places work alone.
    public var shadow = true

    public init(enabled: Bool = false, shadow: Bool = true) {
        self.enabled = enabled
        self.shadow = shadow
    }
}
