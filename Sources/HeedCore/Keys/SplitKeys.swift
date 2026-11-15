/// Step 4 Split's commands and key scopes, and the goal's page's: the board's cursor, a part's fold-out and its
/// actions, defining a part with an agent. `WizardKeys` takes them into `Commands.all` and `DefaultKeys.scoped`.
public enum SplitKeys {
    public static let commands: [CommandSpec] = [
        .init(
            "split.move",
            "Split: the board's cursor: h l the part before or after in time, j k the agent below or above",
            .move, arguments: "<h|j|k|l>"
        ),
        .init("split.fold", "Split: fold the part under the cursor out (again: in)", .selection),
        .init(
            "split.agent",
            "Split: the part on the next agent who should do it (with a name, that agent); it stays where you put it",
            .selection, arguments: "[agent]"
        ),
        .init(
            "split.shift", "Split: move the part to the agent's row below (1) or above (-1)", .selection,
            arguments: "<1|-1>"
        ),
        .init("split.split", "Split: split the part in two (a cheap model call)", .selection),
        .init("split.waits", "Split: what the part waits on: type part numbers (empty: nothing)", .selection),
        .init("split.size", "Split: the part's size, round from XS to L; its estimate follows", .selection),
        .init("split.later", "Split: put the part off (Later), or bring it back", .selection),
        .init("split.note", "Split: tell the part's agent something before it starts", .selection),
        .init(
            "split.define",
            "Split: define the part with its agent: an ACP session that reads the repo and writes nothing", .selection
        ),
        .init(
            "split.balance", "Split: balance for the credits you have, speed, or the fewest agents (round)",
            .selection, arguments: "[credits|speed|fewest]"
        ),
        .init("split.resplit", "Split: split the plan again (a cheap model call); your changes go", .selection),
        .init("define.answer", "defining a part: type an answer to its agent", .selection),
        .init(
            "define.pick",
            "defining a part: answer the agent's question with option n",
            .selection,
            arguments: "<n>"
        ),
        .init(
            "define.use",
            "defining a part: use this definition: the part takes its done when, estimate and context",
            .selection
        ),
        .init("define.later", "defining a part: put it off; d on the part comes back to the conversation", .selection),
        .init("define.close", "defining a part: close it; nothing changes", .selection),
        .init(
            "page.move",
            "the goal's page: h l the part before or after in time, j k the agent below or above (without a part: the "
                + "goals)", .move, arguments: "<h|j|k|l>"
        ),
        .init("page.fold", "the goal's page: fold the part out (again: in); without a part, open the goal", .selection),
        .init("page.steer", "the goal's page: steer the running part: its live helper or worker opens", .selection),
        .init("page.pick", "the goal's page: answer your next step with option n", .selection, arguments: "<n>"),
        .init("page.answer", "the goal's page: type an answer to your next step", .selection),
    ]

    public static let scopes = ["wizardsplit", "splitfold", "splitdefine"]

    /// The goal's page's keys, laid over Goals' list (the page is the goal's overview): h l j k move over the board
    /// once a part is under the cursor (without one, h l j k ⎋ do what they do anyway), ↩ folds a part out, s steers
    /// it, i answers your next step.
    public static let page: [(String, String)] = [
        ("h", "page.move h"), ("l", "page.move l"), ("j", "page.move j"), ("k", "page.move k"),
        ("<CR>", "page.fold"), ("<Esc>", "page.fold in"), ("s", "page.steer"), ("i", "page.answer"),
    ]

    /// The board's keys: h l in time, j k between agents, ↩ folds out, J K move a part between agents, and a part's
    /// actions (the fold-out's buttons): d define, a agent, s split, w waits on, Z size (z starts NORMAL's z keys), p
    /// later, i tell it.
    static let board: [(String, String)] = [
        ("<D-CR>", "wizard.next"), ("H", "wizard.step prev"), ("L", "wizard.step next"), ("T", "goal.tldr"),
        ("h", "split.move h"), ("l", "split.move l"), ("j", "split.move j"), ("k", "split.move k"),
        ("<Left>", "split.move h"), ("<Right>", "split.move l"), ("<Down>", "split.move j"), ("<Up>", "split.move k"),
        ("<CR>", "split.fold"), ("J", "split.shift 1"), ("K", "split.shift -1"),
        ("d", "split.define"), ("a", "split.agent"), ("s", "split.split"), ("w", "split.waits"), ("Z", "split.size"),
        ("p", "split.later"), ("i", "split.note"), ("b", "split.balance"), ("r", "split.resplit"),
        ("D", "wizard.discard"),
    ]

    public static let scoped: [String: [(String, String)]] = [
        // The board: ⎋ leaves the wizard, as on every step.
        "wizardsplit": board + [("<Esc>", "wizard.leave")],
        // A part folded out: ⎋ folds it in.
        "splitfold": board + [("<Esc>", "split.fold")],
        // Defining a part: i answers, 1 2 3 pick, ⌘↩ uses the definition, p puts it off, ⎋ closes.
        "splitdefine": [
            ("i", "define.answer"), ("<D-CR>", "define.use"), ("p", "define.later"), ("<Esc>", "define.close"),
            ("T", "goal.tldr"),
        ] + (1 ... 3).map { ("\($0)", "define.pick \($0)") },
    ]
}
