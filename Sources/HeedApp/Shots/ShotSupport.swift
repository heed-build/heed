import HeedCore
import SwiftUI

/// Screenshot mode (`HEED_SHOTS`): panes draw scripted transcripts instead of shells, the clock is pinned, and views
/// report the frames of their named regions so shots can crop to them and highlight them.
@MainActor
enum ShotMode {
    static var active = false
}

/// The parts of the UI a shot can crop to or highlight. Views mark them with `.shotRegion(_:)`.
enum ShotRegion: String, CaseIterable {
    case titleBar, viewTabs, statusBar
    case sidebar, rail, center, tabStrip, panes, inspector, needsYou
    case dialog, confirm, picker, leaderHints, commandLine, filterPill, help
    case tutorBanner, tutorCard, tutorReminder
    case repoColumn, worktreeTable, rulesPanel, sweepBanner, setupBanner
    case chips, list, pickedPanel, issueRepos, syncBanner
    case pipeline, delivery, promptPreview, reader
    case diffFiles, diffBody
    case historyList, historyDetail
    case timelineFilters, timelineList, timelineDetail
    case ledgerList, ledgerDetail
    case dashboardTiles, dashboardHeatmap, dashboardShares, dashboardRecent
    case logList, logDetail, logUsage
    case pilotDetail, pilotActivity
    case attentionFilters, attentionDetail
    case goalsList, goalsOverview, goalsDoc, goalVersions, goalForm, sessionGoal, inspectorGoal
    case goalsBoard, goalMatrix, goalProposals
    case goalsUnassigned, goalAsk
    case goalReviewers, goalReviewerList, goalReviewerDetail, goalSpawn, goalBars, goalHappy
}

struct ShotRegionKey: PreferenceKey {
    static let defaultValue: [ShotRegion: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ShotRegion: Anchor<CGRect>], nextValue: () -> [ShotRegion: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Names this view's frame for screenshots. Free outside shot mode: an anchor nobody reads.
    func shotRegion(_ region: ShotRegion) -> some View {
        // transform, not set: a region inside another (panes inside center) must survive the outer one.
        transformAnchorPreference(key: ShotRegionKey.self, value: .bounds) { value, anchor in value[region] = anchor }
    }

    /// The same, for a view that is a region only sometimes (one sidebar group of several).
    func shotRegion(_ region: ShotRegion?) -> some View {
        transformAnchorPreference(key: ShotRegionKey.self, value: .bounds) { value, anchor in
            if let region { value[region] = anchor }
        }
    }
}

/// Reads the regions' frames during rendering (crops need them after), and draws highlights: the named regions at
/// full brightness with an amber outline, everything else dimmed.
final class ShotFrames {
    var rects: [ShotRegion: CGRect] = [:]

    /// Keeps the frames for cropping after the render, and returns the highlighted ones.
    func record(_ rects: [ShotRegion: CGRect], highlight: [ShotRegion]) -> [CGRect] {
        self.rects = rects
        return highlight.compactMap { rects[$0] }
    }
}

struct ShotFrame<Content: View>: View {
    let highlight: [ShotRegion]
    let frames: ShotFrames
    @ViewBuilder let content: Content

    var body: some View {
        content.overlayPreferenceValue(ShotRegionKey.self) { anchors in
            GeometryReader { proxy in
                let lit = frames.record(anchors.mapValues { proxy[$0] }, highlight: highlight)
                if !lit.isEmpty {
                    ZStack {
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: proxy.size))
                            for rect in lit {
                                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
                            }
                        }
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        ForEach(Array(lit.enumerated()), id: \.offset) { _, rect in
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(hex: 0xF0A53A), lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// A pane's terminal in shot mode: the fixture's transcript, styled like the real terminal.
struct FakeTerminal: View {
    let pane: PaneSpec

    var body: some View {
        let text = Fixtures.transcripts[pane.id] ?? Fixtures.prompt(for: pane)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Self.styled(line) }
            Spacer(minLength: 0)
        }
        .font(Theme.mono(12.5))
        .foregroundStyle(Theme.fg)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.pane)
    }

    /// `{green}you@mac{/} %` → styled runs.
    static func styled(_ line: String) -> Text {
        var result = Text("")
        var style: String?
        var rest = Substring(line)
        while !rest.isEmpty {
            if rest.hasPrefix("{"), let close = rest.firstIndex(of: "}") {
                let tag = String(rest[rest.index(after: rest.startIndex) ..< close])
                style = tag == "/" ? nil : tag
                rest = rest[rest.index(after: close)...]
                continue
            }
            let next = rest.firstIndex(of: "{") ?? rest.endIndex
            let run = Text(String(rest[..<next]))
            result = Text("\(result)\(apply(style, to: run))")
            rest = rest[next...]
        }
        return Text("\(result) ")
    }

    private static func apply(_ style: String?, to text: Text) -> Text {
        switch style {
        case "dim": text.foregroundColor(Theme.fg3)
        case "bold": text.bold()
        case "green": text.foregroundColor(Theme.done)
        case "blue": text.foregroundColor(Theme.busy)
        case "amber": text.foregroundColor(Theme.block)
        case "red": text.foregroundColor(Theme.err)
        case "violet": text.foregroundColor(Theme.ask)
        default: text
        }
    }
}

/// A list's stack: lazy in the app, plain in shot mode (the offscreen renderer draws nothing inside lazy stacks).
struct ListStack<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        if ShotMode.active {
            VStack(alignment: alignment, spacing: spacing) { content }
        } else {
            LazyVStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

/// A scroll view in the app; in shot mode its content, top-aligned and clipped (the offscreen renderer draws nothing
/// inside a scroll view).
struct ListScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder let content: Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        if ShotMode.active {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(axes) { content }
        }
    }
}
