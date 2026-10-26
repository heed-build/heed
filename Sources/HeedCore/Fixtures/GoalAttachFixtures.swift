import Foundation

/// The fake world's attachment: what heed decided about new work lately (one attached on its own, one ask, things left
/// unassigned, three of them about one thing, one a rule ignored, one you undid) and the rules it learnt. The things
/// are not `Fixtures.main`'s sessions, so the goals' own shots stay as they are. Invented, as every fixture is.
public extension GoalFixtures {
    static func attachDecisions(now: Date = Clock.now) -> [AttachDecision] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - (hours * 3600).rounded()) }
        let anchors = "anchors-survive-page-moves", diagrams = "sequence-diagrams-read-cleanly"
        func signal(_ kind: AttachSignal.Kind, _ weight: Double, _ reason: String) -> AttachSignal {
            AttachSignal(kind, weight, reason)
        }
        let headings = AttachCandidate(goal: anchors, confidence: 0.91, signals: [
            signal(.family, 0.65, "branch family anchors"), signal(.files, 0.67, "5 of 6 touched files on the goal"),
            signal(.repo, 0.15, "same repo acme/docs-toolkit"),
        ])
        let lifelines = AttachCandidate(goal: diagrams, confidence: 0.68, signals: [
            signal(.terms, 0.4, "mentions lifeline, arrowhead, overlap"),
        ])
        func markgraph(_ id: String, _ title: String, _ prompt: String, _ branch: String, _ hours: Double)
            -> AttachDecision
        {
            AttachDecision(
                subject: AttachSubject(
                    kind: .session, id: id, title: title, prompt: prompt, repos: ["globex/markgraph"], branch: branch,
                    worktreePaths: ["/Users/you/code/wt/markgraph/\(branch)"], at: ago(hours)
                ),
                trigger: .prompt,
                verdict: AttachVerdict(
                    action: .leave, confidence: 0.24,
                    reason: "best Sequence diagrams read cleanly at 24%: same repo globex/markgraph"
                ),
                candidates: [AttachCandidate(goal: diagrams, confidence: 0.24, signals: [
                    signal(.repo, 0.15, "same repo globex/markgraph"), signal(.recency, 0.1, "goal active lately"),
                ])],
                at: ago(hours)
            )
        }
        return [
            AttachDecision(
                subject: AttachSubject(
                    kind: .session, id: "f-heading-ids", title: "Heading ids survive renames",
                    prompt: "Keep heading ids stable when a heading is renamed, so redirects still land.",
                    repos: ["acme/docs-toolkit"], branch: "feature/anchors-heading-ids",
                    worktreePaths: ["/Users/you/code/wt/docs-toolkit/anchors-heading-ids"], at: ago(0.2)
                ),
                trigger: .prompt,
                verdict: AttachVerdict(action: .attach, goal: anchors, confidence: 0.91, reason: headings.reason),
                candidates: [headings], at: ago(0.2)
            ),
            AttachDecision(
                subject: AttachSubject(
                    kind: .chat, id: "f-lifelines", title: "Do lifelines need their own z-order?",
                    prompt: "When an arrowhead meets a lifeline, which one draws on top, and does the overlap change "
                        + "with zoom?", at: ago(20)
                ),
                trigger: .prompt,
                verdict: AttachVerdict(
                    action: .ask, goal: diagrams, confidence: 0.68,
                    reason: lifelines.reason + " · model: fits Sequence diagrams read cleanly (70% sure)", basis: .model
                ),
                candidates: [lifelines], tokens: 1460, at: ago(20)
            ),
            AttachDecision(
                subject: AttachSubject(
                    kind: .session, id: "f-formatter", title: "Bump the formatter",
                    prompt: "Update swift-format and fix whatever it flags.", repos: ["initech/editor-rules"],
                    branch: "chore/formatter", at: ago(1)
                ),
                trigger: .started, verdict: AttachVerdict(action: .leave, reason: "no goal matches"), at: ago(1)
            ),
            AttachDecision(
                subject: AttachSubject(
                    kind: .chat, id: "f-scratch", title: "scratch: regex for headings", at: ago(3)
                ),
                trigger: .started,
                verdict: AttachVerdict(action: .ignore, reason: "rule line 6: ignore chat:scratch*", basis: .rule),
                at: ago(3)
            ),
            AttachDecision(
                subject: AttachSubject(
                    kind: .session, id: "f-nav-tables", title: "Tables in the docs nav", repos: ["acme/docs-toolkit"],
                    branch: "docs-nav-tables", worktreePaths: ["/Users/you/code/wt/docs-toolkit/docs-nav-tables"],
                    at: ago(4.2)
                ),
                trigger: .ledger,
                verdict: AttachVerdict(
                    action: .attach, goal: anchors, confidence: 0.86,
                    reason: "4 of 5 touched files on the goal · same repo acme/docs-toolkit"
                ),
                state: .undone, goal: nil, resolvedAt: ago(4), tokens: 0, at: ago(4.2)
            ),
            markgraph(
                "f-col-widths", "Column widths for tables in export", "Tables in the PDF export ignore column widths.",
                "export-column-widths", 2
            ),
            markgraph(
                "f-wide-tables", "Wide tables wrap their column headers",
                "Column headers in wide tables wrap mid-word.", "wide-table-headers", 26
            ),
            markgraph(
                "f-table-overflow", "Table column widths overflow",
                "A table with long cells overflows its column widths.",
                "table-overflow", 50
            ),
        ]
    }

    /// `attach.rules` as heed would have written it, and one line of yours.
    static let attachRules = """
    # How heed puts sessions and chats on goals. heed adds a line when you correct it; edit or delete any line.
    # always|never|ignore field:glob … [-> goal]; fields: worktree, branch, repo, chat, session, title, prompt.

    # you undid Tables in the docs nav on anchors-survive-page-moves
    never worktree:*/docs-nav-* -> anchors-survive-page-moves
    ignore chat:scratch*

    """
}
