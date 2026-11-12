import Foundation

/// The fake world's threads as the reader shows them: bodies and comments in GitHub's rendered HTML, with the
/// markdown a real thread has (code, tables, task lists, images, mentions). All invented.
public extension Fixtures {
    /// The readers' conversations, by `ThreadConversation.key`: the PR in the reader (#2841), the issue it closes
    /// (#2830) and the PR Attention's detail shows (#2845).
    static var conversations: [String: ThreadConversation] {
        let all = [fixPull, anchorsIssue, linkPull]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }

    /// Images the fake world's threads show, by URL: what the image handler serves in fixtures. Any other URL
    /// fails, as a private image would.
    static let threadImages: [String: Data] = [graphImageURL: Data(redirectGraph.utf8)]

    // MARK: Pieces

    internal static let graphImageURL = "https://github.com/user-attachments/assets/redirect-graph-2841"
    internal static let privateImageURL = "https://private-user-images.githubusercontent.com/7/moved-page.png"

    private static func ago(_ minutes: Double) -> Date { Clock.now.addingTimeInterval(-minutes * 60) }

    private static func person(_ login: String, bot: Bool = false) -> ThreadAuthor {
        ThreadAuthor(login: login, avatarURL: nil, isBot: bot)
    }

    private static func mention(_ login: String) -> String {
        "<a class=\"user-mention notranslate\" data-hovercard-type=\"user\" href=\"https://github.com/\(login)\">"
            + "@\(login)</a>"
    }

    private static func issueLink(_ repo: Repo, _ number: Int, pull: Bool = false) -> String {
        let label = repo == docsToolkit ? "#\(number)" : "\(repo.slug)#\(number)"
        return "<a class=\"issue-link js-issue-link\" href=\"https://github.com/\(repo.slug)/"
            + "\(pull ? "pull" : "issues")/\(number)\">\(label)</a>"
    }

    private static func code(_ language: String, _ lines: String) -> String {
        "<div class=\"highlight highlight-source-\(language) notranslate position-relative overflow-auto\" "
            + "dir=\"auto\"><pre>\(lines)</pre><div class=\"zeroclipboard-container\">"
            + "<clipboard-copy aria-label=\"Copy\" class=\"ClipboardButton btn\"></clipboard-copy></div></div>"
    }

    private static func image(_ url: String, alt: String) -> String {
        "<p><a target=\"_blank\" rel=\"noopener noreferrer\" href=\"\(url)\"><img src=\"\(url)\" alt=\"\(alt)\" "
            + "style=\"max-width: 100%;\"></a></p>"
    }

    // MARK: docs-toolkit#2841, your PR in the reader

    private static var fixPull: ThreadConversation {
        let body = """
        <p>Validates redirect targets against real headings, so moved pages no longer lose their anchors. \
        Closes \(issueLink(docsToolkit, 2830)). Companion change in \(issueLink(docsWebsite, 1920, pull: true)).</p>
        <h3>What changes</h3>
        <ul class="contains-task-list">
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled checked> \
        Anchor lookup goes through <code>Slugify</code>, as the headings do</li>
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled checked> \
        A redirect to a missing anchor fails the build with the file and line</li>
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled> \
        Cover the moved-page case in <code>AnchorTests</code></li>
        </ul>
        \(image(graphImageURL, alt: "Redirect graph before and after"))
        """
        let review = """
        <p>The direction is right. Two things before this goes in, both inline: the lookup is still case \
        sensitive, and the moved-page case has no test.</p>
        """
        let reply = """
        <p>Thanks \(mention("reviewer")). The lookup now uses <code>StringComparer.OrdinalIgnoreCase</code>:</p>
        \(code(
            "cs",
            "<span class=\"pl-k\">var</span> <span class=\"pl-s1\">exists</span> = <span class=\"pl-s1\">anchors</span>."
                + "<span class=\"pl-en\">Contains</span>(<span class=\"pl-s1\">target</span>, "
                + "<span class=\"pl-smi\">StringComparer</span>.<span class=\"pl-c1\">OrdinalIgnoreCase</span>);"
        ))
        <p>The test is next; it needs the fixture from \(issueLink(docsToolkit, 2830)).</p>
        """
        let ci = """
        <p><strong>lint</strong> failed on <code>docs/redirects.md:41</code>: line too long (131 &gt; 120).</p>
        """
        return ThreadConversation(
            repo: docsToolkit, number: 2841, kind: .pr, title: "Fix broken anchors in redirects",
            url: "https://github.com/acme/docs-toolkit/pull/2841", state: "OPEN", author: person("you"),
            createdAt: ago(26 * 60), bodyHTML: body, labels: ["bug"],
            comments: [
                ThreadComment(
                    id: "R1", author: person("reviewer"), createdAt: ago(686), bodyHTML: review,
                    review: "CHANGES_REQUESTED"
                ),
                ThreadComment(
                    id: "C1", author: person("you"), createdAt: ago(300), bodyHTML: reply,
                    reactions: [ThreadReaction(content: "THUMBS_UP", count: 1)]
                ),
                ThreadComment(id: "C2", author: person("docs-bot", bot: true), createdAt: ago(42), bodyHTML: ci),
            ],
            fetchedAt: Clock.now
        )
    }

    // MARK: docs-toolkit#2830, the issue

