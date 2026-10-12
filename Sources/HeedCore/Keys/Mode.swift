/// The app's input modes. Each mode has its own keymap; INSERT has only the escape chord.
public enum Mode: String, CaseIterable, Sendable, Codable {
    /// Keys drive the app; nothing reaches a terminal.
    case normal
    /// Every key goes to the focused pty, except the escape chord.
    case insert
    /// Multi-select rows, then act on all of them.
    case visual
    /// `:` command line with completion.
    case command
    /// Letter badges over every pane, tab and session.
    case hint

    public var label: String { rawValue.uppercased() }
}
