/// `[mindmap]`.
public struct MindmapSettings: Equatable, Sendable {
    /// Finished work is grouped into the Mindmap.
    public var enabled = true
    /// Every placement waits for you (`y` or `m`) instead of standing. Off by default: heed places work, and the
    /// small judgement controls on what it placed are how you correct it.
    public var shadow = false

    public init(enabled: Bool = true, shadow: Bool = false) {
        self.enabled = enabled
        self.shadow = shadow
    }
}
