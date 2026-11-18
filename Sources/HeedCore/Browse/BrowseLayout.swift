import Foundation

/// How wide Browse draws: three layouts, chosen from the width of its own area (not the window's), so a view in a
/// split behaves as a narrow window does.
public enum BrowseLayout: Equatable, Sendable {
    /// Rail, list and reader side by side.
    case wide
    /// An icon rail and the list; the reader is pushed over them, full width.
    case half
    /// No rail (the scope chip opens it as a sheet), two-line rows, the reader pushed, bulk as a bottom sheet.
    case third

    /// From this width up: rail, list and reader. Matches the Attention split's neighbour (1000) and the window's
    /// inspector (1180) from above: the reader needs about 440 points beside a 560 point list.
    public static let wideMinimum: Double = 1100
    /// From this width up: the icon rail. Below it the rail goes.
    public static let halfMinimum: Double = 640
    /// The icon rail's width, in points.
    public static let iconRail: Double = 52
    /// The full rail's width, in points.
    public static let fullRail: Double = 224

    public static func mode(width: Double) -> BrowseLayout {
        if width >= wideMinimum { return .wide }
        if width >= halfMinimum { return .half }
        return .third
    }

    /// Whether the reader shares the screen with the list (it is pushed over it otherwise).
    public var showsReaderBeside: Bool { self == .wide }

    /// Whether a rail is drawn at all.
    public var hasRail: Bool { self != .third }
}
