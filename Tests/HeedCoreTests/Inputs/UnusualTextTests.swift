import Foundation
@testable import HeedCore
import Testing

/// Other people's text (`Fixtures/inputs/text.json`) through every form it leaves heed in: the UI, a prompt, a
/// terminal, a command line, a branch name, and the self-review that reads a model's answer about it.
struct UnusualTextTests {
    /// In a prompt it is one fence, named for its author, its trust and its source, that its content cannot close.
    @Test(arguments: TextCase.all) func staysInsideOneFence(_ input: TextCase) throws {
        let text = input.external
        let nonce = input.nonce ?? "n7f3a1c0"
        let rendered = Prompt(text).rendered(nonce: nonce)
        let login = try #require(text.author.login)
        let header = "<external author=\"@\(Prompt.name(login))\" trust=\"\(text.author.trust.rawValue)\" "
            + "source=\"\(text.source.rawValue)\" id=\"\(nonce)\">"
        // The attributes are the four heed writes, each quoted once.
        #expect(header.count(where: { $0 == "\"" }) == 8)
        #expect(rendered.hasPrefix(Prompt.notice + "\n\n" + header))
        #expect(rendered.hasSuffix("</external \(nonce)>"))
        #expect(UnusualInputs.tags(in: rendered) == (1, 1))
        // Cut by scalars, so a combining mark at the content's start does not join the header's `>`.
        let scalars = Array(rendered.unicodeScalars)
        let start = (Prompt.notice + "\n\n" + header).unicodeScalars.count
        let end = scalars.count - "</external \(nonce)>".unicodeScalars.count
        let body = String(String.UnicodeScalarView(scalars[start ..< max(start, end)]))
        #expect(UnusualInputs.tags(in: body) == (0, 0))
        // Only the tags changed: the content is what the UI shows.
        #expect(body.replacingOccurrences(of: "‹", with: "<") == text.display.replacingOccurrences(of: "‹", with: "<"))
        // With a fresh id, the same.
        let fresh = Prompt(text).text
        #expect(UnusualInputs.tags(in: fresh) == (1, 1))
        let id = try #require(fresh.firstMatch(of: /id="([0-9a-f]{8})">/)?.1)
        #expect(fresh.hasSuffix("</external \(id)>"))
    }

    /// Next to heed's own words it is still one fence of its own, and the words around it stay outside.
    @Test(arguments: TextCase.all) func heedsWordsStayOutside(_ input: TextCase) {
        let prompt: Prompt = "Address this comment: \(input.external)\nThen run the tests."
        let rendered = prompt.rendered(nonce: "0badf00d")
        #expect(UnusualInputs.tags(in: rendered) == (1, 1))
        #expect(rendered.hasSuffix("</external 0badf00d>\nThen run the tests."))
        #expect(rendered.contains("\n\nAddress this comment: <external author="))
    }

    /// The UI shows no escapes, controls, bidi or invisible characters, and what is text stays as it was.
    @Test(arguments: TextCase.all) func displayShowsOnlyText(_ input: TextCase) {
        let text = input.external
        #expect(UnusualInputs.hidden(in: text.display) == [])
        #expect(!text.display.contains("\u{1B}") && !text.display.contains("\r"))
        for line in text.lines {
            #expect(!line.display.contains("\n"))
        }
        #expect(!text.oneLine.display.contains("\n"))
        #expect(UnusualInputs.hidden(in: text.firstLine(limit: 80).display) == [])
        for piece in input.drop ?? [] {
            #expect(!text.display.contains(piece), "\(piece)")
            #expect(!Prompt(text).text.contains(piece), "\(piece)")
        }
        for piece in input.keep ?? [] {
            #expect(text.display.contains(piece), "\(piece.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(Prompt(text).text.contains(piece))
        }
    }

    /// Typed into a terminal, neither it nor your own words around it carry a control character.
    @Test(arguments: TextCase.all) func typedFormHasNoControls(_ input: TextCase) {
        let prompts: [Prompt] = [
            "\(owner: "Fix this:")\n\(input.external)",
            .owner(input.full),
            "Branch \(name: input.full)",
        ]
        for prompt in prompts {
            #expect(UnusualInputs.hidden(in: prompt.typed) == [])
        }
    }

