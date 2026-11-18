import Foundation

/// `[browse]`: how far back a Browse search reaches, and when an org has too many repos to browse at once.
public struct BrowseSettings: Equatable, Sendable {
    public static let defaultMaxAgeDays = 90
    public var maxAgeDays: Int
    /// An org with more repos than this is offered a view of its own before everything (0 never asks).
    public var manyRepos: Int

    public init(maxAgeDays: Int = BrowseSettings.defaultMaxAgeDays, manyRepos: Int = BrowseGuidance.defaultThreshold) {
        self.maxAgeDays = maxAgeDays
        self.manyRepos = manyRepos
    }
}
