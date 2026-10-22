import Foundation

/// Where chats live and how their scratch folders are named.
public enum Chats {
    /// Scratch folders on this Mac: `~/Library/Application Support/Heed/chats`. Tests point it elsewhere.
    public nonisolated(unsafe) static var localRoot: String = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Heed/chats").path

    /// Scratch folders on a host: under `~/.heed`, the only place heed writes there.
    public static let hostRoot = "~/.heed/chats"

    /// The folder scratch chats go under, here or on a host.
    public static func root(on location: Location) -> String {
        location.isLocal ? localRoot : hostRoot
    }

    /// Whether `path` is a scratch folder heed made: one folder directly under `root`, nothing else. Heed removes only
    /// those.
    public static func isScratch(_ path: String, root: String = localRoot) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard !base.isEmpty, path.hasPrefix(base + "/") else { return false }
        let name = path.dropFirst(base.count + 1)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// `2026-10-21-cron-line-weekdays`: the day it started, then the prompt's first meaningful words.
    public static func scratchName(for prompt: String, on date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let words = StartWork.slugWords(prompt).prefix(4).joined(separator: "-")
        return words.isEmpty ? "\(day)-chat" : "\(day)-\(String(words.prefix(48)))"
    }

    /// A folder name not taken yet under `root`: `name`, else `name-2`, `name-3`… `exists` answers for a path.
    public static func unique(_ name: String, in root: String, exists: (String) -> Bool) -> String {
        var candidate = name
        var number = 2
        while exists("\(root)/\(candidate)") {
            candidate = "\(name)-\(number)"
            number += 1
        }
        return "\(root)/\(candidate)"
    }
}

/// What Start work makes for a chat: a scratch folder (named `name` under the chats root) or a folder you picked
/// (`name` is its path), here or on a host.
public struct ChatPlan: Hashable, Sendable {
    public var kind: ChatFolder.Kind
    /// The scratch folder's name, or the picked folder's path.
    public var name: String
    public var location: Location

    public init(kind: ChatFolder.Kind, name: String, location: Location = .local) {
        self.kind = kind
        self.name = name
        self.location = location
    }

    /// Where it runs, before a scratch name is made unique.
    public var path: String {
        kind == .scratch ? "\(Chats.root(on: location))/\(name)" : Paths.expandOn(location, name)
    }
}

public extension Paths {
    /// `/Users/me/Documents/x` as `~/Documents/x`, measured from `home` (the fake world's in screenshots).
    static func tilde(_ path: String, home: String = Paths.home) -> String {
        let (root, relative) = split(path, roots: [], home: home)
        return root + relative
    }

    /// `~/x` expanded here; left for the host's shell there (its home is not ours).
    static func expandOn(_ location: Location, _ path: String) -> String {
        location.isLocal ? expand(path) : path
    }
}
