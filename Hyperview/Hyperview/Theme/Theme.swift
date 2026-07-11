//
//  Theme.swift
//  Hyperview — "Serene" visual identity (design/final/, 2026-07-11)
//
//  D11 / §8 — the ONLY place a color, font, radius, or spacing constant may be
//  defined. Every view reads from `Theme`.
//
//  Serene rules (see design/final/README.md):
//   • Two accent CHANNELS, never merged:
//       Palette.primary — ordinary interactive elements (buttons, links,
//       selection, calendar/reminders accents, badges)
//       Palette.claude  — AI surfaces ONLY (chat, daily briefing, Ask Claude)
//   • NO GREEN: success/done is intentionally the SAME blue as `primary`.
//   • Dark mode first-class — every surface/text token has its own dark value.
//   • Mail reading pane is ALWAYS white paper (`mailPaper`/`mailPaperText`).
//   • Subtle translucent 1px separators; no heavy borders or drop shadows.
//

import SwiftUI

/// Namespaced design tokens. Purely static — no state, no instances.
enum Theme {

    // MARK: - Color palette (Serene)

    enum Palette {
        /// Primary interactive accent — calm sky blue.
        static let primary = Color(hex: 0x3E8EF7)
        /// Reserved exclusively for Claude / AI surfaces — warm amber
        /// (the blue's complement; the one warm spark in the UI).
        static let claude = Color(hex: 0xF2A65A)

        // Surfaces (appearance-dependent; dark values are tuned, not inverted).
        static let background = Color(
            light: Color(hex: 0xE7EAEF),
            dark: Color(hex: 0x1B1D21)
        )
        static let surface = Color(
            light: Color(hex: 0xFFFFFF),
            dark: Color(hex: 0x24262B)
        )
        static let surfaceRaised = Color(
            light: Color(hex: 0xF1F3F7),
            dark: Color(hex: 0x31343A)
        )

        // Text
        static let textPrimary = Color(
            light: Color(hex: 0x1A1C20),
            dark: Color(hex: 0xF1F3F6)
        )
        static let textSecondary = Color(
            light: Color(hex: 0x7F838C),
            dark: Color(hex: 0x969AA3)
        )
        static let textOnAccent = Color(hex: 0xFFFFFF)

        // Semantic
        static let separator = Color(
            light: Color(hex: 0x000000, opacity: 0.08),
            dark: Color(hex: 0xFFFFFF, opacity: 0.09)
        )
        /// Success/done — intentionally the SAME blue as `primary` (no green).
        static let success = Color(hex: 0x3E8EF7)
        static let warning = Color(hex: 0xF5B841)
        static let danger = Color(hex: 0xE5624D)

        // Fixed (both appearances): the email reading pane is white paper.
        static let mailPaper = Color(hex: 0xFFFFFF)
        static let mailPaperText = Color(hex: 0x1C1C1E)
    }

    // MARK: - Typography (all system SF Pro; Display for headings per Serene)

    enum Font {
        static let dashboardTitle = SwiftUI.Font.system(.largeTitle, design: .default).weight(.bold)
        static let cardTitle = SwiftUI.Font.system(.headline, design: .default)
        static let cardBody = SwiftUI.Font.system(.body)
        static let cardCaption = SwiftUI.Font.system(.caption)
        static let metricNumber = SwiftUI.Font.system(.title, design: .default).weight(.semibold)
        /// Monospace — briefing action-items block, code.
        static let mono = SwiftUI.Font.system(.body, design: .monospaced)
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner radii

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let pill: CGFloat = 999
    }

    // MARK: - Elevation (Serene: avoid shadows; kept for legacy call sites)

    enum Shadow {
        static let card = (color: Color.black.opacity(0.06), radius: CGFloat(10), y: CGFloat(3))
    }
}

// MARK: - Color helpers (kept here so no view constructs a raw color)

extension Color {
    /// Resolves to `light` or `dark` with the current appearance.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        self = Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    /// Build a color from a 24-bit hex literal, e.g. `Color(hex: 0x3E8EF7)`.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Parse "#RRGGBB" (leading # optional). Nil for anything else.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// "#RRGGBB" of this color in sRGB (for persisting user-picked colors).
    var hexRGB: String? {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        #endif
    }

    /// Soft accent fill for selected rows / active nav — the SwiftUI
    /// equivalent of the mockup's `color-mix(… 14–18%, transparent)`.
    func softFill(_ opacity: Double = 0.16) -> Color { self.opacity(opacity) }
}
