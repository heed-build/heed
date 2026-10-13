import HeedCore
import SwiftUI

/// While a key sequence is pending (`g`, `<C-w>`, `'`, `]`), lists every key that can follow and what it does.
struct LeaderHints: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        panel.shotRegion(.leaderHints)
    }

    @ViewBuilder private var panel: some View {
        let entries = model.engine.continuations
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    KeyCap(text: (model.engine.count.map(String.init) ?? "") + KeyCapText.of(model.engine.pending))
                    Text("then").foregroundStyle(Theme.fg3)
                    Spacer()
                    KeyCap(text: "⎋")
                    Text("cancel").foregroundStyle(Theme.fg3)
                }
                .font(Theme.ui(12))
                FlowLayout(spacing: 22, lineSpacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Text(KeyCapText.of(entry.rest))
                                .font(Theme.mono(12.5, weight: .semibold))
                                .foregroundStyle(Theme.modeColor(.hint))
                                .frame(minWidth: 22, alignment: .leading)
                            Text(Self.describe(entry.command))
                                .font(Theme.ui(12.5))
                                .foregroundStyle(Theme.fg2)
                                .lineLimit(1)
                        }
                        .frame(width: 250, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// "jump to pinned session 3", "switch view: inbox", or the command's summary.
    static func describe(_ line: String) -> String {
        let invocation = CommandInvocation(parsing: line)
        let summary = Commands.spec(invocation.name)?.summary ?? invocation.name
        return invocation.arguments.isEmpty ? summary : "\(summary) \(invocation.arguments.joined(separator: " "))"
    }
}
