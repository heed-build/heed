import AppKit
import HeedCore
import SwiftUI

/// One screenshot for the docs: what to draw from the fake world, what to type first, and how to frame it.
struct Shot {
    enum Subject {
        /// The main window, with drawn window chrome.
        case window
        /// The standalone Start work panel over a desktop backdrop.
        case panel
        /// The menu bar item, and the menu bar around it.
        case menuBar
        /// The menu bar item's open menu.
        case menu
        /// The Dock icon with its badge.
        case dock
    }

    /// Output path under docs/images/shots, without extension: `sessions/anatomy`.
    let id: String
    var subject: Subject = .window
    var size = CGSize(width: 1440, height: 900)
    /// Keys typed into the fake world first, in vim notation.
    var keys = ""
    /// Crop to this region (with padding) instead of the whole frame.
    var crop: ShotRegion?
    var cropPadding: CGFloat = 16
    /// Regions kept bright and outlined; the rest is dimmed.
    var highlight: [ShotRegion] = []
    /// Anything keys cannot reach (a state to set up), run before the keys.
    var prepare: (@MainActor (AppModel) -> Void)?
}

/// `HEED_SHOTS=<dir>`: renders every shot (or those whose id starts with `HEED_SHOTS_ONLY`) offscreen from the fake
/// world, writes `<dir>/<id>.png` at 2x, and quits. `mise run shots` runs it into docs/images/shots.
@MainActor
enum ShotRunner {
    /// The instant every shot is taken at, so ages and dates never move.
    static let instant = ISO8601DateFormatter().date(from: "2026-10-13T09:41:00+02:00")!

    static var requested: Bool { ProcessInfo.processInfo.environment["HEED_SHOTS"] != nil }

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["HEED_SHOTS"] ?? "shots")
        let only = environment["HEED_SHOTS_ONLY"] ?? ""
        ShotMode.active = true
        Clock.fixed = instant
        NSTimeZone.default = TimeZone(identifier: "Europe/Amsterdam")!
        var written = 0
        for shot in Shots.all where only.isEmpty || shot.id.hasPrefix(only) {
            do {
                try await render(shot, into: directory)
                written += 1
                print("shot \(shot.id)")
            } catch {
                print("shot \(shot.id) FAILED: \(error)")
            }
        }
        print("shots: \(written) written to \(directory.path)")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func render(_ shot: Shot, into directory: URL) async throws {
        let model = AppModel(domain: Fixtures.main, isFixture: true)
        shot.prepare?(model)
        for stroke in (try? KeyNotation.parse(shot.keys)) ?? [] {
            _ = model.handle(stroke)
        }
        // Let whatever the keys started (tasks on the main actor) finish.
        try? await Task.sleep(for: .milliseconds(150))

        let frames = ShotFrames()
        let view = ShotFrame(highlight: shot.highlight, frames: frames) {
            subject(shot, model: model)
        }
        .frame(width: shot.size.width, height: shot.size.height)
        .environment(model)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(shot.size)
        guard var image = renderer.cgImage else { throw Failure(description: "nothing rendered") }
        if let crop = shot.crop {
            guard let rect = frames.rects[crop] else { throw Failure(description: "region \(crop) not on screen") }
            let padded = rect.insetBy(dx: -shot.cropPadding, dy: -shot.cropPadding)
                .intersection(CGRect(origin: .zero, size: shot.size))
            let pixels = CGRect(
                x: padded.minX * 2,
                y: padded.minY * 2,
                width: padded.width * 2,
                height: padded.height * 2
            )
            guard let cropped = image.cropping(to: pixels.integral) else { throw Failure(description: "crop failed") }
            image = cropped
        }
        let url = directory.appendingPathComponent(shot.id + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
        try png.write(to: url)
    }

    @ViewBuilder
    private static func subject(_ shot: Shot, model _: AppModel) -> some View {
        switch shot.subject {
        case .window: WindowChrome { MainWindow() }
        case .panel: PanelBackdrop { StartWorkView(standalone: true) }
        case .menuBar: MenuBarMock()
        case .menu: MenuMock()
        case .dock: DockMock()
        }
    }
}

/// The window's own chrome, which AppKit draws and an offscreen render does not: rounded corners, the traffic lights.
private struct WindowChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57))
                    Circle().fill(Color(hex: 0xFEBC2E))
                    Circle().fill(Color(hex: 0x28C840))
                }
                .frame(width: 52, height: 12)
                .padding(.leading, 14)
                .padding(.top, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// A plain desktop behind the floating panel, so it reads as "over another app".
private struct PanelBackdrop<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            // Flat, so the PNG stays small.
            Color(hex: 0x232A33)
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x23272E)).frame(width: 900, height: 560)
                .offset(x: -120, y: 120).opacity(0.7)
            content.padding(.top, 60)
        }
    }
}
