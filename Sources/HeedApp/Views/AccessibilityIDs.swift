import SwiftUI

extension View {
    /// A stable accessibility identifier, for what drives Heed from outside (reel's `Wait #id` and `Click #id`, UI
    /// tests). The view stays a container, so its text and controls remain reachable and read as they did.
    func axID(_ id: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}
