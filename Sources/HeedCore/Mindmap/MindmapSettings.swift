/// `[mindmap]`.
public struct MindmapSettings: Equatable, Sendable {
    /// Finished work is grouped into the Mindmap.
    public var enabled = true
    /// Every placement waits for you, so how often heed is right can be measured before it places work alone.
    public var shadow = true

    public init(enabled: Bool = true, shadow: Bool = true) {
        self.enabled = enabled
        self.shadow = shadow
    }
}
