#if HEED_GHOSTTY
    import AppKit
    import HeedCore
    import HeedTerminal

    /// Makes libghostty panes. Every pane gets the session's hook environment and the bundled `heed` on its PATH.
    @MainActor
    enum GhosttyTerminalFactory {
        static func makeView(pane: PaneSpec, environment: [String: String]) -> NSView {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: pane.directory, isDirectory: &isDirectory) && isDirectory
                .boolValue
            var env = environment
            if let helpers = Bundle.main.url(forAuxiliaryExecutable: "heed")?.deletingLastPathComponent().path
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path as String?
            {
                env["PATH"] = "\(helpers):\(environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
                env[HeedEnvironment.binary] = "\(helpers)/heed"
            }
            // A pane's command is typed into its shell only when its worktree exists, so a fixture or a cleaned-up
            // worktree opens a plain shell instead of starting an agent somewhere unexpected.
            let launch = TerminalLaunch(
                directory: exists ? pane.directory : NSHomeDirectory(),
                initialInput: exists ? pane.command.map { "\($0)\n" } : nil,
                environment: env
            )
            return GhosttySurfaceView(launch: launch)
        }
    }
#endif
