import HeedCore
import SwiftUI

/// "Pick up where you left off" on launch (design/screens/Resume.png).
struct ResumeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let form = model.resume {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.6)
                    ScrollView {
                        dialog(form)
                            .frame(width: min(1060, max(geometry.size.width - 48, 360)))
                            .padding(.vertical, 24)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }

    private func dialog(_ form: ResumeForm) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pick up where you left off").font(Theme.ui(16, weight: .semibold))
                    Spacer()
                    Text("Auto-continue: \(model.settings.resumeOnLaunch.rawValue.capitalized) (config)")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
                Text("\(form.candidates.count) sessions were open when Heed quit. Parked ones stay closed.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg2)
            }
            .padding(22)

            ForEach(Array(form.candidates.enumerated()), id: \.element.id) { index, candidate in
                row(candidate, selected: form.selected.contains(candidate.id), focused: index == form.cursor)
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "After resuming a session that was mid-turn")
                    Text(model.settings.continuePrompt.isEmpty ? "(off)" : model.settings.continuePrompt)
                        .font(Theme.mono(12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                    Text("Sent once the agent is idle and ready.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "What comes back")
                    Text("""
                    Worktrees, tabs and split layout, and every shell in its old directory. Processes inside shells \
                    do not survive a restart, so tests and watchers need starting again.
                    """)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }

            HStack(spacing: 10) {
                KeyCap(text: "space")
                Text("toggle").foregroundStyle(Theme.fg3)
                KeyCap(text: "j k")
                Text("move").foregroundStyle(Theme.fg3)
                Spacer()
                HStack(spacing: 6) {
                    KeyCap(text: "⎋")
                    Text("Start empty")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                HStack(spacing: 6) {
                    Text("Resume \(form.selected.count) session\(form.selected.count == 1 ? "" : "s")")
                        .fontWeight(.medium)
                    KeyCap(text: "↩")
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inverse))
            }
            .font(Theme.ui(12.5))
            .padding(22)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private func row(_ candidate: ResumeCandidate, selected: Bool, focused: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Theme.fg : Theme.fg3)
            StateGlyph(state: candidate.session.state.state, guessed: candidate.session.state.source == .guessed)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.session.title).font(Theme.ui(13, weight: .medium)).lineLimit(1)
                Text(
                    "\(candidate.session.agent) · \(candidate.paneCount) pane\(candidate.paneCount == 1 ? "" : "s") · \(candidate.summary)"
                )
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: 320, alignment: .leading)
            Text(candidate.mode.rawValue)
                .font(Theme.mono(10.5))
                .foregroundStyle(candidate.mode == .resumeThenContinue ? Theme.busy : Theme.fg2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(
                    candidate.mode == .resumeThenContinue ? Theme.busy.opacity(0.16) : Theme.chip
                ))
                .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.command)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(selected ? Theme.fg : Theme.fg3)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                if let note = candidate.note {
                    Text(note).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(focused ? Theme.bg3 : .clear)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}
