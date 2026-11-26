import Foundation
@testable import HeedCore
import Testing

/// Found by running Browse's Fix on a pull request against real GitHub: `gh pr view --json authorAssociation` does not
/// exist (gh 2.96: `Unknown JSON field`), so every trust check ("who opened it") and every review helper's read of a PR
/// failed. The facts now come from the REST pull request.
@Suite(.scratch)
struct PullFactsTests {
    private let ref = PullRef(repo: Repo(org: "acme", name: "docs"), number: 156)

    /// A gh that records what it was asked and answers with `answer`.
    private func fakeGh(answering answer: String) throws -> (path: String, asked: () throws -> [String]) {
        let dir = try Scratch.folder("heed-pull-facts-gh")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(dir.path)/args'
        printf '%s' '\(answer)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, {
            try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        })
    }

    @Test func theAuthorIsReadFromTheRestPullRequestNotFromGhPrView() async throws {
        let gh =
            try fakeGh(
                answering: #"{"author":{"login":"ann","is_bot":false},"authorAssociation":"CONTRIBUTOR","isCrossRepository":true}"#
            )
        let authorship = try await GitHub.$executable.withValue(gh.path) {
            try await GitHub.pullAuthorship(ref, caller: "test")
        }
        #expect(authorship == PullAuthorship(author: "ann", association: "CONTRIBUTOR", crossRepository: true))
        let args = try gh.asked()
        #expect(args.starts(with: ["api", "repos/acme/docs/pulls/156", "--jq"]))
        #expect(!args.contains("pr"), "gh pr view has no authorAssociation field")
        #expect(!args.contains { $0.contains("authorAssociation,") || $0 == "--json" })
    }

    @Test func aReviewHelpersReadOfAPullRequestAsksTheSameWay() async throws {
        let gh =
            try fakeGh(
                answering: #"{"headRefName":"fix","baseRefName":"main","title":"T","body":"B","author":{"login":"ann","is_bot":false},"authorAssociation":"MEMBER","isCrossRepository":false}"#
            )
        let read = try await GitHub.$executable.withValue(gh.path) {
            try await GitHub.pullForReview(ref, caller: "test")
        }
        #expect(read.head == "fix" && read.base == "main")
        #expect(read.authorship?.association == "MEMBER")
        let args = try gh.asked()
        #expect(args.starts(with: ["api", "repos/acme/docs/pulls/156", "--jq"]))
        #expect(!args.contains("--json"))
    }

    /// The jq that reshapes the REST pull request, run by the real jq on what GitHub sends: a fork, a bot, a PR from a
    /// deleted fork (no head repo) and a branch in the same repo.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func theJqShapesWhatGitHubSends() throws {
        let jq = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq") ? "/opt/homebrew/bin/jq" : "/usr/bin/jq"
        func shaped(_ rest: String) throws -> PullAuthorship? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: jq)
            process.arguments = ["-c", "{\(PullAuthorship.restFields)}"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(rest.utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return PullAuthorship.parse(String(decoding: data, as: UTF8.self))
        }
        let base = #""base":{"repo":{"full_name":"acme/docs"}}"#
        let fork =
            try shaped(
                #"{"user":{"login":"ann","type":"User"},"author_association":"CONTRIBUTOR","head":{"repo":{"full_name":"ann/docs"}},\#(base)}"#
            )
        #expect(fork == PullAuthorship(author: "ann", association: "CONTRIBUTOR", crossRepository: true))
        let same =
            try shaped(
                #"{"user":{"login":"bo","type":"User"},"author_association":"MEMBER","head":{"repo":{"full_name":"acme/docs"}},\#(base)}"#
            )
        #expect(same == PullAuthorship(author: "bo", association: "MEMBER", crossRepository: false))
        let bot =
            try shaped(
                #"{"user":{"login":"dependabot[bot]","type":"Bot"},"author_association":"NONE","head":{"repo":{"full_name":"acme/docs"}},\#(base)}"#
            )
        #expect(bot?.isBot == true)
        let gone =
            try shaped(
                #"{"user":{"login":"cy","type":"User"},"author_association":"NONE","head":{"repo":null},\#(base)}"#
            )
        #expect(gone?.crossRepository == true, "a PR from a deleted fork is not from this repo")
    }
}
