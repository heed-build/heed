/// Personas in sessions: the panel's commands and key scopes. `Commands.all` and `DefaultKeys.scoped` take them in.
/// `gL` (NORMAL) asks the panel for a look at the session under the cursor: yes to an offer, open a verdict, or ask
/// now without a milestone. The offer line, the verdict's popover, a held PR and a chat with one persona each have a
/// scope laid over Sessions'.
public enum PanelKeys {
    public static let commands: [CommandSpec] = [
        .init(
            "panel.ask",
            "ask the panel for a look at the session's work: yes to its offer, open its verdict, or ask now (a cheap "
                + "model call); with names, only those personas", .selection, arguments: "[persona…]"
        ),
        .init("panel.notnow", "the panel's offer: not now (the next milestone offers again)", .selection),
        .init("panel.never", "the panel's offer: never in this session (you can still ask)", .selection),
        .init(
            "panel.send",
            "the panel's verdict: send its concerns to the agent (its inbox, else typed under the usual rules)",
            .selection
        ),
        .init(
            "panel.talk",
            "the panel's verdict: talk to the persona under the cursor (again: close the chat)",
            .selection
        ),
        .init("panel.say", "talking to a persona: type to it", .selection),
        .init("panel.dismiss", "the panel's verdict: dismiss it", .selection),
        .init("panel.close", "close the panel's popover", .selection),
        .init("panel.row", "the panel's popover: the persona below (1) or above (-1)", .move, arguments: "<1|-1>"),
        .init(
            "panel.pr", "a PR held for the panel: let it open, send the concern first, or hold the PR", .selection,
            arguments: "<open|concern|hold>"
        ),
        // Settings › Personas › In sessions.
        .init("personas.sessions", "Settings › Personas: the library, or when personas look at sessions", .views),
        .init(
            "personas.signal",
            "Personas in sessions: the milestone below (1) or above (-1)",
            .move,
            arguments: "<1|-1>"
        ),
        .init("personas.signal.toggle", "Personas in sessions: the milestone under the cursor on or off", .selection),
    ]

    public static let scopes = [
        "sessionsoffer",
        "sessionspanel",
        "sessionspanelpr",
        "sessionspanelchat",
        "personasessions",
    ]

    /// The popover's moving keys.
    static let rows: [(String, String)] = [
        ("j", "panel.row 1"), ("k", "panel.row -1"), ("<Down>", "panel.row 1"), ("<Up>", "panel.row -1"),
    ]

    public static let scoped: [String: [(String, String)]] = [
        // The offer line at the session's foot: gL (NORMAL's) says yes, x not now, N never here.
        "sessionsoffer": DefaultKeys.laid([("x", "panel.notnow"), ("N", "panel.never")], over: DefaultKeys.sessions),
        // The verdict's popover (gL on the verdict line): ↩ sends the concerns to the agent, i talks to the persona
        // under the cursor, x dismisses, ⎋ (or gL) closes.
        "sessionspanel": DefaultKeys.laid(
            rows + [
                ("<CR>", "panel.send"), ("i", "panel.talk"), ("x", "panel.dismiss"), ("<Esc>", "panel.close"),
            ],
            over: DefaultKeys.sessions
        ),
        // A held PR's popover: ↩ lets it open, s sends the concern first, h holds the PR, ⎋ closes (it stays held).
        "sessionspanelpr": DefaultKeys.laid(
            rows + [
                ("<CR>", "panel.pr open"), ("s", "panel.pr concern"), ("h", "panel.pr hold"), ("<Esc>", "panel.close"),
            ],
            over: DefaultKeys.sessions
        ),
        // Talking to one persona: i types, ⎋ closes the chat.
        "sessionspanelchat": DefaultKeys.laid(
            [("i", "panel.say"), ("<Esc>", "panel.talk")], over: DefaultKeys.sessions
        ),
        // Settings › Personas › In sessions: j k the milestones, space on or off, s back to the library.
        "personasessions": [
            ("j", "personas.signal 1"), ("k", "personas.signal -1"), ("<Space>", "personas.signal.toggle"),
            ("s", "personas.sessions"), ("<Esc>", "personas.sessions"),
        ],
    ]
}
