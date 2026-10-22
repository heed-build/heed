#if HEED_GHOSTTY
    import AppKit
    import HeedCore
    import HeedTerminal

    /// Makes libghostty panes. Every pane gets the session's hook environment and the bundled `heed` on its PATH.
    @MainActor
    enum GhosttyTerminalFactory {
        /// `command` replaces the login shell: the pane's own command (`PaneLaunch`), zmx attaching to the pane's
        /// session, or ssh to a host; nil runs your shell as usual.
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
            let launch = TerminalLaunch(
                directory: exists ? pane.directory : NSHomeDirectory(), command: command, environment: env
            )
            return GhosttySurfaceView(launch: launch)
        }
    }
#endif
