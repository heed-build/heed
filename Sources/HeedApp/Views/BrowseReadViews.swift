import HeedCore
import SwiftUI

// heed's read of an item in Browse: the columns of a row, the card in the reader, and the verbs an agent can be
// sent with. A read is local to this Mac and never written to GitHub.

extension BrowseVerb {
    /// Fix red, Implement blue, Chat purple, Review green.
    var tint: Color {
        switch self {
        case .fix: Theme.err
        case .implement: Theme.busy
        case .chat: Theme.ask
        case .review: Theme.done
        }
    }

    var symbol: String {
        switch self {
        case .fix: "ladybug"
        case .implement: "sparkle"
        case .chat: "bubble.left"
        case .review: "arrow.triangle.pull"
        }
    }
}

extension BrowseClass {
    var symbol: String {
        switch self {
        case .bug: "ladybug"
        case .feature: "sparkle"
        case .docs: "tag"
        case .question: "questionmark.bubble"
        case .chore: "flag"
        }
    }

    var tint: Color {
        switch self {
        case .bug: Theme.err
        case .feature: Theme.busy
        case .docs: Theme.done
        case .question: Theme.ask
        case .chore: Theme.fg2
        }
    }
}

extension BrowseRead {
    /// Green from 70, amber from 40, gray under it.
    var readyTint: Color { agentReady >= BrowseRead.readyLine ? Theme.done : agentReady >= 40 ? Theme.block : Theme.fg3
    }
}

/// Three ascending bars, as many lit as the size says.
struct ReadPips: View {
    let size: BrowseSize
    var dimmed = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < size.pips ? Theme.fg : Theme.fg3.opacity(0.35))
                    .frame(width: 4, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 10, alignment: .bottom)
        .opacity(dimmed ? 0.5 : 1)
        .help("\(size.title)")
    }
}

/// A ring filled to the readiness, with the number beside it when asked.
struct ReadyRing: View {
    let read: BrowseRead
    var number = true
    var dimmed = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.fg3.opacity(0.3), lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(read.agentReady) / 100)
                    .stroke(read.readyTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            if number {
                Text(verbatim: "\(read.agentReady)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .help("\(read.agentReady)% agent-ready")
    }
}

/// The hatch an unread row shows in place of a read.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(path, with: .color(Theme.fg3.opacity(0.45)), lineWidth: 1)
        }
        .frame(width: 44, height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// A row's right-hand columns: class glyph, size pips and the readiness ring; hatched, with "unread", when heed
/// has not read the item. Dimmed when the read is stale.
struct BrowseReadColumns: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        let state = model.browseReadState(item)
        HStack(spacing: 10) {
            if let read = state.read {
                let stale = if case .stale = state { true } else { false }
                Image(systemName: read.kind.symbol).font(.system(size: 12.5)).foregroundStyle(read.kind.tint)
                    .frame(width: 18).opacity(stale ? 0.5 : 1).help(read.kind.title)
                ReadPips(size: read.size, dimmed: stale)
                if item.kind == .issue {
                    ReadyRing(read: read, dimmed: stale).frame(width: 46, alignment: .leading)
                } else {
                    Color.clear.frame(width: 46, height: 1)
                }
            } else {
                switch state {
                case let .reading(run):
                    ProgressView().controlSize(.mini).help(run.queued ? "queued to be read" : "reading")
                    Text(run.queued ? "queued" : "reading").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                default:
                    Hatch()
                    Text("unread").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
        .frame(width: 128, alignment: .trailing)
    }
}

/// The verb heed suggests, in the row's second line, in its colour.
struct BrowseVerbHint: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        if let advice = model.browseVerbs(item).recommended {
            let stale = if case .stale = model.browseReadState(item) { true } else { false }
            HStack(spacing: 4) {
                Image(systemName: advice.verb.symbol).font(.system(size: 10.5))
                Text(advice.verb.title).font(Theme.ui(12, weight: .semibold))
            }
            .foregroundStyle(advice.verb.tint)
            .opacity(stale ? 0.55 : 1)
            .fixedSize()
            .help(advice.reason)
        }
    }
}

// MARK: The reader's card

