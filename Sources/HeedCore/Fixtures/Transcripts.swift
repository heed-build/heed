import Foundation

/// What the fixture panes show in screenshots (shot mode draws these instead of starting a shell), keyed by pane id.
/// Markup: `{dim}`, `{bold}`, `{green}`, `{blue}`, `{amber}`, `{red}`, `{violet}` start a style, `{/}` ends it.
public extension Fixtures {
    static let transcripts: [String: String] = [
        "s1-agent": """
        {bold}claude{/} {dim}· fix-anchors-redirects{/}

        {bold}>{/} Fix broken anchors in redirects.yml.
          Every target must hit a heading.

        {violet}●{/} Making anchor lookups slug-aware,
          then adding moved-page fixtures.

        {green}●{/} {bold}Update{/}(RedirectFile.cs)
          {dim}⎿ 4 additions, 2 removals{/}

        {green}●{/} {bold}Write{/}(moved-page.yml)
          {dim}⎿ Wrote 18 lines{/}

        {blue}●{/} {bold}Bash{/}(dotnet test)
          {dim}⎿ 212 passed, 0 failed so far{/}

        {amber}✻ Running tests… (14m · esc){/}
        """,
        "s1-shell": """
        {green}you@mac{/} {blue}fix-anchors{/} % git status -s
         M src/…/RedirectFile.cs
        ?? tests/redirects/moved-page.yml
        {green}you@mac{/} {blue}fix-anchors{/} % ▌
        """,
        "s1-tests": """
        {dim}dotnet watch ⌚ Started{/}
          Passed! Failed: 0, Passed: 212
        {dim}dotnet watch ⌚ Waiting for changes{/}
        """,
        "s2-agent": """
        {bold}>{/} Add a cross-link validator for
          assembled docs.

        {green}●{/} {bold}Write{/}(CrossLinks/Validator.cs)
          {dim}⎿ Wrote 96 lines{/}

        {amber}Bash command{/}
          dotnet publish -c Release
          src/docs-assembler

        {bold}Do you want to proceed?{/}
        {amber}❯ 1. Yes{/}
          2. Yes, don't ask again for this
          3. No, tell Claude what to do
        """,
        "s3-agent": """
        {bold}codex{/} {dim}· ingest-backpressure{/}

        Three questions before I change
        the stage:

          {violet}1.{/} Block producers when the buffer
             is full, or drop the oldest?
          {violet}2.{/} Is 10k events a good default?
          {violet}3.{/} Add a metric for time blocked?

        {dim}› answer, or press enter to let me choose{/}
        """,
        "s4-agent": """
        {bold}>{/} Arrowheads detach at small zoom.

        {green}●{/} {bold}Read{/}(Sequence/Arrow.cs)
        {green}●{/} {bold}Update{/}(Sequence/Arrow.cs)
          {dim}⎿ 7 additions, 3 removals{/}

        {amber}✻ Editing… (3m · esc to interrupt){/}
        """,
        "s5-agent": """
        {green}●{/} PR #412 is approved and checks
          pass. Nothing left to do.

        {dim}Total cost: $0.42 · 18 turns{/}
        """,
        "s6-agent": """
        {bold}opencode{/} {dim}· docs-nav-spike{/}

        {dim}idle · waiting for your next prompt{/}
        """,
    ]

    /// A pane without a transcript: a quiet prompt in its directory.
    static func prompt(for pane: PaneSpec) -> String {
        let folder = (pane.directory as NSString).lastPathComponent
        return "{green}you@mac{/} {blue}\(folder){/} % ▌"
    }
}
