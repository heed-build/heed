import AppKit
import HeedCore
#if HEED_GHOSTTY
    import HeedTerminal
#endif
import Observation
import SwiftUI

/// The design's tokens (design/html/Main.html), in dark and in light. Every token is dynamic: it resolves against the
/// appearance of the window it is drawn in, which `Appearance` (`[ui] appearance`) sets on the app. Mono type for data
/// and keys, system font for chrome.
enum Theme {
    static let bg = Color(dark: 0x111214, light: 0xF6F7F8)
    static let bg2 = Color(dark: 0x15171A, light: 0xEEF0F2)
    static let bg3 = Color(dark: 0x1D2024, light: 0xE6E9EC)
    static let line = Color(dark: 0x272B30, light: 0xD5D9DE)
    static let fg = Color(dark: 0xE9EAEC, light: 0x17191C)
    static let fg2 = Color(dark: 0xA6ABB2, light: 0x474D55)
    static let fg3 = Color(dark: 0x848B93, light: 0x646B74)
    static let dim = Color(dark: 0x7B828A, light: 0x6A717A)
    static let pane = Color(dark: 0x0C0D0F, light: 0xFFFFFF)
    static let paneHeader = Color(dark: 0x121316, light: 0xF1F2F4)
    static let paneActive = Color(dark: 0xAAB0B8, light: 0x4F565E)
    static let chip = Color(dark: 0x23272C, light: 0xE4E7EB)
    static let selected = Color(dark: 0x2B2F35, light: 0xCDD4DC)
    static let keyCap = Color(dark: 0x1A1D20, light: 0xFFFFFF)
    static let keyCapBorder = Color(dark: 0x373C43, light: 0xC2C8CF)
    static let inverse = Color(dark: 0xDFE3E8, light: 0x23272C)
    static let ink = Color(dark: 0x101114, light: 0xF6F7F8)
    static let terminalText = Color(dark: 0xCFD3D8, light: 0x24292F)
    /// What dims what is behind a dialog or drawer; a shadow under one.
    static let scrim = Color(dark: 0x000000, light: 0x1B1E22)

    // State hues. Org colors never use these.
    static let busy = Color.adaptive(0x67B0F9)
    static let block = Color.adaptive(0xF9BB51)
    static let ask = Color.adaptive(0xC79EF7)
    static let done = Color.adaptive(0x72D699)
    static let err = Color.adaptive(0xF97770)

    /// A kind of work's hue: its badge and its Start work chip. Drawn as text on a tint, never as a state dot.
    static func kind(_ kind: WorkKind) -> Color {
        switch kind {
        case .feat: Color.adaptive(0x8FB4FF)
        case .fix: Color.adaptive(0xFF8F8F)
        case .refactor: Color.adaptive(0xC9A0FF)
        case .docs: Color.adaptive(0x7FD1C7)
        case .chore: Color.adaptive(0x9AA0AD)
        case .plan: Color.adaptive(0xE8C36A)
        }
    }

