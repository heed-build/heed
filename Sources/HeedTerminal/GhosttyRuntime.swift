import AppKit
import GhosttyKit

/// The one libghostty app instance. Owns the Ghostty config and the runtime callbacks; surfaces are created from it.
///
/// libghostty calls `wakeup` from its own threads when it has work; we answer with a tick on the main thread. Every
/// other callback arrives on the main thread during a tick. Rendering happens on Ghostty's renderer thread, so none
/// of this blocks the UI.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    let app: ghostty_app_t?
    /// The config the app runs on. A change of appearance builds a new one; the old one is left allocated, as
    /// libghostty may still read it from a surface mid-frame, and it is a few kilobytes.
    private var config: ghostty_config_t?
    /// Whether panes are drawn in the dark scheme; set (`setAppearance`) before the first surface opens.
    private nonisolated(unsafe) static var isDark = true
    private nonisolated(unsafe) static var started = false
    private var tickScheduled = false

    /// Called when a surface's process ends and Ghostty asks to close it (`processAlive` false), or the user closed it.
    public var onSurfaceClosed: ((GhosttySurfaceView, _ processAlive: Bool) -> Void)?

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("heed: ghostty_init failed")
        }
        Self.started = true
        let config = Self.buildConfig()
        self.config = config

        var runtime = Self.runtimeConfig()
        app = withUnsafeMutablePointer(to: &runtime) { ghostty_app_new($0, config) }
        if app == nil { NSLog("heed: ghostty_app_new failed") }
    }

    /// The user's own Ghostty config applies, then Heed's pane look on top so panes match the window.
    private static func buildConfig() -> ghostty_config_t? {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        if let overrides = writeOverrides() { ghostty_config_load_file(config, overrides) }
        ghostty_config_finalize(config)
        return config
    }

    /// Pane settings that keep a terminal in step with the design: the pane background, padding and the mono face.
    /// Dark keeps Ghostty's own palette; light brings one that reads on white (GitHub's light terminal colours).
    static func overrides(dark: Bool) -> String {
        let colors = dark ? """
        background = 0c0d0f
        foreground = cfd3d8
        """ : """
        background = ffffff
        foreground = 24292f
        cursor-color = 24292f
        selection-background = cfe0f7
        selection-foreground = 24292f
        palette = 0=#24292f
        palette = 1=#cf222e
        palette = 2=#116329
        palette = 3=#4d2d00
        palette = 4=#0969da
        palette = 5=#8250df
        palette = 6=#1b7c83
        palette = 7=#6e7781
        palette = 8=#57606a
        palette = 9=#a40e26
        palette = 10=#1a7f37
        palette = 11=#633c01
        palette = 12=#218bff
        palette = 13=#a475f9
        palette = 14=#3192aa
        palette = 15=#8c959f
        """
        return colors + """

        font-family = JetBrains Mono
        font-size = 12
        window-padding-x = 14
        window-padding-y = 10
        window-padding-balance = false
        cursor-style = block
        confirm-close-surface = false
        wait-after-command = false
        """
    }

    private static func writeOverrides() -> String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed")
        let file = support.appendingPathComponent("ghostty-panes.conf")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try overrides(dark: isDark).write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            NSLog("heed: could not write \(file.path): \(error)")
            return nil
        }
    }

    /// Switches every pane between the dark and the light look. Before the first pane opens it only records the
    /// choice, which the config then starts from.
    public static func setAppearance(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        guard started else { return }
        shared.reload(dark: dark)
    }

    private func reload(dark: Bool) {
        guard let app else { return }
        let fresh = Self.buildConfig()
        config = fresh
        if let fresh { ghostty_app_update_config(app, fresh) }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// The C callbacks. Built outside the main actor on purpose: closures written in a main-actor context are
    /// main-actor isolated, and Swift checks that at entry, but libghostty calls `wakeup` from its renderer thread.
    private nonisolated static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { userdata, location, state, mimes, count, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // Clipboard reads that need confirmation (OSC 52 from a program) are denied rather than prompted.
                let userdata = RawPointer(userdata), state = RawPointer(state)
                MainActor.assumeIsolated {
                    guard let surface = GhosttyRuntime.surface(userdata.value)?.surface else { return }
                    ghostty_surface_deny_clipboard_request(surface, state.value)
                }
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )
    }

    func tick() {
        tickScheduled = false
        if let app { ghostty_app_tick(app) }
    }

    public func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    // MARK: Callbacks (C function pointers: no captures, may arrive off the main thread)

    private nonisolated static func wakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let runtime = GhosttyRuntime.shared
                guard !runtime.tickScheduled else { return }
                runtime.tickScheduled = true
                runtime.tick()
            }
        }
    }

    nonisolated static func surface(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Serves plain-text reads (paste) from the general pasteboard; other MIME types are reported unavailable.
    private nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int
    ) -> ghostty_clipboard_read_result_e {
        let requested = (0 ..< count).compactMap { mimes?[$0].map { String(cString: $0) } }
        let userdata = RawPointer(userdata), state = RawPointer(state)
        return MainActor.assumeIsolated {
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let surface = surface(userdata.value)?.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            guard let mime = requested.first(where: { $0.hasPrefix("text/plain") }),
                  let text = NSPasteboard.general.string(forType: .string)
            else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            let bytes = Array(text.utf8)
            mime.withCString { mimePointer in
                bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(bytes.count, 1)) { data in
                        var content = ghostty_clipboard_content_s(mime: mimePointer, data: data, len: bytes.count)
                        withUnsafePointer(to: &content) { contentPointer in
                            var complete = ghostty_clipboard_complete_s(
                                contents: contentPointer, contents_len: 1, available: nil, available_len: 0,
                                confirmed: false, remember: false
                            )
                            ghostty_surface_complete_clipboard_request(surface, &complete, state.value)
                        }
                    }
                }
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    /// Copies the plain-text representation of a write (copy, OSC 52) to the general pasteboard.
    private nonisolated static func writeClipboard(
        location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for index in 0 ..< count {
            let item = content[index]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else {
                continue
            }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }

    private nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let userdata = RawPointer(userdata)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = surface(userdata.value) else { return }
                GhosttyRuntime.shared.onSurfaceClosed?(view, processAlive)
            }
        }
    }
}

/// A C pointer handed to the main actor. libghostty's callback pointers are only dereferenced there.
struct RawPointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer?
    init(_ value: UnsafeMutableRawPointer?) { self.value = value }
}
