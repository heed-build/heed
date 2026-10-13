import HeedCore
import SwiftUI

/// The tutor's amber. The app's blocked colour: the one the eye already reads as "look here".
private let amber = Theme.block

/// Under the title bar the whole time the tutor runs: that this is a pretend world, and the way out.
struct TutorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text("TUTOR MODE")
                .font(Theme.mono(11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(amber)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
            Text("simulating data. Nothing here touches your files or calls real git.")
                .lineLimit(1)
            Spacer()
            Text(":q leave")
                .contentShape(Rectangle())
                .onTapGesture { model.perform(CommandInvocation(name: "tutor.exit")) }
        }
        .font(Theme.mono(12, weight: .medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(amber)
    }
}

/// The status bar's `TUTOR 3/9`, beside the mode.
struct TutorPill: View {
    let tutor: Tutor

    var body: some View {
        Text("TUTOR \(min(tutor.step + 1, tutor.lesson.steps.count))/\(tutor.lesson.steps.count)")
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(amber)
    }
}

/// Over the window while the tutor runs: everything but the step's target dimmed, and the card, on the side away from
/// the target. Reads the same region frames the screenshots use.
struct TutorLayer: View {
    @Environment(AppModel.self) private var model
    let tutor: Tutor
    let anchors: [ShotRegion: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            let target = tutor.current?.target.flatMap(ShotRegion.init(rawValue:)).flatMap { anchors[$0] }
                .map { proxy[$0] }
            ZStack(alignment: .topLeading) {
                if let target, tutor.justDone == nil {
                    // The banner stays bright: it is how you know where you are.
                    let banner = anchors[.tutorBanner].map { proxy[$0] }
                    Spotlight(hole: target.insetBy(dx: -4, dy: -4), keepLit: banner, size: proxy.size)
                        .allowsHitTesting(false)
                }
                let onRight = (target?.midX ?? 0) < proxy.size.width * 0.55
                TutorCard(tutor: tutor)
                    .shotRegion(.tutorCard)
                    .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 104)
            }
        }
    }
}

/// Everything dimmed but one rounded hole, outlined amber.
private struct Spotlight: View {
    let hole: CGRect
    var keepLit: CGRect?
    let size: CGSize

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: 8, height: 8))
                if let keepLit { path.addRect(keepLit) }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(amber, lineWidth: 1.5)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
        }
    }
}

/// One card: where you are, one sentence, the keys. Its moods: waiting (amber), a hint after a while without the keys
/// (they pulse), a nudge after a key that did nothing (violet line), done (green, what changed). A finished lesson
/// turns it into the finish card.
struct TutorCard: View {
    @Environment(AppModel.self) private var model
    let tutor: Tutor
    @State private var hinted = false

    var body: some View {
        Group {
            if tutor.finished {
                TutorFinishCard(tutor: tutor)
            } else if let step = tutor.current {
                stepCard(step)
            }
        }
        .frame(width: 400, alignment: .leading)
    }

    private func stepCard(_ step: TutorStep) -> some View {
        let done = tutor.justDone != nil
        let border = done ? Theme.done : amber
        return TimelineView(.periodic(from: model.tutorStepStarted, by: 1)) { context in
            let idle = context.date.timeIntervalSince(model.tutorStepStarted) >= 8
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(header).font(Theme.mono(11, weight: .medium)).tracking(0.6).foregroundStyle(Theme.fg3)
                    Spacer()
                    if idle, !done { Text("hint").font(Theme.mono(10.5)).foregroundStyle(amber) }
                }
                dots
                if let line = tutor.justDone {
                    Label {
                        Text(model.renderTutorText(line))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.done)
                    }
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        KeyCap(text: "↩")
                        Text("to continue, or just keep going").foregroundStyle(Theme.fg3)
                    }
                    .font(Theme.ui(12))
                    Theme.line.frame(height: 1)
                }
                Text(step.title).font(Theme.ui(17, weight: .semibold))
                Text(model.renderTutorText(step.say))
                    .font(Theme.ui(13.5))
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ForEach(step.keys, id: \.self) { key in
                        BigKey(text: model.renderTutorText(key), pulse: idle && !done)
                    }
                }
                .frame(maxWidth: .infinity)
                if let nudge = tutor.nudge {
                    Text(nudge).font(Theme.ui(12.5)).foregroundStyle(Theme.ask)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("waiting for your keys▌").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                        .frame(maxWidth: .infinity)
                }
                Theme.line.frame(height: 1)
                HStack {
                    footerCommand(":back", "tutor.back")
                    Spacer()
                    footerCommand(":skip", "tutor.skip")
                    Spacer()
                    footerCommand(":q exit", "tutor.exit")
                }
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.fg2)
            }
            .onChange(of: idle) { _, now in
                if now, !hinted, !done {
                    hinted = true
                    model.noteTutorHint()
                }
            }
        }
        .onChange(of: tutor.step) { hinted = false }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(border, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 26)
        .animation(.easeOut(duration: 0.2), value: tutor.step)
    }

    private var header: String {
        let lesson = tutor.lesson
        let where_ = lesson.isTour ? "GLOBAL TOUR" : "LESSON · \(lesson.title.uppercased())"
        return "\(where_) · \(min(tutor.step + 1, lesson.steps.count)) / \(lesson.steps.count)"
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< tutor.lesson.steps.count, id: \.self) { index in
                Circle()
                    .fill(index < tutor.step ? Theme.done : index == tutor.step ? amber : Theme.line)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private func footerCommand(_ label: String, _ command: String) -> some View {
        Text(label)
            .contentShape(Rectangle())
            .onTapGesture { model.perform(CommandInvocation(name: command)) }
    }
}

