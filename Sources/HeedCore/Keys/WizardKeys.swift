/// The new-goal wizard's commands and key scopes, kept together so the wizard's keys read in one place. `Commands.all`
/// and `DefaultKeys.scoped` take them in.
public enum WizardKeys {
    public static let commands: [CommandSpec] = [
        .init(
            "goal.wizard",
            "Goals: walk the goal through the new-goal wizard (plan, panel, done looks like, …); where it was left, "
                + "it resumes",
            .views, arguments: "[goal]"
        ),
        .init(
            "goal.tldr", "the goal's TL;DR: each step's summary, what is settled, what is still open (toggle)", .views
        ),
        .init("wizard.leave", "wizard: back to the goals; it keeps its place", .selection),
        .init(
            "wizard.next",
            "wizard: on to the next step (Plan: good enough; Panel: worth it, take the fixes; Done looks like: looks "
                + "right)",
            .selection
        ),
        .init(
            "wizard.step",
            "wizard: show a step already reached (prev, next, or a name)",
            .selection,
            arguments: "<step>"
        ),
        .init("wizard.row", "wizard: the persona or criterion below (1) or above (-1)", .move, arguments: "<delta>"),
        .init(
            "wizard.pick",
            "wizard: Plan answers with option n; Done looks like highlights replacement n", .selection, arguments: "<n>"
        ),
        .init("wizard.answer", "wizard: type an answer (Plan), or a message to the persona you talk to", .selection),
        .init("wizard.smaller", "wizard: Panel: make the plan smaller, and the panel reads it again", .selection),
        .init("wizard.talk", "wizard: Panel: talk to the persona under the cursor (again: close)", .selection),
        .init("wizard.drop", "wizard: Panel: don't do it: archive the goal with the reason", .selection),
        .init(
            "wizard.invite", "wizard: Panel: invite another persona (the picker; with a name, that one)", .selection,
            arguments: "[persona]"
        ),
        .init("wizard.invite.pick", "wizard: invite the persona under the cursor in the picker", .selection),
        .init("wizard.use", "wizard: Done looks like: use the highlighted replacement for the criterion", .selection),
        .init(
            "wizard.define",
            "wizard: Done looks like: an agent reads the repo and proposes a check for the criterion", .selection,
            arguments: "[n]"
        ),
        .init(
            "wizard.later",
            "wizard: a step heed has no screen for yet: open the goal's page that does it",
            .selection
        ),
        .init("tldr.copy", "TL;DR: copy it as markdown", .selection),
        .init("tldr.act", "TL;DR: do the first open point's action", .selection),
    ]

    /// Keys every step shares: ⌘↩ on, H L between the steps reached, j k rows, T the TL;DR, ⎋ out.
    static let shared: [(String, String)] = [
        ("<D-CR>", "wizard.next"), ("H", "wizard.step prev"), ("L", "wizard.step next"),
        ("j", "wizard.row 1"), ("k", "wizard.row -1"), ("<Down>", "wizard.row 1"), ("<Up>", "wizard.row -1"),
        ("T", "goal.tldr"), ("<Esc>", "wizard.leave"),
    ]

    public static let scopes = [
        "wizardplan",
        "wizardpanel",
        "wizarddone",
        "wizardlater",
        "wizardchat",
        "wizardinvite",
        "tldr",
    ]

    public static let scoped: [String: [(String, String)]] = [
        // Plan: 1 2 3 pick heed's option, i types an answer, ⌘↩ good enough.
        "wizardplan": shared + [("i", "wizard.answer")] + (1 ... 9).map { ("\($0)", "wizard.pick \($0)") },
        // Panel: ⌘↩ worth it, take the fixes; - go smaller; i talk to one; x don't do it; + invite another.
        "wizardpanel": shared + [
            ("-", "wizard.smaller"), ("i", "wizard.talk"), ("x", "wizard.drop"), ("+", "wizard.invite"),
        ],
        // Done looks like: j k criteria, 1 2 3 a replacement, ↩ uses it, d defines it with an agent, ⌘↩ looks right.
        "wizarddone": shared + [("<CR>", "wizard.use"), ("d", "wizard.define")]
            + (1 ... 3).map { ("\($0)", "wizard.pick \($0)") },
        // Split, How careful, Go until they have screens: ↩ opens the goal's page that does it today.
        "wizardlater": shared + [("<CR>", "wizard.later")],
        // Talking to one persona: i types, ⎋ closes the chat.
        "wizardchat": [("i", "wizard.answer"), ("<Esc>", "wizard.talk"), ("T", "goal.tldr")],
        // The + picker: j k, ↩ invites, ⎋ closes.
        "wizardinvite": [
            ("j", "wizard.row 1"), ("k", "wizard.row -1"), ("<Down>", "wizard.row 1"), ("<Up>", "wizard.row -1"),
            ("<CR>", "wizard.invite.pick"), ("<Esc>", "wizard.invite"),
        ],
        // The TL;DR: y copies it as markdown, d does the first open point, T or ⎋ closes.
        "tldr": [("y", "tldr.copy"), ("d", "tldr.act"), ("T", "goal.tldr"), ("<Esc>", "goal.tldr"), ("q", "goal.tldr")],
    ]
}
