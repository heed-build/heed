import Foundation

/// How git signs the commits of a Browse run's worktree, when it does (`commit.gpgsign`), and whether the run's
/// environment can do it. A Fix that cannot sign fails at `git commit` with a passphrase prompt, and a model then
/// reaches for `--no-verify` or `-c commit.gpgsign=false`, which heed refuses: so the run is told, before its first
/// commit, that commits are signed by the user's agent and what to do when signing fails.
public struct CommitSigning: Equatable, Sendable {
    public enum Format: String, Sendable { case ssh, openpgp, x509 }

    public var format: Format
    /// What the run's environment keeps for it: the ssh agent's socket for `ssh`, the gpg home for the others.
    public var available: Bool

    public init(format: Format, available: Bool) {
        self.format = format
        self.available = available
    }

    /// `gpgsign` and `format` are the values of `commit.gpgsign` and `gpg.format` (nil when unset); `parent` is the
    /// environment heed itself runs in. Nil when commits are not signed.
    public static func parse(gpgsign: String?, format: String?, parent: [String: String]) -> CommitSigning? {
        let on = ["true", "yes", "on", "1"]
        guard let gpgsign, on.contains(gpgsign.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return nil }
        let kind = Format(rawValue: (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? .openpgp
        switch kind {
        case .ssh: return CommitSigning(format: .ssh, available: !(parent["SSH_AUTH_SOCK"] ?? "").isEmpty)
        case .openpgp, .x509: return CommitSigning(format: kind, available: true)
        }
    }

    /// Reads the worktree's git config (`HOME` and the repository's own, as `git commit` will).
    public static func detect(in worktree: String, parent: [String: String]) async -> CommitSigning? {
        func value(_ key: String) async -> String? {
            let result = try? await ProcessRunner.run(
                "git", ["-C", worktree, "config", "--get", key], caller: "browse.signing"
            )
            return result?.succeeded == true ? result?.stdout : nil
        }
        return await parse(gpgsign: value("commit.gpgsign"), format: value("gpg.format"), parent: parent)
    }

    /// What the run's agent is told when the worktree signs commits.
    public var prompt: Prompt {
        switch (format, available) {
        case (.ssh, true):
            "Commits here are signed by the user's ssh agent, which heed has given you: `git commit -m 'message'` signs "
                + "them as usual. Do not use `--no-verify` or `-c commit.gpgsign=false`: heed refuses both. If a "
                + "commit still fails on signing, say so in your final message and stop."
        case (.ssh, false):
            "Commits here are signed with an ssh key, and this run has no ssh agent (commit signing needs one and it "
                + "is not available in this run): a `git commit` will fail on signing. Make the change and say so "
                + "in your final message. Do not use `--no-verify` or `-c commit.gpgsign=false`: heed refuses both."
        case (_, _):
            "Commits here are signed with gpg: `git commit -m 'message'` signs them as usual when gpg-agent has the key "
                + "unlocked. Do not use `--no-verify` or `-c commit.gpgsign=false`: heed refuses both. If a commit "
                + "fails on signing (gpg needs a passphrase prompt a run cannot answer), say so in your final message "
                + "and stop."
        }
    }

    /// Whether a failed command's output is git failing to sign.
    public static func failed(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["enter passphrase", "incorrect passphrase", "failed to write commit object", "gpg failed to sign",
                "failed to sign the data", "couldn't load public key", "agent refused operation",
                "error: gpg", "no secret key", "signing failed", "sign_and_send_pubkey", "pinentry"]
            .contains { text.contains($0) }
    }

    /// The failure card's words for a commit that could not be signed.
    public var unavailable: String {
        switch format {
        case .ssh: "commit signing needs your ssh agent (SSH_AUTH_SOCK) and it is not available in this run"
        case .openpgp, .x509: "commit signing needs gpg-agent to have your key unlocked and it is not available in this run"
        }
    }
}
