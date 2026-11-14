/// Settings › Personas' commands and key scopes: the library, Add a persona, and defining one with an agent.
/// `Commands.all` and `DefaultKeys.scoped` take them in; the Settings window reads its keys from these scopes (the main
/// window never sees Settings' keys).
public enum PersonaKeys {
    public static let commands: [CommandSpec] = [
        .init("personas.open", "Settings › Personas: the people heed asks for a view, in one library", .views),
        .init("personas.move", "Personas: the persona below (1) or above (-1)", .move, arguments: "<1|-1>"),
        .init("personas.toggle", "Personas: turn the persona under the cursor on or off", .selection),
        .init(
            "personas.try",
            "Personas: try the persona on a recent merged PR in its scope (a cheap model call); defining one: another PR",
            .selection
        ),
        .init("personas.edit", "Personas: edit the persona's file in place (again, ⎋ or ⌘S: save it)", .selection),
        .init("personas.share", "Personas: copy the persona's file, to send to a teammate", .selection),
        .init(
            "personas.join", "Personas: what the persona joins on its own, on or off", .selection,
            arguments: "<panels|pr|plans>"
        ),
        .init(
            "personas.add",
            "Personas: add one: heed reads your repos and proposes the people they serve (a cheap model call)",
            .selection
        ),
        .init("personas.pick", "Add a persona: pick the proposal under the cursor (again: unpick)", .selection),
        .init("personas.read", "Add a persona: read the repos picked again and propose again", .selection),
        .init("personas.repo", "Add a persona: look at a repo, or not", .selection, arguments: "<repo>"),
        .init("personas.describe", "Add a persona: describe one in your words; heed drafts it", .selection),
        .init(
            "personas.overlap", "Add a persona: a proposal that overlaps one you have: sharpen that one, or keep both",
            .selection, arguments: "<sharpen|keep>"
        ),
        .init("personas.drafted", "Add a persona: add the picked as drafted, into the library", .selection),
        .init(
            "personas.define",
            "Add a persona: define the picked with an agent: an ACP session per persona that reads the repo and writes "
                + "nothing", .selection
        ),
        .init("personas.answer", "defining a persona: type an answer to its agent", .selection),
        .init("personas.option", "defining a persona: answer with option n", .selection, arguments: "<n>"),
        .init("personas.next", "defining a persona: the next picked persona", .selection),
        .init("personas.save", "defining a persona: save it into the library", .selection),
        .init(
            "personas.close",
            "Personas: close Add a persona, or the persona being defined (nothing saved)",
            .selection
        ),
    ]

    public static let scopes = ["personas", "personaadd", "personadefine"]

    public static let scoped: [String: [(String, String)]] = [
        // The library: j k move (the arrows stay the Settings tree's), space turns on or off, a adds, t tries on a
        // PR, e edits the file, p shares it.
        "personas": [
            ("j", "personas.move 1"), ("k", "personas.move -1"), ("<Space>", "personas.toggle"), ("a", "personas.add"),
            ("t", "personas.try"), ("e", "personas.edit"), ("p", "personas.share"),
        ],
        // Add a persona: j k move, space picks, i describes one, r reads again, s sharpens the one it overlaps, b keeps
        // both, ⌘↩ defines the picked with an agent, ⌥↩ adds them as drafted, ⎋ closes.
        "personaadd": [
            ("j", "personas.move 1"), ("k", "personas.move -1"), ("<Down>", "personas.move 1"),
            ("<Up>", "personas.move -1"), ("<Space>", "personas.pick"), ("i", "personas.describe"),
            ("r", "personas.read"), ("s", "personas.overlap sharpen"), ("b", "personas.overlap keep"),
            ("<D-CR>", "personas.define"), ("<M-CR>", "personas.drafted"), ("<Esc>", "personas.close"),
        ],
        // Defining one: i answers, 1 2 3 pick, t tries another PR, n the next persona (] would wait on NORMAL's ]p), ⌘↩
        // saves, ⎋ closes.
        "personadefine": [
            ("i", "personas.answer"), ("t", "personas.try"), ("n", "personas.next"), ("<D-CR>", "personas.save"),
            ("<Esc>", "personas.close"),
        ] + (1 ... 3).map { ("\($0)", "personas.option \($0)") },
    ]
}