    static func modeColor(_ mode: Mode) -> Color {
        switch mode {
        case .normal: inverse
        case .insert: done
        case .visual: block
        case .command: ask
        case .hint: Color.adaptive(0x73DFDF)
        }
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrains Mono", size: size) != nil {
            return .custom("JetBrains Mono", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Org and repo colors: hues away from the state hues, so a chip is never mistaken for a status.
enum OrgPalette: String, CaseIterable, Sendable {
    case teal, pink, lime, orange, periwinkle, sky

    var foreground: Color {
        switch self {
        case .teal: Color.adaptive(0x73DFDF)
        case .pink: Color.adaptive(0xFDB0D4)
        case .lime: Color.adaptive(0xC2D58A)
        case .orange: Color.adaptive(0xFFB88F)
        case .periwinkle: Color.adaptive(0xC3C2FF)
        case .sky: Color.adaptive(0x82D7FF)
        }
    }

    var swatch: Color {
        switch self {
        case .teal: Color.adaptive(0x3BCFCF, lightness: 0.52)
        case .pink: Color.adaptive(0xF197C2, lightness: 0.52)
        case .lime: Color.adaptive(0xADC367, lightness: 0.52)
        case .orange: Color.adaptive(0xF5A06F, lightness: 0.52)
        case .periwinkle: Color.adaptive(0xAFACFF, lightness: 0.52)
        case .sky: Color.adaptive(0x59C5F5, lightness: 0.52)
        }
    }

    /// The chip background: 16% of the swatch over the chip base, as in the design.
    var background: Color { swatch.opacity(0.16) }

    /// A stable automatic color for an org that has none configured.
    static func automatic(for name: String) -> OrgPalette {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return allCases[sum % allCases.count]
    }
}

/// Host colours: the palette minus lime and orange, which read as green and amber (done and needs-you).
enum HostPalette {
    static let colors: [OrgPalette] = [.teal, .periwinkle, .pink, .sky]

    /// `[hosts.x] color`, else one picked from the name.
    static func color(for host: String, configured: String?) -> OrgPalette {
        if let configured, let color = OrgPalette(rawValue: configured), colors.contains(color) { return color }
        let sum = host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }
}

extension Color {
    /// A colour that is `dark` in a dark appearance and `light` in a light one.
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// A hue designed for dark panels, kept as it is there and darkened (same hue and saturation) to `lightness` in a
    /// light appearance, so a state colour or a chip's text still reads on a pale background.
    static func adaptive(_ hex: UInt32, lightness: Double = 0.38) -> Color {
        let (hue, saturation, light) = NSColor(hex: hex).hsl
        return Color(
            dark: hex,
            light: NSColor(hue: hue, saturation: saturation, lightness: min(light, lightness)).hexValue
        )
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Repo {
    /// The repo's color from config (`[repos."org/name"] color`), else its org's (`[orgs.<name>] color`), else one
    /// picked from the org's name.
    @MainActor var color: OrgPalette { Palette.shared.color(for: self) }
}

/// Org and repo colors from config, observed so chips redraw when config.toml changes.
@MainActor
@Observable
final class Palette {
    static let shared = Palette()
    private(set) var orgs: [String: OrgPalette] = [:]
    private(set) var repos: [String: OrgPalette] = [:]

    func apply(_ config: HeedConfig) {
        orgs = config.orgColors.compactMapValues(OrgPalette.init(rawValue:))
        repos = config.repos.compactMapValues { $0.color.flatMap(OrgPalette.init(rawValue:)) }
    }

    func color(for repo: Repo) -> OrgPalette {
        repos[repo.slug] ?? orgs[repo.org] ?? orgs[repo.org.lowercased()] ?? OrgPalette
            .automatic(for: repo.org.lowercased())
    }
}

/// Org avatars as images, observed so tiles redraw when one arrives. Disk reads and downloads run off the main
/// actor (`AvatarCache`); this only holds decoded images.
@MainActor
@Observable
final class Avatars {
    static let shared = Avatars()
    private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []
    private let cache = AvatarCache.default()

    func image(for org: String) -> NSImage? { images[org.lowercased()] }

    /// Shows cached avatars at once, then refreshes missing or week-old ones in the background (from `urls`, by
    /// lowercased name, where the API gave one: a bot's or app's avatar is not at github.com/<name>.png).
    func load(_ orgs: [String], urls: [String: URL] = [:]) {
        let wanted = Set(orgs.map { $0.lowercased() }).subtracting(requested)
        guard !wanted.isEmpty else { return }
        requested.formUnion(wanted)
        let cache = cache
        Task.detached(priority: .utility) {
            var stale: [String] = []
            for org in wanted {
                if let data = cache.cached(org) { await self.store(org, data) }
                if cache.isStale(org) { stale.append(org) }
            }
            for org in stale {
                if let data = await cache.refresh(org, from: urls[org]) { await self.store(org, data) }
            }
        }
    }

    private func store(_ org: String, _ data: Data) {
        if let image = NSImage(data: data) { images[org] = image }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }

    /// Hue, saturation and lightness (all 0...1) of an sRGB colour.
    var hsl: (Double, Double, Double) {
        let color = usingColorSpace(.sRGB) ?? self
        let (red, green, blue) = (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        let high = max(red, green, blue), low = min(red, green, blue)
        let light = (high + low) / 2
        guard high != low else { return (0, 0, light) }
        let delta = high - low
        let saturation = light > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double = switch high {
        case red: (green - blue) / delta + (green < blue ? 6 : 0)
        case green: (blue - red) / delta + 2
        default: (red - green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, light)
    }

    convenience init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2
        let (red, green, blue): (Double, Double, Double) = switch Int(hue * 6) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        self.init(srgbRed: red + match, green: green + match, blue: blue + match, alpha: 1)
    }

    var hexValue: UInt32 {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) & 0xFF }
        return byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
}

/// Applies `[ui] appearance`: the app's appearance (which every dynamic token in `Theme` resolves against) and the
/// terminal panes' colours. The last choice is kept in UserDefaults so the next launch draws in it before config.toml
/// has been read.
@MainActor
enum AppearanceControl {
    private static let key = "appearance"
    private static var observation: NSKeyValueObservation?

    /// At launch, before any window: the last choice.
    static func applyStored() {
        let stored = UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
        set(stored)
        // Following macOS: the panes change when the system does.
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { syncTerminals() }
        }
    }

    static func apply(_ appearance: Appearance, remember: Bool = true) {
        if remember { UserDefaults.standard.set(appearance.rawValue, forKey: key) }
        set(appearance)
    }

    private static func set(_ appearance: Appearance) {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        syncTerminals()
    }

    private static func syncTerminals() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #if HEED_GHOSTTY
            GhosttyRuntime.setAppearance(dark: dark)
        #endif
    }
}