    private static var anchorsIssue: ThreadConversation {
        let body = """
        <p>Moving a page drops its heading anchors from redirects: a link to <code>/old-page#install</code> lands \
        on the top of the new page instead of its <em>Install</em> section.</p>
        <h3>Steps</h3>
        <ol>
        <li>Move <code>guides/setup.md</code> to <code>get-started/setup.md</code></li>
        <li>Build with <code>docs-builder build --strict</code></li>
        <li>Open <code>/guides/setup#install</code></li>
        </ol>
        \(code(
            "yaml",
            "<span class=\"pl-ent\">redirects</span>:\n  <span class=\"pl-ent\">guides/setup.md</span>: "
                + "<span class=\"pl-s\">get-started/setup.md</span>   "
                + "<span class=\"pl-c\"><span class=\"pl-c\">#</span> anchors are not carried over</span>"
        ))
        <table>
        <thead><tr><th>page</th><th>anchors</th><th>lost</th></tr></thead>
        <tbody><tr><td><code>setup.md</code></td><td>9</td><td>9</td></tr>
        <tr><td><code>upgrade.md</code></td><td>14</td><td>3</td></tr></tbody>
        </table>
        \(image(privateImageURL, alt: "The moved page without its anchor"))
        <p>cc \(mention("you")), this is the redirect map from \(issueLink(docsWebsite, 1920, pull: true)).</p>
        """
        let first = """
        <p>Reproduced on main. The redirect file keeps the path and drops everything after <code>#</code>.</p>
        <blockquote><p>a link to a moved page should land where it pointed before</p></blockquote>
        <p>That is the rule I'd test against.</p>
        """
        let second = """
        <p>Picking this up in \(issueLink(docsToolkit, 2841, pull: true)): anchors are now validated against \
        the target page's headings, and a missing one fails the build.</p>
        """
        return ThreadConversation(
            repo: docsToolkit, number: 2830, kind: .issue, title: "Anchors lost when a page is moved",
            url: "https://github.com/acme/docs-toolkit/issues/2830", state: "OPEN", author: person("reviewer"),
            createdAt: ago(3 * 1440), bodyHTML: body,
            reactions: [ThreadReaction(content: "THUMBS_UP", count: 4), ThreadReaction(content: "EYES", count: 1)],
            labels: ["bug"],
            comments: [
                ThreadComment(id: "I1", author: person("docs-writer"), createdAt: ago(2 * 1440), bodyHTML: first),
                ThreadComment(
                    id: "I2", author: person("you"), createdAt: ago(26 * 60), bodyHTML: second,
                    reactions: [ThreadReaction(content: "HOORAY", count: 2)]
                ),
            ],
            fetchedAt: Clock.now
        )
    }

    // MARK: docs-toolkit#2845, the PR Attention shows

    private static var linkPull: ThreadConversation {
        let body = """
        <p>Validates every link the assembler writes, and fails the build on a broken one.</p>
        <ul class="contains-task-list">
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled checked> \
        internal links and anchors</li>
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled> \
        cross-repo links (follow-up)</li>
        </ul>
        """
        let question = """
        <p>Looks good overall. One question before I approve:</p>
        \(code(
            "yaml",
            "<span class=\"pl-ent\">redirects</span>:\n  <span class=\"pl-ent\">map</span>: "
                + "<span class=\"pl-s\">generated</span>   "
                + "<span class=\"pl-c\"><span class=\"pl-c\">#</span> or: checked-in</span>"
        ))
        <p>Which of the two do we want? If <code>generated</code>, the assembler needs to run before \
        <code>lint</code>.</p>
        <table><thead><tr><th>option</th><th>cost</th></tr></thead>
        <tbody><tr><td>generated</td><td>+40 s CI</td></tr><tr><td>checked in</td><td>drift risk</td></tr></tbody>
        </table>
        """
        return ThreadConversation(
            repo: docsToolkit, number: 2845, kind: .pr, title: "Add link validation to assembler",
            url: "https://github.com/acme/docs-toolkit/pull/2845", state: "OPEN", author: person("reviewer"),
            createdAt: ago(2 * 1440), bodyHTML: body, labels: ["feature"],
            comments: [
                ThreadComment(
                    id: "L1", author: person("reviewer"), createdAt: ago(30),
                    bodyHTML: "<p>Validator looks good, one question first.</p>"
                ),
                ThreadComment(
                    id: "L2", author: person("you"), createdAt: ago(20),
                    bodyHTML: "<p>The map is generated at build time.</p>"
                ),
                ThreadComment(id: "L3", author: person("reviewer"), createdAt: ago(4), bodyHTML: question),
            ],
            fetchedAt: Clock.now
        )
    }

    /// A drawn redirect graph: what the fixture PR's screenshot shows.
    private static let redirectGraph = """
    <svg xmlns="http://www.w3.org/2000/svg" width="600" height="150" viewBox="0 0 600 150">
    <rect width="600" height="150" rx="8" fill="#0C0D0F"/>
    <g font-family="Menlo, monospace" font-size="12" fill="#CFD3D8">
    <rect x="20" y="30" width="180" height="34" rx="5" fill="#1D2024" stroke="#373C43"/>
    <text x="34" y="52">guides/setup#install</text>
    <rect x="20" y="88" width="180" height="34" rx="5" fill="#1D2024" stroke="#373C43"/>
    <text x="34" y="110">guides/upgrade#v9</text>
    <rect x="370" y="30" width="210" height="34" rx="5" fill="#1D2024" stroke="#72D699"/>
    <text x="384" y="52">get-started/setup#install</text>
    <rect x="370" y="88" width="210" height="34" rx="5" fill="#1D2024" stroke="#F97770"/>
    <text x="384" y="110">upgrade (no #v9)</text>
    </g>
    <g stroke-width="2" fill="none"><path d="M200 47 H362" stroke="#72D699"/><path d="M200 105 H362" stroke="#F97770"
    stroke-dasharray="5 4"/></g>
    <g font-family="-apple-system, Helvetica" font-size="11" fill="#848B93">
    <text x="268" y="40">kept</text><text x="218" y="98">missing: fails the build</text></g>
    </svg>
    """
}
