import Foundation

/// What ⎋ does in Browse, from the inside out. One order for every layout, so no layer is skipped: help or a reader on
/// top is closed first, a pushed reader goes back before it touches a run or the picks, and a run is ended only by its
/// own close.
public enum BrowseEscape {
    public struct State: Equatable, Sendable {
        /// An overlay (help, ...) is open.
        public var overlay = false
        /// A pull request or issue reader is open over the view.
        public var reader = false
        /// A bulk step is on.
        public var bulk = false
        /// Half and third widths: Browse's reader is pushed over the list.
        public var pushedReader = false
        public var picks = false
        /// Third width: the scope sheet is open.
        public var jumpSheet = false
        public init() {}
    }

    public enum Step: Equatable, Sendable {
        /// An overlay or a reader: the topmost closes (`closeTopmost`).
        case closeTopmost
        case cancelBulk
        /// The pushed reader goes back to the list.
        case backFromReader
        case clearPicks
        case closeJumpSheet
        /// The run on the item closes (kept, when it holds work), or a refusal's card, or else `overlay.close`.
        case closeRun
    }

    public static func next(state: State) -> Step {
        if state.overlay || state.reader { return .closeTopmost }
        if state.bulk { return .cancelBulk }
        if state.pushedReader { return .backFromReader }
        if state.picks { return .clearPicks }
        if state.jumpSheet { return .closeJumpSheet }
        return .closeRun
    }
}
