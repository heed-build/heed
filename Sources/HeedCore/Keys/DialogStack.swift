import Foundation

/// The dialogs open over the window, oldest first, at most one of each kind. The app keeps one stack instead of a
/// variable per dialog, so whether any dialog is open (and so whether a click may reach a list or a terminal) is
/// one question with one answer. Which open dialog takes a key is the app's order of kinds, not the stack's.
public struct DialogStack<Kind: Hashable & Sendable, Dialog> {
    public private(set) var open: [(kind: Kind, dialog: Dialog)] = []

    public init() {}

    public var isEmpty: Bool { open.isEmpty }

    /// The dialog of `kind`, while it is open.
    public subscript(kind: Kind) -> Dialog? {
        open.first { $0.kind == kind }?.dialog
    }

    public func contains(_ kind: Kind) -> Bool {
        open.contains { $0.kind == kind }
    }

    /// Opens `dialog` as `kind` (on top), or changes the one of that kind where it is; nil closes it. Closing a kind
    /// that is not open does nothing, and never closes another.
    public mutating func set(_ kind: Kind, _ dialog: Dialog?) {
        let index = open.firstIndex { $0.kind == kind }
        switch (index, dialog) {
        case let (index?, dialog?): open[index].dialog = dialog
        case let (nil, dialog?): open.append((kind, dialog))
        case let (index?, nil): open.remove(at: index)
        case (nil, nil): break
        }
    }

    /// The kinds open, oldest first.
    public var kinds: [Kind] { open.map(\.kind) }
}

extension DialogStack: Sendable where Dialog: Sendable {}
