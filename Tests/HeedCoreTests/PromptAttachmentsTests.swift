import Foundation
@testable import HeedCore
import Testing

/// Big pastes stay beside the prompt as files; linked PRs and issues show as chips and name the branch.
struct PromptAttachmentsTests {
    private let records = ["docs-builder"].map {
        RepoRecord(repo: Repo(org: "acme", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private let log = (1 ... 40).map { "2026-11-12T10:\(String(format: "%02d", $0)):00Z INFO step \($0)" }
        .joined(separator: "\n")

    @Test func aPasteIsLargeByLinesOrLength() {
        #expect(!PromptAttachments.isLarge("one line"))
        #expect(PromptAttachments.isLarge(Array(repeating: "x", count: 25).joined(separator: "\n")))
        #expect(PromptAttachments.isLarge(String(repeating: "x", count: 2500)))
    }

    @Test func kindsAreReadFromTheLines() {
        #expect(PromptAttachments.kind(of: log) == .log)
        #expect(PromptAttachments.kind(of: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b") == .diff)
        #expect(PromptAttachments.kind(of: #"{"a": [1, 2], "b": {"c": true}}"#) == .json)
        #expect(PromptAttachments.kind(of: """
        Traceback (most recent call last):
          File "x.py", line 3, in <module>
          File "y.py", line 9, in run
        ValueError: nope
        """) == .trace)
        #expect(PromptAttachments.kind(of: "just some notes\nabout the task\nand more") == .text)
    }

    @Test func theAgentIsToldWhereTheFilesAreOrGetsTheTextOnAHost() {
        let attachment = PromptAttachment(id: 1, text: log)
        let filed = PromptAttachments.prompt("fix the build", attachments: [(attachment, "/tmp/s/paste-1.log")])
        #expect(filed == "fix the build\n\nAttached, read these files:\n- /tmp/s/paste-1.log (log, 40 lines)")
        let inline = PromptAttachments.prompt("fix the build", attachments: [(attachment, nil)])
        #expect(inline.hasPrefix("fix the build\n\nAttached log:\n```\n2026-11-12T10:01:00Z"))
        #expect(PromptAttachments.prompt("as typed", attachments: []) == "as typed")
        #expect(attachment.fileName == "paste-1.log")
    }

    @Test func aBigPasteBecomesAnAttachmentAndASmallOneIsTyped() {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix the build")
        form.paste(log)
        #expect(form.prompt == "fix the build")
        #expect(form.attachments.count == 1)
        #expect(form.attachments.first?.kind == .log)
        #expect(form.plan.attachments.count == 1)
        form.paste(" now")
        #expect(form.prompt == "fix the build now")
        #expect(form.attachments.count == 1)
    }

    @Test func xDropsTheChipAndPPutsItBack() {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix the build")
        form.paste(log)
        form.paste(log)
        _ = form.handle(.escape)
        #expect(form.field == .prompt)
        _ = form.handle(KeyStroke("h"))
        #expect(form.attachmentCursor == 0)
        _ = form.handle(KeyStroke("x"))
        #expect(form.attachments.map(\.id) == [2])
        _ = form.handle(KeyStroke("P"))
        #expect(form.attachments.isEmpty)
        #expect(form.prompt.hasPrefix("fix the build\n\n2026-11-12T10:01:00Z"))
    }

    @Test func linksInThePromptAreFoundOnceEach() {
        let text = """
        see https://github.com/acme/docs-builder/pull/12 and https://github.com/acme/docs-builder/issues/7, \
        again https://github.com/acme/docs-builder/pull/12
        """
        let links = PromptLink.links(in: text)
        #expect(links.map(\.label) == ["acme/docs-builder#12", "acme/docs-builder#7"])
        #expect(links.first?.ref.isPull == true)
        #expect(links.last?.ref.isPull == false)
    }

    @Test func aLinkedTitleNamesTheBranchAndSaysTheKind() {
        var form = StartWorkForm(
            repos: records, settings: .default, prompt: "look at https://github.com/acme/docs-builder/issues/7 please"
        )
        #expect(form.name == "feature/look")
        form.setLinkTitles(["https://github.com/acme/docs-builder/issues/7": "Fix redirects for moved pages"])
        #expect(form.name == "fix/redirects-moved-pages")
        #expect(form.kind == .fix)
    }
}
