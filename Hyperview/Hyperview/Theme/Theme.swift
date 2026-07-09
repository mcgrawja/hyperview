//
//  Theme.swift
//  Hyperview
//
//  D11 / §8 — PLACEHOLDER visual design. This file is the ONLY place a color,
//  font, radius, or spacing constant may be defined. Every view reads from
//  `Theme`. The final scheme arrives later from a Claude Design session and is
//  swapped in here without touching any view. Do not hardcode a color anywhere
//  else in the app.
//

import SwiftUI

/// Namespaced design tokens. Purely static — no state, no instances.
enum Theme {

    // MARK: - Color palette (placeholder: light-blue primary, orange = Claude/AI)

    enum Palette {
        /// Primary brand / interactive accent. Placeholder `#4A90D9`.
        static let primary = Color(hex: 0x4A90D9)
        /// Reserved exclusively for Claude / AI surfaces. Placeholder `#F58B3C`.
        static let claude = Color(hex: 0xF58B3C)

        // Surfaces adapt to light/dark automatically via system materials.
        static let background = Color(nsPlatformColor: .windowBackground)
        static let surface = Color(nsPlatformColor: .contentBackground)
        static let surfaceRaised = Color(nsPlatformColor: .raisedBackground)

        // Text
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textOnAccent = Color.white

        // Semantic
        static let separator = Color.primary.opacity(0.08)
        static let success = Color(hex: 0x3CB371)
        static let warning = Color(hex: 0xF5A623)
        static let danger = Color(hex: 0xE0533D)
    }

    // MARK: - Typography (system SF per §8)

    enum Font {
        static let dashboardTitle = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let cardTitle = SwiftUI.Font.system(.headline, design: .rounded)
        static let cardBody = SwiftUI.Font.system(.body)
        static let cardCaption = SwiftUI.Font.system(.caption)
        static let metricNumber = SwiftUI.Font.system(.title, design: .rounded).weight(.semibold)
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

    // MARK: - Elevation

    enum Shadow {
        static let card = (color: Color.black.opacity(0.08), radius: CGFloat(12), y: CGFloat(4))
    }
}

// MARK: - Color helpers (kept here so no view constructs a raw color)

extension Color {
    /// Build a color from a 24-bit hex literal, e.g. `Color(hex: 0x4A90D9)`.
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
}

/// Cross-platform system surface colors, resolved once here so the rest of the
/// app stays platform-agnostic. macOS-first (D8/Phase order); iOS fills in the
/// same token names.
private extension Color {
    enum PlatformColor {
        case windowBackground, contentBackground, raisedBackground
    }

    init(nsPlatformColor token: PlatformColor) {
        #if os(macOS)
        switch token {
        case .windowBackground: self = Color(nsColor: .windowBackgroundColor)
        case .contentBackground: self = Color(nsColor: .controlBackgroundColor)
        case .raisedBackground: self = Color(nsColor: .underPageBackgroundColor)
        }
        #else
        switch token {
        case .windowBackground: self = Color(uiColor: .systemBackground)
        case .contentBackground: self = Color(uiColor: .secondarySystemBackground)
        case .raisedBackground: self = Color(uiColor: .tertiarySystemBackground)
        }
        #endif
    }
}
