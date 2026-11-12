import HeedCore
import SwiftUI

// Settings › Machine: Hosts, Tools, Keys & modes.

/// Settings › Hosts: the machines in `[hosts.<name>]`, as config.toml has them, one card each. Adding and checking one
/// is gH's (it reads ~/.ssh/config and your tailnet); editing one is the file's, and ↺ removes a key set there.
struct HostsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hosts = model.config.hosts.values.sorted { $0.name < $1.name }
        HStack(spacing: 12) {
            Button("Add or check hosts (gH)") {
                model.activateHeed()
                model.perform(CommandInvocation(name: "host.open"))
            }
            Button("Edit in config.toml") { NSWorkspace.shared.open(model.configFile) }
        }
        if hosts.isEmpty {
            Text("No hosts yet. gH lists the ones in ~/.ssh/config and on your tailnet to add.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
        }
        ForEach(hosts, id: \.name) { host in
            let target = SettingTarget.host(host.name)
            SettingsCard(title: "@\(host.name)") {
                SettingRow("host.ssh", target: target) { value(host.ssh) }
                SettingRow("host.transport", target: target, defaultText: "the tailnet when the machine is on it") {
                    value(host.transport?.rawValue ?? "unset")
                }
                SettingRow("host.tailscale", target: target, defaultText: "the host's name") {
                    value(host.tailscale ?? "unset")
                }
                SettingRow("host.user", target: target, defaultText: "the tailnet's") { value(host.user ?? "unset") }
                SettingRow("host.repo_roots", target: target) { value(host.repoRoots.joined(separator: ", ")) }
                SettingRow("host.worktree_root", target: target) { value(host.worktreeRoot) }
                SettingRow("host.color", target: target, defaultText: "picked from the name") {
                    value(host.color ?? "unset")
                }
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(text == "unset" ? Theme.fg3 : Theme.fg).textSelection(.enabled)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
    }
}

/// Settings › Tools: what heed found (git, gh and the rest), and where to look for them instead.
struct ToolsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tools = model.config.tools
        SettingsCard(title: "Found", bare: true) {
            ToolsList(report: model.tools).padding(14).settingsCard()
        }
        SettingsCard(title: "Tools") {
            SettingRow("tools.git", defaultText: "detected") {
                ConfigTextField(path: ["tools", "git"], value: tools.git, placeholder: "detected", width: 220)
            }
            SettingRow("tools.gh", defaultText: "detected") {
                ConfigTextField(path: ["tools", "gh"], value: tools.gh, placeholder: "detected", width: 220)
            }
            SettingRow("tools.zmx", defaultText: "detected", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigTextField(path: ["tools", "zmx"], value: tools.zmx, placeholder: "detected", width: 220)
                    ZmxStatus(health: model.zmxHealth, setting: model.settings.persist)
                }
            }
            SettingRow("tools.tailscale", defaultText: "detected", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigTextField(
                        path: ["tools", "tailscale"], value: tools.tailscale, placeholder: "detected", width: 220
                    )
                    TailscaleStatusLine(path: model.tailscalePath, tailnet: model.tailnet)
                }
            }
            SettingRow("tools.path", defaultText: "none") {
                ListField(path: ["tools", "path"], values: tools.path, width: 220)
            }
        }
    }
}

