import HeedCore
import SwiftUI

/// Under the title bar while the tutor runs: that this is a sandbox, and how to move through it or leave.
struct TutorBanner: View {
    @Environment(AppModel.self) private var model
    let tutor: Tutor

    var body: some View {
        HStack(spacing: 10) {
            Text("TUTOR")
                .font(Theme.mono(11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.modeColor(.hint)))
            Text("Sandbox on made-up data: nothing here touches your real sessions.")
                .foregroundStyle(Theme.fg2)
                .lineLimit(1)
            Spacer()
            Text("lesson \(tutor.lesson + 1) of \(tutor.lessons.count)").foregroundStyle(Theme.fg3).fixedSize()
            KeyCap(text: "⌘[")
            KeyCap(text: "⌘]")
            Text("lessons").foregroundStyle(Theme.fg3).fixedSize()
            HStack(spacing: 6) {
                Text("Leave")
                KeyCap(text: ":tutor")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .onTapGesture { model.perform(CommandInvocation(name: "tutor")) }
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Theme.bg3)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The current lesson: what it is for, its steps ticked off as you do them, the next one highlighted.
struct TutorCard: View {
    @Environment(AppModel.self) private var model
    let tutor: Tutor

    var body: some View {
        let lesson = tutor.current
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lesson \(tutor.lesson + 1)").font(Theme.ui(11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.fg3)
                Text(lesson.title).font(Theme.ui(15, weight: .semibold))
            }
            rendered(lesson.intro).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lesson.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: index < tutor.step ? "checkmark.circle.fill"
                            : index == tutor.step ? "arrow.right.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(index < tutor.step ? Theme.done : index == tutor.step ? Theme.fg : Theme
                                .fg3)
                        rendered(step.instruction)
                            .font(Theme.ui(12.5))
                            .foregroundStyle(index == tutor.step ? Theme.fg : Theme.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if tutor.lessonDone {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.done)
                    if tutor.finished {
                        Text("That is the tutor. :tutor leaves the sandbox.")
                    } else {
                        Text("Lesson done.")
                        KeyCap(text: "⌘]")
                        Text("next lesson")
                    }
                }
                .font(Theme.ui(12.5, weight: .medium))
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 24)
    }

    /// `{command}` becomes that command's key as you have it bound, in bold mono; the rest stays prose.
    private func rendered(_ text: String) -> Text {
        var result = Text("")
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result = Text("\(result)\(Text(String(rest[..<open])))")
            let command = String(rest[rest.index(after: open) ..< close])
            let key = model.keyLabel(for: command) ?? ":\(command)"
            result = Text("\(result)\(Text(key).font(Theme.mono(12.5, weight: .bold)).foregroundColor(Theme.fg))")
            rest = rest[rest.index(after: close)...]
        }
        return Text("\(result)\(Text(String(rest)))")
    }
}
