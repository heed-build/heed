import HeedCore
import SwiftUI

/// The first launch: what Heed found and what it will (and will not) change (design/screens/FirstRun.png).
struct FirstRunView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let report = model.firstRun {
            ZStack {
                Color.black.opacity(0.6)
                ListScroll {
                    dialog(report).frame(width: 760).shotRegion(.dialog).padding(.vertical, 40)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func dialog(_ report: FirstRunReport) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Heed").font(Theme.ui(20, weight: .semibold))
                Text("Here is what it found. Everything can be changed later in Settings (⌘,) or config.toml.")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.fg2)
            }
            step("GitHub", done: report.githubUser != nil) {
                if let user = report.githubUser {
                    Text("Signed in to gh as \(user). Inbox, issues and PRs sync through gh only.")
                        .foregroundStyle(Theme.fg2)
                } else if let problem = report.githubProblem {
                    Text(problem.contains("auth login")
                        ? "\(problem). Run it in any terminal; this updates by itself."
                        : problem)
                        .foregroundStyle(Theme.block)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Asking gh…").foregroundStyle(Theme.fg3)
                }
            }
            step("Tools", done: report.tools.map { $0.tools.allSatisfy { $0.path != nil } } ?? false) {
                ToolsList(report: report.tools)
            }
            step("Repos", done: !model.repos.isEmpty) {
                Text(model.repos.isEmpty
                    ? "Scanning \(model.settings.repoRoots.joined(separator: ", "))…"
                    : "\(model.repos.count) repos found under \(model.settings.repoRoots.joined(separator: ", ")).")
                    .foregroundStyle(Theme.fg2)
            }
            step("Agents", done: report.agents.contains { $0.path != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.agents, id: \.name) { agent in
                        HStack(spacing: 12) {
                            Text(agent.name).font(Theme.mono(12.5)).frame(width: 90, alignment: .leading)
                            if let path = agent.path {
                                Text("found").foregroundStyle(Theme.done)
                                Text(Paths.abbreviate(path)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                                    .lineLimit(1)
                            } else {
                                Text("not found").foregroundStyle(Theme.fg3)
                            }
                        }
                        .font(Theme.ui(12.5))
                    }
                    if report.agents.isEmpty { Text("Looking on your PATH…").foregroundStyle(Theme.fg3) }
                    Text("""
                    Nothing in your own agent config changes. Heed passes its hooks per run (claude --settings, codex -c, \
                    pi -e, opencode's config env var); for cursor it writes .cursor/hooks.json into worktrees it creates, \
                    kept out of git.
                    """)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            step("Keys", done: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("i enters INSERT (keys go to the terminal);").foregroundStyle(Theme.fg2)
                        KeyCap(text: "⇧⎋")
                        Text("or").foregroundStyle(Theme.fg2)
                        KeyCap(text: KeyCapText.of(model.config.insertEscape))
                        Text("leaves it. ? shows every key.").foregroundStyle(Theme.fg2)
                    }
                    Text("Change the escape chord with insert_escape under [keys] in config.toml.")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
            }
            HStack {
                Text(Paths.abbreviate(model.configFile.path)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                Spacer()
                Text(model.firstRunChecking ? "checking…" : "checks again every few seconds")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg3)
                KeyCap(text: "r")
                Text("check now").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                KeyCap(text: "e")
                Text("open config").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                KeyCap(text: "t")
                Text("take the tutor").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                HStack(spacing: 6) {
                    Text("Start").fontWeight(.medium)
                    KeyCap(text: "↩")
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inverse))
            }
            .font(Theme.ui(12.5))
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private func step(_ title: String, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(done ? Theme.done : Theme.fg3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.ui(14, weight: .semibold))
                content().font(Theme.ui(12.5))
            }
        }
    }
}

/// git and gh as detected: where, which version and why that one; shared by the first run and Settings.
struct ToolsList: View {
    let report: ToolReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report {
                ForEach(report.tools, id: \.name) { tool in
                    HStack(spacing: 12) {
                        Text(tool.name).font(Theme.mono(12.5)).frame(width: 90, alignment: .leading)
                        if let path = tool.path {
                            Text(Paths.abbreviate(path)).font(Theme.mono(11.5))
                            Text([tool.version, tool.source.map { "from \($0.rawValue)" }].compactMap(\.self)
                                .joined(separator: " · "))
                                .foregroundStyle(Theme.fg3)
                                .lineLimit(1)
                        } else {
                            Text("not found").foregroundStyle(Theme.block)
                        }
                    }
                    .font(Theme.ui(12.5))
                    if let problem = tool.problem {
                        Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.block)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(report.shellPath == nil
                    ? "\(Paths.abbreviate(report.shell)) did not report its PATH; searched the usual places instead."
                    :
                    "Searched \(Paths.abbreviate(report.shell))'s PATH, then the usual places. Set [tools] in config.toml to pick another.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Looking for git and gh…").foregroundStyle(Theme.fg3)
            }
        }
    }
}
