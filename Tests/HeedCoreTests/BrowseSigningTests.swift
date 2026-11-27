import Foundation
@testable import HeedCore
import Testing

/// Commit signing in a Browse run: which run keeps the ssh agent, and what a run is told about it.
struct BrowseSigningTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var verb: BrowseVerb?
        var trusted: Bool
        var kept: Bool
        var testDescription: String { "\(verb?.rawValue ?? "no verb") trusted=\(trusted) keeps=\(kept)" }
    }

    /// Only a trusted run that writes keeps the signing variables; a Chat, a Review, an untrusted run and a call with
    /// no verb never do.
    static let table: [Case] = [
        Case(verb: .fix, trusted: true, kept: true),
        Case(verb: .implement, trusted: true, kept: true),
        Case(verb: .fix, trusted: false, kept: false),
        Case(verb: .implement, trusted: false, kept: false),
        Case(verb: .chat, trusted: true, kept: false),
        Case(verb: .chat, trusted: false, kept: false),
        Case(verb: .review, trusted: true, kept: false),
        Case(verb: .review, trusted: false, kept: false),
        Case(verb: nil, trusted: true, kept: false),
        Case(verb: nil, trusted: false, kept: false),
    ]

    @Test(arguments: table)
    func onlyATrustedWriterKeepsTheSigningVariables(_ row: Case) {
        let parent = [
            "PATH": "/usr/bin", "HOME": "/Users/you", "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "GNUPGHOME": "/Users/you/.gnupg",
            "GPG_AGENT_INFO": "/tmp/gpg:1:1", "GH_TOKEN": "t", "GIT_SSH_COMMAND": "curl x",
        ]
        let environment = BrowseRunEnvironment.make(
            parent, agent: "claude", folder: "/tmp/heed-run", trusted: row.trusted, verb: row.verb, path: nil
        )
        for name in BrowseRunEnvironment.signingVariables {
            #expect((environment[name] != nil) == row.kept, "\(name) \(row.testDescription)")
        }
        if row.kept { #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock") }
        // Nothing else leaks with it.
        #expect(environment["GH_TOKEN"] == nil)
        #expect(environment["GIT_SSH_COMMAND"] == nil)
    }

    @Test func aMissingSocketIsNotInvented() {
        let environment = BrowseRunEnvironment.make(
            ["HOME": "/Users/you"], agent: "claude", folder: "/tmp/heed-run", trusted: true, verb: .fix, path: nil
        )
        #expect(environment["SSH_AUTH_SOCK"] == nil)
    }

    @Test func signingIsReadFromTheGitConfigValues() {
        let sock = ["SSH_AUTH_SOCK": "/tmp/a"]
        #expect(CommitSigning.parse(gpgsign: nil, format: "ssh", parent: sock) == nil)
        #expect(CommitSigning.parse(gpgsign: "false", format: "ssh", parent: sock) == nil)
        #expect(CommitSigning.parse(gpgsign: "true\n", format: "ssh\n", parent: sock)
            == CommitSigning(format: .ssh, available: true))
        #expect(CommitSigning.parse(gpgsign: "true", format: "ssh", parent: [:])
            == CommitSigning(format: .ssh, available: false))
        #expect(CommitSigning.parse(gpgsign: "yes", format: nil, parent: [:])
            == CommitSigning(format: .openpgp, available: true))
        #expect(CommitSigning.parse(gpgsign: "true", format: "x509", parent: [:])?.format == .x509)
    }

    @Test func theRunIsToldCommitsAreSignedAndNotToWorkAround() {
        for signing in [
            CommitSigning(format: .ssh, available: true), CommitSigning(format: .ssh, available: false),
            CommitSigning(format: .openpgp, available: true),
        ] {
            let text = signing.prompt.text
            #expect(text.contains("--no-verify") && text.contains("commit.gpgsign=false"), "\(text)")
        }
        #expect(CommitSigning(format: .ssh, available: true).prompt.text.contains("ssh agent"))
        #expect(CommitSigning(format: .ssh, available: false).prompt.text.contains("not available in this run"))
    }

    @Test func aWriterWithSigningGetsTheLineAndNobodyElseDoes() {
        let item = BrowseItem(
            repo: Repo(org: "acme", name: "docs-toolkit"), number: 1, kind: .issue,
            title: ExternalText("t", source: .issueTitle, author: .unknown), author: "me"
        )
        let place = BrowseRunPrompt.Place(
            worktree: "/w", branch: "heed/browse/issue-1-a", defaultBranch: "main",
            signing: CommitSigning(format: .ssh, available: true)
        )
        func text(_ verb: BrowseVerb) -> String {
            let run = BrowseRun(
                item: item, verb: verb, mode: .full, agent: "claude", adapter: "x", name: "issue-1-a",
                branch: "heed/browse/issue-1-a", worktree: "/w", phase: .preparing,
                startedAt: Date(timeIntervalSince1970: 2_000_000_000), cap: 0
            )
            return BrowseRunPrompt.start(run, item: item, place: place).text
        }
        #expect(text(.fix).contains("signed by the user's ssh agent"))
        #expect(text(.implement).contains("signed by the user's ssh agent"))
        #expect(!text(.chat).contains("signed by"))
        #expect(!text(.review).contains("signed by"))
    }

    @Test func aSigningFailureIsRecognised() {
        #expect(CommitSigning
            .failed("Enter passphrase for /Users/x/.ssh/id_ed25519:\nerror: incorrect passphrase supplied"))
        #expect(CommitSigning.failed("error: gpg failed to sign the data\nfatal: failed to write commit object"))
        #expect(!CommitSigning.failed("nothing to commit, working tree clean"))
    }
}