/// A key to press, large, amber; it pulses when the step has waited a while.
private struct BigKey: View {
    let text: String
    let pulse: Bool
    @State private var bright = false

    var body: some View {
        Text(text)
            .font(Theme.mono(20, weight: .medium))
            .foregroundStyle(amber)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.keyCap))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(amber.opacity(bright ? 1 : 0.6), lineWidth: 1.5))
            .shadow(color: amber.opacity(bright ? 0.5 : 0), radius: 10)
            .fixedSize()
            .onChange(of: pulse, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
                } else {
                    withAnimation(.default) { bright = false }
                }
            }
    }
}

/// The end of a lesson: how long, how many hints, every key it taught, and what is next.
struct TutorFinishCard: View {
    @Environment(AppModel.self) private var model
    let tutor: Tutor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lesson done: \(tutor.lesson.title)").font(Theme.ui(17, weight: .semibold))
                Text(summary).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("KEYS YOU NOW OWN").font(Theme.mono(10.5, weight: .medium)).tracking(0.6)
                    .foregroundStyle(Theme.fg3)
                FlowLayout(spacing: 6) {
                    ForEach(tutor.keysTaught, id: \.self) { key in KeyCap(text: model.renderTutorText(key)) }
                }
            }
            FlowLayout(spacing: 8) {
                if let next = model.nextTutorLesson {
                    chip("Next: \(next.title) · \(next.minutes) min", key: "↩", accent: true)
                }
                chip("Cheat sheet", key: "?", accent: false)
                chip("Replay", key: "r", accent: false)
            }
            Text(":q leaves the tutor; your sessions come back as they were.")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.done, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 26)
    }

    private var summary: String {
        let seconds = Int(Clock.now.timeIntervalSince(tutor.startedAt))
        let time = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        let hints = tutor.hintsUsed == 0 ? "no hints used" : "\(tutor.hintsUsed) hint\(tutor.hintsUsed == 1 ? "" : "s")"
        return "\(time) · \(hints)"
    }

    private func chip(_ text: String, key: String, accent: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text)
            KeyCap(text: key)
        }
        .font(Theme.mono(11.5, weight: .medium))
        .fixedSize()
        .foregroundStyle(accent ? amber : Theme.fg2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(accent ? amber : Theme.line))
    }
}

/// `:tutor`: this view's lesson first, then the tour, every other view, and the last lesson again.
struct TutorPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: TutorPicker

    var body: some View {
        let done = model.tutorProgress.done
        let progress = model.tutorProgress
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(": tutor▌").font(Theme.mono(13)).padding(.horizontal, 18).padding(.vertical, 14)
                Theme.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picker.rows.enumerated()), id: \.offset) { index, row in
                        if index == picker.viewsStart, picker.rows.count > picker.viewsStart {
                            Text("VIEWS").font(Theme.mono(10.5, weight: .medium)).tracking(0.6)
                                .foregroundStyle(Theme.fg3).padding(.horizontal, 18).padding(.top, 12)
                                .padding(.bottom, 4)
                        }
                        rowView(row, index: index, done: done, progress: progress)
                    }
                }
                .padding(.vertical, 6)
                Theme.line.frame(height: 1)
                HStack(spacing: 6) {
                    Text("world:").foregroundStyle(Theme.fg3)
                    Text(picker.selectedWorld.title).foregroundStyle(amber)
                    KeyCap(text: "w")
                    Spacer()
                    KeyCap(text: "↩")
                    Text("run ·").foregroundStyle(Theme.fg3)
                    KeyCap(text: "j k")
                    Text("browse ·").foregroundStyle(Theme.fg3)
                    KeyCap(text: "Esc")
                    Text("close").foregroundStyle(Theme.fg3)
                }
                .font(Theme.ui(12))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }

    private func rowView(_ row: TutorPicker.Row, index: Int, done: Set<String>, progress: TutorProgress) -> some View {
        let selected = index == picker.cursor
        let (id, replay): (String, Bool) = switch row {
        case let .lesson(id): (id, false)
        case let .replay(id): (id, true)
        }
        let lesson = Tutor.lesson(id)
        let inProgress = progress.lastLesson == id && progress.lastStep > 0 && !done.contains(id)
        return HStack(spacing: 10) {
            Group {
                if index == 0 {
                    Image(systemName: "play.fill").foregroundStyle(Theme.done)
                } else if replay {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(Theme.fg2)
                } else if done.contains(id) {
                    Image(systemName: "checkmark").foregroundStyle(Theme.done)
                } else if inProgress {
                    Text("…").foregroundStyle(amber)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14, height: 14)
            Text(title(index: index, lesson: lesson, replay: replay)).font(Theme.ui(13.5))
            Spacer()
            if let lesson, !replay {
                Text(inProgress ? "\(lesson.minutes) min · \(progress.lastStep + 1) of \(lesson.steps.count)"
                    : "\(lesson.minutes) min")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(selected ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if selected { amber.frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.pickTutorRow(index) }
    }

    private func title(index: Int, lesson: TutorLesson?, replay: Bool) -> String {
        let name = lesson?.title ?? "?"
        if replay { return "Replay last lesson (\(name))" }
        if index == 0, lesson?.isTour == false { return "This view: \(name)" }
        return name
    }
}
