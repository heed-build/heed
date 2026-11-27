import Foundation

/// The environment a Browse run's agent and everything it starts inherit.
public enum BrowseRunEnvironment {
    public static func make(
        _ parent: [String: String], agent: String, folder: String, trusted: Bool, path: String?
    ) -> [String: String] {
        parent
    }
}