/// Settings › Keys & modes: the INSERT escape, the two global shortcuts, and every binding as it stands. Bindings
/// are edited in config.toml.
struct KeysPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keymap = model.engine.keymaps[.normal] ?? Keymap()
        SettingsCard(title: "Modes") {
            SettingRow("keys.insert_escape") {
                HStack(spacing: 10) {
                    KeyCap(text: KeyCapText.of(model.config.insertEscape))
                    EditInConfigButton(title: "Change in config.toml")
                }
            }
        }
        SettingsCard(
            title: "Global shortcuts",
            note: "They work from any app. One key with ⌃, ⌥ or ⌘; Record takes the next one you press, ⎋ cancels. "
                + "Empty turns one off."
        ) {
            SettingRow("keys.global_start_work", defaultText: "off", stacked: true) {
                ShortcutField(
                    path: ["keys", "global_start_work"], value: model.config.globalStartWork,
                    other: model.config.globalActivate
                )
            }
            SettingRow("keys.global_activate", defaultText: "off", stacked: true) {
                ShortcutField(
                    path: ["keys", "global_activate"], value: model.config.globalActivate,
                    other: model.config.globalStartWork
                )
            }
        }
        SettingsCard(title: "Bindings") {
            SettingRow("keys.bindings", label: "Your bindings", defaultText: "heed's own") {
                EditInConfigButton(title: "Edit bindings in config.toml")
            }
            InfoRow(
                label: "NORMAL",
                detail: "Every binding as it stands; : completes the same command names.",
                stacked: true
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(keymap.bindings.enumerated()), id: \.offset) { _, binding in
                        HStack(spacing: 12) {
                            Text(KeyCapText.of(binding.keys)).font(Theme.mono(12))
                                .frame(width: 90, alignment: .leading)
                            Text(binding.command).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                                .frame(width: 200, alignment: .leading)
                            Text(Commands.spec(CommandInvocation(parsing: binding.command).name)?.summary ?? "")
                                .font(Theme.ui(12))
                                .foregroundStyle(Theme.fg3)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

/// zmx's check, under its field: where it is, its version, whether it works, and what panes do because of it.
private struct ZmxStatus: View {
    let health: ZmxHealth?
    let setting: PanePersistence

    var body: some View {
        let effective = ZmxHealth.decide(setting, health: health)
        VStack(alignment: .leading, spacing: 4) {
            if let health {
                HStack(spacing: 6) {
                    Image(systemName: health.works ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                    if let path = health.path {
                        Text(Paths.abbreviate(path)).font(Theme.mono(11.5))
                        if let version = health.version { Text(version).foregroundStyle(Theme.fg3) }
                    }
                    Text(health.works ? "works" : health.problem ?? "")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                }
                Text(effective == .zmx
                    ? "Panes run in zmx: agents outlive heed."
                    : setting == .none ? "Off: panes end when heed quits." : "Panes are plain shells until zmx works.")
                    .foregroundStyle(Theme.fg3)
                if health.path == nil {
                    Text("Install: " + ZmxInstall.mac.joined(separator: "; ")).font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not checked yet.").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }
}

/// Tailscale's check, under its field: where the CLI is, and whether your tailnet is up.
private struct TailscaleStatusLine: View {
    let path: String?
    let tailnet: Tailnet?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tailnet {
                let (ok, text) = summary(tailnet)
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Theme.done : Theme.block)
                    if let path { Text(Paths.abbreviate(path)).font(Theme.mono(11.5)) }
                    Text(text).foregroundStyle(ok ? Theme.done : Theme.block)
                }
                if tailnet.state == .notInstalled {
                    Text("Optional. Install: " + TailscaleCLI.install.joined(separator: " ")).font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not checked yet.").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }

    private func summary(_ tailnet: Tailnet) -> (Bool, String) {
        switch tailnet.state {
        case .running:
            (true, "on \(tailnet.name ?? "your tailnet") · \(tailnet.machines.count) machines")
        case .notInstalled: (false, "not installed")
        case .off, .starting: (false, "Tailscale is off")
        case .needsLogin: (false, "signed out")
        }
    }
}

/// A system-wide shortcut: typed in vim notation, or recorded from the next key pressed. Checked before it is
/// written, so a shortcut that cannot work never reaches config.toml.
private struct ShortcutField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    /// The other global shortcut, which this one may not repeat.
    let other: String
    @State private var text = ""
    @State private var problem: String?
    @State private var recording = false
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("off", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12.5))
                    .frame(width: 150)
                    .focused($focused)
                    .onAppear { text = value }
                    .onChange(of: value) { if !focused, !recording { text = value } }
                    .onSubmit { save(text) }
                    .onChange(of: focused) { if !focused, !recording { save(text) } }
                if !value.isEmpty { KeyCap(text: KeyCapText.of(value)) }
                Button(recording ? "Press a key…" : "Record") { recording ? stop() : record() }
                Button("Off") { save("") }
                    .buttonStyle(.link)
                    .font(Theme.ui(12))
                    .disabled(value.isEmpty)
            }
            FieldNoteView(note: problem.map { FieldNote("value", $0) })
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let stroke = KeyStroke(event: event) else { return nil }
            MainActor.assumeIsolated {
                if stroke == .escape {
                    stop()
                } else {
                    text = stroke.description
                    stop()
                    save(text)
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func save(_ notation: String) {
        let notation = notation.trimmingCharacters(in: .whitespaces)
        if let problem = GlobalShortcut.problem(notation, other: other) {
            self.problem = problem
            return
        }
        problem = nil
        text = notation
        guard notation != value else { return }
        model.setConfig(path, .string(notation))
    }
}
