import AppKit
import SwiftUI

enum AccentColor: String, Codable, CaseIterable, Identifiable {
    case violet, coral, lime, sky, pink, gold, mint, mono
    var id: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .violet: 0x8B7CFF
        case .coral: 0xFF6B57
        case .lime: 0xB8E85A
        case .sky: 0x4FB8F5
        case .pink: 0xFF7EBB
        case .gold: 0xF2B63D
        case .mint: 0x5CC98E
        case .mono: 0x8E8E93
        }
    }

    var label: String { rawValue.capitalized }
}

enum FontChoice: String, Codable, CaseIterable, Identifiable {
    case serif      // New York
    case inter      // bundled Inter
    case system     // SF Pro
    case rounded    // SF Pro Rounded
    case mono       // SF Mono
    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "New York"
        case .inter: "Inter"
        case .system: "SF Pro"
        case .rounded: "Rounded"
        case .mono: "Mono"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .inter:
            return NSFont.inter(size: size, weight: weight)
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .serif, .rounded, .mono:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign = self == .serif ? .serif : self == .rounded ? .rounded : .monospaced
            guard let d = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: d, size: size) ?? base
        }
    }
}

extension NSFont {
    static func inter(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-Bold"
        case .semibold: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

/// A theme preset: a matched set of colors and fonts. Notes pick one and may override parts.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: UInt32
    let surface: UInt32      // rails, tabs, panels
    let text: UInt32
    let secondary: UInt32    // body copy slightly softer than headings
    let tertiary: UInt32     // metadata, placeholders, unchecked boxes
    let titleFont: FontChoice
    let bodyFont: FontChoice
    let defaultAccent: AccentColor?

    static let midnight = Theme(id: "midnight", name: "Midnight", isDark: true,
                                background: 0x111114, surface: 0x1C1B21, text: 0xF0EFF4, secondary: 0xC9C7D2, tertiary: 0x6E6C78,
                                titleFont: .serif, bodyFont: .inter, defaultAccent: nil)
    static let ink = Theme(id: "ink", name: "Ink", isDark: false,
                           background: 0xFDFDFC, surface: 0xF2F2F0, text: 0x111113, secondary: 0x3A3A3D, tertiary: 0xA3A3A0,
                           titleFont: .serif, bodyFont: .inter, defaultAccent: nil)
    static let paper = Theme(id: "paper", name: "Paper", isDark: false,
                             background: 0xF7F1E6, surface: 0xEDE4D4, text: 0x33281F, secondary: 0x4A3C30, tertiary: 0xAE9C86,
                             titleFont: .serif, bodyFont: .serif, defaultAccent: .coral)
    static let terminal = Theme(id: "terminal", name: "Terminal", isDark: true,
                                background: 0x0A0A0A, surface: 0x171717, text: 0xE8F5D0, secondary: 0xC2CCB0, tertiary: 0x5E6656,
                                titleFont: .mono, bodyFont: .mono, defaultAccent: .lime)
    static let blush = Theme(id: "blush", name: "Blush", isDark: false,
                             background: 0xFAE6E8, surface: 0xF2D5D9, text: 0x5E2232, secondary: 0x74394A, tertiary: 0xC0959F,
                             titleFont: .serif, bodyFont: .inter, defaultAccent: .pink)
    static let sage = Theme(id: "sage", name: "Sage", isDark: true,
                            background: 0x17221D, surface: 0x22302A, text: 0xE3F0E7, secondary: 0xC0D4C7, tertiary: 0x6C8476,
                            titleFont: .serif, bodyFont: .inter, defaultAccent: .mint)

    static let lilac = Theme(id: "lilac", name: "Lilac", isDark: false,
                             background: 0xF2EEFB, surface: 0xE6DFF6, text: 0x2A2340, secondary: 0x463D62, tertiary: 0xA59DC0,
                             titleFont: .serif, bodyFont: .inter, defaultAccent: .violet)
    static let ocean = Theme(id: "ocean", name: "Ocean", isDark: true,
                             background: 0x0E1726, surface: 0x18243A, text: 0xE8EFFA, secondary: 0xC2CEE0, tertiary: 0x5F7090,
                             titleFont: .serif, bodyFont: .inter, defaultAccent: .sky)
    static let espresso = Theme(id: "espresso", name: "Espresso", isDark: true,
                                background: 0x1A1411, surface: 0x271F1A, text: 0xF4EAE2, secondary: 0xD8C9BD, tertiary: 0x7F6D60,
                                titleFont: .serif, bodyFont: .serif, defaultAccent: .gold)

    /// "Auto" follows the system: Midnight when dark, Ink when light.
    static let auto = Theme(id: "auto", name: "Auto", isDark: true,
                            background: 0, surface: 0, text: 0, secondary: 0, tertiary: 0,
                            titleFont: .serif, bodyFont: .inter, defaultAccent: nil)

    static let presets: [Theme] = [.auto, .midnight, .ink, .paper, .terminal, .blush, .sage, .lilac, .ocean, .espresso]

    static func preset(id: String) -> Theme { presets.first { $0.id == id } ?? .auto }

    /// Concrete theme for the current system appearance.
    func resolved(systemIsDark: Bool) -> Theme {
        id == Theme.auto.id ? (systemIsDark ? .midnight : .ink) : self
    }
}

/// Everything the editor and chrome need to draw one note, after applying overrides.
struct ResolvedStyle: Equatable {
    let theme: Theme
    let accent: AccentColor
    let titleFont: FontChoice
    let bodyFont: FontChoice
    let textSize: CGFloat
    let lineSpacing: CGFloat
    let width: PageWidth

    init(style: NoteStyle, systemIsDark: Bool, appAccent: AccentColor) {
        let theme = Theme.preset(id: style.themeID).resolved(systemIsDark: systemIsDark)
        self.theme = theme
        accent = style.accent ?? theme.defaultAccent ?? appAccent
        titleFont = style.titleFont ?? theme.titleFont
        bodyFont = style.bodyFont ?? theme.bodyFont
        textSize = CGFloat(style.textSize ?? 15)
        lineSpacing = CGFloat(style.lineSpacing ?? 1.0)
        width = style.width ?? .medium
    }

    // AppKit colors
    var nsBackground: NSColor { NSColor(hex: theme.background) }
    var nsSurface: NSColor { NSColor(hex: theme.surface) }
    var nsText: NSColor { NSColor(hex: theme.text) }
    var nsSecondary: NSColor { NSColor(hex: theme.secondary) }
    var nsTertiary: NSColor { NSColor(hex: theme.tertiary) }
    var nsAccent: NSColor { NSColor(hex: accent.hex) }

    // SwiftUI colors
    var background: Color { Color(nsColor: nsBackground) }
    var surface: Color { Color(nsColor: nsSurface) }
    var text: Color { Color(nsColor: nsText) }
    var secondary: Color { Color(nsColor: nsSecondary) }
    var tertiary: Color { Color(nsColor: nsTertiary) }
    var accentColor: Color { Color(nsColor: nsAccent) }
    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Mix toward another color by `amount` (0…1).
    func mixed(with other: NSColor, _ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: other) ?? self
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
