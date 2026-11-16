import Foundation
import Synchronization

/// What heed takes from the machine it runs on: the home folder, where scratch chats go, the time it shows, and new
/// session ids. The real machine's, except where something narrower says otherwise:
///
/// - The app's screenshot and tutor-check runs put the whole process in the fake world, once, before they draw
///   (`pinProcess`): their drawing runs from the run loop, outside any task, so it has to be the process's.
/// - Tests override it for one task and the tasks it starts (`with`), so a test running beside it in parallel never
///   sees the override. Tests never call `pinProcess` (`.swiftlint.yml` rejects it there).
public struct HeedContext: Sendable {
    /// The home folder paths are shown relative to (`Paths.split`, `Paths.tilde`).
    public var home: String
    /// Scratch chats on this Mac (`Chats.localRoot`).
    public var chatsRoot: String
    /// The time the UI shows (`Clock.now`): nil for the real time.
    public var pinnedNow: Date?
    /// Makes a new session's id (`StartWorkForm`).
    public var newSessionID: @Sendable () -> String

    public init(
        home: String, chatsRoot: String, pinnedNow: Date? = nil,
        newSessionID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.home = home
        self.chatsRoot = chatsRoot
        self.pinnedNow = pinnedNow
        self.newSessionID = newSessionID
    }

    /// This Mac: `~`, `~/Library/Application Support/Heed/chats`, the real time, random ids.
    public static let machine = HeedContext(
        home: NSHomeDirectory(),
        chatsRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/chats").path
    )

    private static let process = Mutex(machine)
    @TaskLocal private static var scoped: HeedContext?

    /// The environment in effect: the task's own, else the process's.
    public static var current: HeedContext { scoped ?? process.withLock { $0 } }

    /// Puts the whole process in another environment, from now on. Only for the app's screenshot and tutor-check
    /// runs, at their start, before anything is drawn.
    public static func pinProcess(_ change: (inout HeedContext) -> Void) {
        process.withLock { change(&$0) }
    }

    /// Runs `operation` with the environment changed for this task and the tasks it starts, and nowhere else.
    public static func with<T>(
        _ change: (inout HeedContext) -> Void, isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        var context = current
        change(&context)
        return try await $scoped.withValue(context, operation: operation, isolation: isolation)
    }

    /// `with`, for synchronous work.
    public static func with<T>(_ change: (inout HeedContext) -> Void, operation: () throws -> T) rethrows -> T {
        var context = current
        change(&context)
        return try $scoped.withValue(context, operation: operation)
    }
}
