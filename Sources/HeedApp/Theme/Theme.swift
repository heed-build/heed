import AppKit
import HeedCore
import Observation
import SwiftUI

/// The design's tokens (design/html/Main.html). Dark only; mono type for data and keys, system font for chrome.
enum Theme {
    static let bg = Color(hex: 0x111214)
    static let bg2 = Color(hex: 0x15171A)
    static let bg3 = Color(hex: 0x1D2024)
    static let line = Color(hex: 0x272B30)
    static let fg = Color(hex: 0xE9EAEC)
    static let fg2 = Color(hex: 0xA6ABB2)
    static let fg3 = Color(hex: 0x848B93)
    static let dim = Color(hex: 0x7B828A)
    static let pane = Color(hex: 0x0C0D0F)
    static let paneHeader = Color(hex: 0x121316)
    static let paneActive = Color(hex: 0xAAB0B8)
    static let chip = Color(hex: 0x23272C)
    static let selected = Color(hex: 0x2B2F35)
    static let keyCap = Color(hex: 0x1A1D20)
    static let keyCapBorder = Color(hex: 0x373C43)
    static let inverse = Color(hex: 0xDFE3E8)
    static let ink = Color(hex: 0x101114)
    static let terminalText = Color(hex: 0xCFD3D8)

    // State hues. Org colors never use these.
    static let busy = Color(hex: 0x67B0F9)
    static let block = Color(hex: 0xF9BB51)
    static let ask = Color(hex: 0xC79EF7)
    static let done = Color(hex: 0x72D699)
    static let err = Color(hex: 0xF97770)

    static func modeColor(_ mode: Mode) -> Color {
        switch mode {
        case .normal: inverse
        case .insert: done
        case .visual: block
        case .command: ask
        case .hint: Color(hex: 0x73DFDF)
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
        case .teal: Color(hex: 0x73DFDF)
        case .pink: Color(hex: 0xFDB0D4)
        case .lime: Color(hex: 0xC2D58A)
        case .orange: Color(hex: 0xFFB88F)
        case .periwinkle: Color(hex: 0xC3C2FF)
        case .sky: Color(hex: 0x82D7FF)
        }
    }

    var swatch: Color {
        switch self {
        case .teal: Color(hex: 0x3BCFCF)
        case .pink: Color(hex: 0xF197C2)
        case .lime: Color(hex: 0xADC367)
        case .orange: Color(hex: 0xF5A06F)
        case .periwinkle: Color(hex: 0xAFACFF)
        case .sky: Color(hex: 0x59C5F5)
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

extension Color {
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
