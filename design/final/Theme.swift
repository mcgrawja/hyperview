//
//  Theme.swift
//  Hyperview — "Serene" visual identity
//
//  Single source of truth for the app's color, shape, and type tokens.
//  Drop-in replacement for the previous placeholder Theme.swift.
//
//  Design decisions (see README for full rationale):
//   • Two accent CHANNELS, never merged:
//       Palette.primary  — ordinary interactive elements (buttons, links, selection, calendar/reminders accents)
//       Palette.claude   — AI surfaces ONLY (chat, daily briefing, "Ask Claude", AI buttons)
//   • Positive / done / success intentionally uses the SAME blue as `primary`
//     (no green anywhere — deliberate, per design review).
//   • Dark mode is first-class; every surface/text token is defined for both appearances.
//   • Semantic colors are tuned to pass contrast on `surface` in both appearances.
//
//  NOTE: Accents & semantics are appearance-INDEPENDENT (one value for light & dark).
//        Surfaces, text, and separator are appearance-DEPENDENT.
//

import SwiftUI

// MARK: - Adaptive color helper

extension Color {
    /// Resolves to `light` or `dark` based on the current NSAppearance.
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

    /// Hex initializer, e.g. Color(hex: 0x3E8EF7)
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Theme

enum Theme {

    // MARK: Palette
    enum Palette {

        // ── Accent channels ──────────────────────────────────────────────
        /// Ordinary interactive elements. Blue.
        static let primary = Color(hex: 0x3E8EF7)
        /// AI surfaces ONLY (Claude chat, briefing, AI buttons). Warm amber.
        static let claude  = Color(hex: 0xF2A65A)

        // ── Surfaces (appearance-dependent) ──────────────────────────────
        /// Window background.
        static let bg = Color(
            light: Color(hex: 0xE7EAEF),
            dark:  Color(hex: 0x1B1D21)
        )
        /// Content background — cards, panes.
        static let surface = Color(
            light: Color(hex: 0xFFFFFF),
            dark:  Color(hex: 0x24262B)
        )
        /// Raised background — fields, chips, segmented controls.
        static let surfaceRaised = Color(
            light: Color(hex: 0xF1F3F7),
            dark:  Color(hex: 0x31343A)
        )

        // ── Text (appearance-dependent) ──────────────────────────────────
        static let textPrimary = Color(
            light: Color(hex: 0x1A1C20),
            dark:  Color(hex: 0xF1F3F6)
        )
        static let textSecondary = Color(
            light: Color(hex: 0x7F838C),
            dark:  Color(hex: 0x969AA3)
        )
        /// Text/icons placed ON a filled accent (primary or claude). Always white.
        static let textOnAccent = Color(hex: 0xFFFFFF)

        // ── Separator (appearance-dependent, translucent) ────────────────
        static let separator = Color(
            light: Color(hex: 0x000000, alpha: 0.08),
            dark:  Color(hex: 0xFFFFFF, alpha: 0.09)
        )

        // ── Semantic (appearance-independent) ────────────────────────────
        /// Success / done / in-range. Intentionally the SAME blue as `primary` — no green.
        static let success = Color(hex: 0x3E8EF7)
        static let warning = Color(hex: 0xF5B841)
        static let danger  = Color(hex: 0xE5624D)

        // ── Fixed (appearance-independent) ───────────────────────────────
        /// Email reading pane is always white "paper" regardless of appearance.
        /// The seam is intentional — see README.
        static let mailPaper     = Color(hex: 0xFFFFFF)
        static let mailPaperText = Color(hex: 0x1C1C1E)
    }

    // MARK: Shape
    enum Radius {
        static let card: CGFloat    = 16   // cards, panes
        static let control: CGFloat = 10   // buttons, fields, chips
    }

    // MARK: Typography — all system SF Pro
    enum Font {
        /// Body / UI text.
        static func ui(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)   // SF Pro Text
        }
        /// Display / headings (greeting, card titles, note titles).
        static func display(_ size: CGFloat, weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)   // SF Pro Display
        }
        /// Monospace (briefing action-items block, code).
        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced) // SF Mono
        }
    }
}

// MARK: - Tint helpers
//
// The mockup tints accents for soft backgrounds (e.g. selected mail row, badges,
// active sidebar item). In CSS this was `color-mix(in srgb, var(--primary) 14%, transparent)`.
// The SwiftUI equivalent is simply the accent at low opacity:

extension Color {
    /// Soft accent fill for selected rows / active nav (≈ CSS color-mix 14–18%).
    func softFill(_ opacity: Double = 0.16) -> Color { self.opacity(opacity) }
}
