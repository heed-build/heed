import Foundation

/// Whether a pane's terminal outlives heed.
public enum PanePersistence: String, CaseIterable, Sendable, Codable {
    /// The terminal is heed's: it ends when heed quits, and a relaunch resumes the agent from its own history.
    case none
    /// The terminal runs in a zmx session (https://zmx.sh) that heed attaches to: quitting, restarting or updating heed
    /// leaves the agent running, and heed reattaches to it, screen and scrollback as they were.
    case zmx
}

/// heed's use of zmx: one zmx session per pane, named after it, in a socket directory of heed's own so they stay
/// apart from sessions you run yourself.
public enum Zmx {
    public static let prefix = "heed-"

    public static func sessionName(pane: String) -> String { prefix + pane }

    /// The pane a session belongs to, if it is one of heed's.
    public static func pane(ofSession name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    /// `~/Library/Application Support/Heed/zmx`.
    public static func socketDirectory() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/zmx").path
    }

    /// What every zmx call needs: heed's socket directory, and no detach key (`⌃\` is heed's own INSERT escape).
    public static func environment(socketDirectory: String) -> [String: String] {
        ["ZMX_DIR": socketDirectory, "ZMX_NO_DETACH_KEY": "1"]
    }

    /// The command a pane's terminal runs: attach to its session, creating it (with your login shell) when it is not
    /// there.
    public static func attachCommand(zmx: String, pane: String) -> String {
        "\(ShellQuote.quote(zmx)) attach \(sessionName(pane: pane))"
    }

    /// The panes with a live session, from `zmx list --short`.
    public static func livePanes(fromList output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { pane(ofSession: String($0)) })
    }

    /// Lists heed's live sessions; empty when zmx cannot be run.
    public static func livePanes(zmx: String, socketDirectory: String) async -> Set<String> {
        guard let result = try? await ProcessRunner.run(
            zmx, ["list", "--short"], environment: environment(socketDirectory: socketDirectory), timeout: .seconds(5)
        ), result.succeeded else { return [] }
        return livePanes(fromList: result.stdout)
    }

    /// Ends panes' sessions (and what runs in them). Ones already gone are fine.
    public static func kill(panes: [String], zmx: String, socketDirectory: String) async {
        guard !panes.isEmpty else { return }
        _ = try? await ProcessRunner.run(
            zmx, ["kill"] + panes.map(sessionName(pane:)), environment: environment(socketDirectory: socketDirectory),
            timeout: .seconds(10)
        )
    }
}

/// How to install zmx (https://zmx.sh), told to you rather than done for you: heed ships no copy of it.
public enum ZmxInstall {
    /// The release heed is tested with, for the tarball line.
    public static let testedVersion = "0.8.1"
    public static let site = "https://zmx.sh"

    /// Lines to run for a machine: `uname -sm` (`Linux x86_64`, `Darwin arm64`) and, on Linux, its os-release ID.
    public static func commands(platform: String, os: String? = nil) -> [String] {
        let words = platform.lowercased().split(separator: " ").map(String.init)
        if words.first == "darwin" { return ["brew install neurosnap/tap/zmx"] }
        if os == "nixos" { return ["nix profile install nixpkgs#zmx"] }
        let arch = switch words.last {
        case "x86_64", "amd64": "x86_64"
        case "aarch64", "arm64": "aarch64"
        default: ""
        }
        guard words.first == "linux", !arch.isEmpty else { return [] }
        return [
            "mkdir -p ~/.local/bin && curl -fsSL \(site)/a/zmx-\(testedVersion)-linux-\(arch).tar.gz | tar -xz -C ~/.local/bin zmx",
        ]
    }

    /// For this Mac.
    public static let mac = commands(platform: "Darwin arm64")
}
