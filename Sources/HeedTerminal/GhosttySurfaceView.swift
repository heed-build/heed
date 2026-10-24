import AppKit
import GhosttyKit

/// What a terminal surface starts with.
public struct TerminalLaunch: Sendable {
    public var directory: String
    /// Command to run instead of the login shell, in sh words (Ghostty runs it with `bash -c 'exec -l …'`). Nil runs
    /// the user's shell.
    public var command: String?
    public var environment: [String: String]

    public init(directory: String, command: String? = nil, environment: [String: String]) {
        self.directory = directory
        self.command = command
        self.environment = environment
    }
}

/// An AppKit view hosting one libghostty surface: its pty, renderer and input. Keys reach it only when the key router
/// lets them through (INSERT); Heed's own keys never get here.
///
/// Key and IME handling follows Ghostty's own `SurfaceView_AppKit.swift`, trimmed to what an embedded pane needs.
@MainActor
public final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    /// Text committed by the input method during the current `keyDown`; nil outside one.
    private var keyTextAccumulator: [String]?
    private var contentSize: CGSize = .zero
    /// The size in pixels last given to the surface: a divider dragged within one pixel, or a layout pass that changed
    /// nothing, does not make the terminal resize (and redraw) again.
    private var surfacePixels: (width: UInt32, height: UInt32)?

    public init(launch: TerminalLaunch) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        createSurface(launch)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    private func createSurface(_ launch: TerminalLaunch) {
        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        // C strings must outlive ghostty_surface_new; strdup and free afterwards.
        var allocations: [UnsafeMutablePointer<CChar>] = []
        func c(_ string: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(string)!
            allocations.append(pointer)
            return pointer
        }
        defer { allocations.forEach { free($0) } }

        config.working_directory = UnsafePointer(c(launch.directory))
        if let command = launch.command { config.command = UnsafePointer(c(command)) }
        var env = launch.environment.map { ghostty_env_var_s(key: c($0.key), value: c($0.value)) }
        surface = env.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(app, &config)
        }
        if surface == nil { NSLog("heed: ghostty_surface_new failed for \(launch.directory)") }
    }

    // MARK: Reading the screen

    /// The visible screen as text, for guessing agent states from output. Cheap enough to poll a few times a second.
    public func visibleText() -> String? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: UInt32(max(size.columns, 1) - 1), y: UInt32(max(size.rows, 1) - 1)
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Types `text` without pressing Return, leaving it for the user to finish.
    public func typeText(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// Types `text` and presses Return, as if the user did: used to send the continue prompt to a resumed agent. Never
    /// to
    /// start one: a shell that is still starting can lose or garble what is typed (`PaneLaunch`).
    public func typeLine(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var key = ghostty_input_key_s()
            key.action = action
            key.keycode = 36 // Return
            key.mods = GHOSTTY_MODS_NONE
            key.consumed_mods = GHOSTTY_MODS_NONE
            if action == GHOSTTY_ACTION_PRESS {
                _ = "\r".withCString { pointer in
                    key.text = pointer
                    return ghostty_surface_key(surface, key)
                }
            } else {
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    /// True once the surface's process has exited (the pane shows Ghostty's "process exited" state).
    public var processExited: Bool { surface.map(ghostty_surface_process_exited) ?? true }

    // MARK: Layout and focus

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        updateSurfaceSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        surfacePixels = nil
        updateSurfaceSize()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
        surfacePixels = nil
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, contentSize.width > 0, contentSize.height > 0 else { return }
        let scaled = convertToBacking(contentSize)
        let pixels = (width: UInt32(scaled.width), height: UInt32(scaled.height))
        if let last = surfacePixels, last == pixels { return }
        surfacePixels = pixels
        ghostty_surface_set_size(surface, pixels.width, pixels.height)
    }

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, true) }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let committed = keyTextAccumulator, !committed.isEmpty {
            for text in committed {
                _ = sendKey(action, event: event, text: text)
            }
        } else if !(composing && (event.characters?.unicodeScalars.first.map { $0.value < 0x20 } ?? false)) {
            _ = sendKey(action, event: event, text: Self.terminalCharacters(event), composing: composing)
        }
    }

    override public func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Command-key combinations arrive here before `keyDown`. When the terminal has focus they are its keys (copy,
    /// paste, Ghostty bindings); Heed's own command keys were already taken by the key router before this point.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        else { return false }
        keyDown(with: event)
        return true
    }

    override public func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        guard markedText.length == 0 else { return }
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        _ = sendKey(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    private func sendKey(
        _ action: ghostty_input_action_e, event: NSEvent, text: String? = nil, composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        // Control and command never contribute to the text; everything else may have.
        key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
        key.composing = composing
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        // Control characters (Return, Tab, ⌃ chords) go without text: given "\r", Ghostty sends it as typed, and the
        // modifiers are lost, so ⇧↩ would be ↩. Without text it encodes the key and its modifiers itself, as the
        // program asked (the Kitty keyboard protocol's CSI 13;2u for ⇧↩).
        guard let text, let first = text.unicodeScalars.first, first.value >= 0x20 else {
            return ghostty_surface_key(surface, key)
        }
        return text.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    /// The event's text as Ghostty wants it: control characters without control (Ghostty encodes those itself),
    /// and no private-use function-key characters.
    private static func terminalCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar
                .value <
                0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700 ... 0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: Mouse

    /// Called on a left click, before the terminal sees it: the app focuses this pane and enters INSERT.
    public var onClick: (() -> Void)?

    override public func mouseDown(with event: NSEvent) {
        onClick?()
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }

    override public func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override public func rightMouseDown(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
    }

    override public func rightMouseUp(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
    }

    override public func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override public func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Self.mods(event.modifierFlags))
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        // Precise (trackpad) deltas are scaled up the way Ghostty's own view does.
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(precise ? 1 : 0))
    }

    private func mouseButton(
        _ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        mouseMoved(with: event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    // MARK: NSTextInputClient (input methods: Korean, Japanese, dead keys)

    public func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            // Committed outside a key event (e.g. the emoji picker).
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        }
    }

    public func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(
            location: NSNotFound,
            length: 0
        )
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func attributedSubstring(
        forProposedRange _: NSRange,
        actualRange _: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let local = NSRect(x: x, y: frame.height - y, width: width, height: height)
        return window.convertToScreen(convert(local, to: nil))
    }

    public func characterIndex(for _: NSPoint) -> Int { 0 }

    override public func doCommand(by _: Selector) {
        // Keys AppKit maps to editing commands (arrows, return) are sent by keyDown; nothing to do here.
    }
}
