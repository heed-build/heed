#if HEED_GHOSTTY
    import AppKit
    import HeedCore
    import HeedTerminal

    /// Makes libghostty panes. Every pane gets the session's hook environment and the bundled `heed` on its PATH.
    @MainActor
    enum GhosttyTerminalFactory {
        /// `command` replaces the login shell (zmx attaching to the pane's session); nil runs your shell as usual.
        static func makeView(pane: PaneSpec, environment: [String: String], command: String? = nil) -> NSView {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: pane.directory, isDirectory: &isDirectory) && isDirectory
                .boolValue
            var env = environment
            if let helper = Helper.path {
                let helpers = (helper as NSString).deletingLastPathComponent
                env["PATH"] = "\(helpers):\(environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
                env[HeedEnvironment.binary] = helper
            }
            // A pane's command is typed into its shell only when its worktree exists, so a fixture or a cleaned-up
            // worktree opens a plain shell instead of starting an agent somewhere unexpected.
            let launch = TerminalLaunch(
                directory: exists ? pane.directory : NSHomeDirectory(),
                command: command,
                initialInput: exists ? pane.command.map { "\($0)\n" } : nil,
                environment: env
            )
            return GhosttySurfaceView(launch: launch)
        }
    }
#endif