/// "heed's read" in the reader: class, size, readiness, the TL;DR, possible duplicates, and always its state (queued,
/// reading, up to date, stale, failed, off), as the catch-up card has.
struct BrowseReadCard: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        let state = model.browseReadState(item)
        let read = state.read
        let stale = if case .stale = state { true } else { false }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 11))
                    Text("HEED'S READ").font(Theme.mono(11, weight: .bold)).tracking(0.8)
                }
                .foregroundStyle(Theme.busy)
                Spacer(minLength: 12)
                Text("local to heed · never written to GitHub").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    .lineLimit(1)
            }
            if let read {
                facts(read, stale: stale)
                Text(verbatim: read.tldr).font(Theme.ui(13.5)).foregroundStyle(stale ? Theme.fg2 : Theme.fg)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(read.duplicates, id: \.self) { id in duplicate(id) }
            }
            status(state)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.busy.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.busy.opacity(0.3)))
        .shotRegion(.browseRead)
    }

    private func facts(_ read: BrowseRead, stale: Bool) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: read.kind.symbol).foregroundStyle(read.kind.tint)
                Text(read.kind.title).font(Theme.ui(14, weight: .semibold))
            }
            HStack(spacing: 6) {
                ReadPips(size: read.size)
                Text(read.size.title).font(Theme.ui(14, weight: .semibold))
            }
            if item.kind == .issue {
                HStack(spacing: 6) {
                    ReadyRing(read: read, number: false)
                    Text("\(read.agentReady)%").font(Theme.ui(14, weight: .semibold))
                    Text("agent-ready").font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
                }
            } else if let checks = item.checks {
                HStack(spacing: 6) {
                    Image(systemName: checks == .passing ? "checkmark" : checks == .failing ? "xmark" : "clock")
                        .foregroundStyle(checks == .passing ? Theme.done : checks == .failing ? Theme.err : Theme.block)
                    Text("CI \(checks == .passing ? "green" : checks == .failing ? "failing" : "running")")
                        .font(Theme.ui(14, weight: .semibold))
                }
            }
        }
        .opacity(stale ? 0.55 : 1)
    }

    /// "Possibly the same as #2701 (closed, anchors on rename)": from titles, found on this Mac, not by the model.
    @ViewBuilder private func duplicate(_ id: String) -> some View {
        if let other = model.browse.items.first(where: { $0.id == id }) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square").font(.system(size: 11)).foregroundStyle(Theme.block)
                Text("Possibly the same as").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                Text(verbatim: "#\(other.number)").font(Theme.ui(13)).foregroundStyle(Theme.busy)
                Text(verbatim: "(\(other.state.rawValue), \(other.title.display.lowercased()))")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
        }
    }

    private func status(_ state: BrowseReadState) -> some View {
        HStack(spacing: 8) {
            Text(state.chip).font(Theme.ui(11.5)).foregroundStyle(tint(state))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(tint(state).opacity(0.14))).fixedSize()
            Text(state.line(item: item, now: Clock.now)).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(2)
            switch state {
            case .upToDate, .stale:
                action("↻ read again")
            case .failed:
                action("↻ again")
                action(":log", invocation: CommandInvocation(name: "view.log"), key: false)
            case .unread:
                action("Read it")
            case let .off(reason):
                let words = reason.command.split(separator: " ").map(String.init)
                action(
                    "Turn on", invocation: CommandInvocation(name: words[0], arguments: Array(words.dropFirst())),
                    key: false
                )
            case .reading:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func action(
        _ label: String, invocation: CommandInvocation = CommandInvocation(name: "browse.read"), key: Bool = true
    ) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg)
            if key {
                Text(model.keyText(for: "browse.read", in: "browse")).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.keyCapBorder))
        .clickRuns(invocation)
    }

    private func tint(_ state: BrowseReadState) -> Color {
        switch state {
        case .reading: Theme.busy
        case .upToDate: Theme.done
        case .stale: Theme.block
        case .failed: Theme.err
        case .unread, .off: Theme.fg3
        }
    }
}

// MARK: Work on it

/// "Work on it with an agent": all four verbs, the suggested one outlined in its colour with the reason, those that do
/// not fit dashed and dimmed with why, and the line to say it in your own words.
struct BrowseWorkSection: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        let verbs = model.browseVerbs(item)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.busy)
                Text("Work on it with an agent").font(Theme.ui(14, weight: .semibold)).fixedSize()
                Spacer(minLength: 12)
                Text(verbs.headline).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(verbs.ordered, id: \.verb) { advice in card(advice) }
            }
            HStack {
                Text("or tell it what to do…").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                Spacer()
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                    .frame(width: 22, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .clickRuns(CommandInvocation(name: "browse.tell"))
            Text(footer).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .shotRegion(.browseWork)
    }

    private var footer: String {
        var text = "Each opens Start work with the prompt ready. Nothing runs until you start it."
        if !model.browseIsCloned(item.repo) {
            text = "\(item.repo.slug) is not cloned on this Mac: Start work offers to clone it. " + text
        }
        return text
    }

    private func card(_ advice: BrowseVerbAdvice) -> some View {
        let verb = advice.verb
        let off = advice.availability == .unavailable
        let recommended = advice.availability == .recommended
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: verb.symbol).font(.system(size: 12))
                    .foregroundStyle(off ? Theme.fg3 : verb.tint)
                Text(verb.title).font(Theme.ui(13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                Text(verb.key).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.keyCapBorder))
            }
            .foregroundStyle(off ? Theme.fg3 : Theme.fg)
            // What it does, unless it is on offer with a caveat, or does not fit: then why.
            Text(off || (advice.availability == .available && advice.reason != verb.summary)
                ? advice.reason : verb.summary)
                .font(Theme.ui(12.5)).foregroundStyle(off ? Theme.fg3 : Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(recommended ? verb.tint.opacity(0.07) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                recommended ? verb.tint : off ? Theme.line : Theme.keyCapBorder,
                style: StrokeStyle(lineWidth: recommended ? 1.5 : 1, dash: off ? [4, 3] : [])
            )
        )
        .opacity(off ? 0.7 : 1)
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: verb.command))
    }
}