    /// On a command line a prompt is never read as an option, whatever it starts with.
    @Test(arguments: TextCase.all) func neverAnOption(_ input: TextCase) throws {
        let prompts: [Prompt] = [.owner(input.full), "\(name: input.full)", Prompt(input.external)]
        for prompt in prompts where !prompt.text.isEmpty {
            #expect(!prompt.argument.hasPrefix("-"))
            for agent in ["claude", "codex"] {
                let spawn = try #require(GoalSpawnRun.headless(
                    agent: agent, command: agent, prompt: prompt, worktree: "/w", instructions: []
                ))
                let review = try #require(ReviewRun.headless(
                    agent: agent, command: agent, prompt: prompt, model: nil, worktree: "/w", folder: "/f"
                ))
                let walk = try #require(EvaluationRun.headless(
                    agent: agent, command: agent, prompt: prompt, model: nil, clone: "/w", folder: "/f"
                ))
                for words in [spawn, review, walk] {
                    let argument = agent == "claude" ? words.firstIndex(of: "-p").map { words[$0 + 1] } : words.last
                    // Your words and names render the same each time; a fence gets a fresh id.
                    if !prompt.hasExternal { #expect(argument == prompt.argument) }
                    #expect(argument?.hasPrefix("-") == false)
                }
            }
        }
    }

    /// As a branch name (start work from an issue's title) it is a name git takes as a branch, never an option.
    @Test(arguments: TextCase.all) func makesABranchGitTakes(_ input: TextCase) {
        for prefixes in [
            BranchPrefixes.default,
            BranchPrefixes(prefixes: BranchPrefixes.default.prefixes, defaultPrefix: ""),
        ] {
            let branch = StartWork.branchName(for: input.external.display, prefixes: prefixes)
            #expect(!branch.isEmpty)
            #expect(!branch.hasPrefix("-"), "\(branch)")
            #expect(!branch.contains(".."), "\(branch)")
            #expect(!branch.contains("//") && !branch.hasSuffix("/") && !branch.hasPrefix("/"), "\(branch)")
            #expect(!branch.hasSuffix(".") && !branch.hasSuffix(".lock") && !branch.contains("@{"), "\(branch)")
            #expect(!branch.contains { $0.isWhitespace || "~^:?*[\\".contains($0) }, "\(branch)")
            #expect(UnusualInputs.hidden(in: branch) == [], "\(branch)")
            #expect(branch.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") })
        }
    }

    /// The self-review reads only the first line of the model's answer: a model that repeats the PR's title, body and
    /// diff (all this text) back does not approve it, and a real verdict still reads as one.
    @Test(arguments: TextCase.all) func selfReviewIsNotTakenInByThePR(_ input: TextCase) {
        let at = Date(timeIntervalSince1970: 0)
        let detail = PullDetail(
            ref: PullRef(repo: Repo(org: "globex", name: "heed"), number: 7), title: input.full, body: input.full,
            author: input.login ?? "drive-by", baseBranch: "main", headBranch: "b", additions: 1, deletions: 1,
            commitCount: 1, headSHA: "abc", reviews: [], threads: [], failingChecks: [], checks: CheckSummary(),
            closes: [], fetchedAt: at, authorTrust: input.author.trust
        )
        let prompt = SelfReview.prompt(detail, diff: input.full)
        // Title, body and diff: three fences, each the author's.
        let rendered = prompt.rendered(nonce: "5e1f0000")
        #expect(UnusualInputs.tags(in: rendered) == (3, 3))
        #expect(rendered.components(separatedBy: "trust=\"\(input.author.trust.rawValue)\"").count == 4)
        let display = input.external.display
        for echo in [prompt.text, "\n  \n" + prompt.text, "I read the description:\n" + display, rendered] {
            let review = SelfReview.parse(echo, sha: "abc", at: at)
            #expect(!review.approved)
        }
        let refused = SelfReview.parse("REQUEST_CHANGES: no tests\n" + display, sha: "abc", at: at)
        #expect(!refused.approved && refused.summary == "no tests")
        #expect(SelfReview.parse("APPROVE\n" + prompt.text, sha: "abc", at: at).approved)
    }
}
