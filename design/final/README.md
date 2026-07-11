# Handoff: Hyperview — "Serene" Visual Identity

## Overview
This package delivers the complete **"Serene"** visual identity for Hyperview — the native macOS (SwiftUI) app that unifies Jason's Apple-ecosystem life (Mail, Calendar, Reminders, Notes, Photos, Contacts) behind one dashboard with Claude AI woven throughout. It replaces the placeholder color scheme with a finalized token set for **both light and dark appearance**, keeps typography all-system (SF Pro), and preserves the app's hard design constraints.

The deliverable is exactly what the brief asked for: **final values for every token in the mockup's `:root` block + font names**, shipped through a single Swift token file.

## About the Design Files
The files in this bundle are **design references created in HTML** — a prototype showing the intended look, not production code to copy verbatim. `Hyperview Serene.dc.html` is a `.dc.html` component file; open the accompanying **`Hyperview Serene.preview.html`** in any browser to view it (it renders the full dashboard window with all modules, dark/light toggle top-right).

Your task is **not** to embed this HTML. It is to apply the finalized token values (provided ready-to-use in `Theme.swift`) to Hyperview's existing SwiftUI views, and to make sure every surface honors the constraints below. `Theme.swift` is real, paste-able Swift — the HTML is only there so you can see the target.

## Fidelity
**High-fidelity.** Colors, radii, and type roles are final. Use the exact hex values in `Theme.swift`. Match the token *roles* (which token paints which element), not the mockup's pixel layout — the app already has its own view hierarchy.

## The "Serene" direction — rationale
Built on documented drivers of aesthetic preference so the palette feels good, not just arbitrary:
- **Universal blue preference + processing fluency** — blue is the most cross-culturally preferred hue and lowers arousal; a calm sky-blue primary against near-neutral surfaces maximizes legibility.
- **Complementary warmth for AI** — the warm amber Claude accent is the blue's complementary; it's the single warm spark the eye is drawn to, so "this is AI" reads instantly.
- **Personality match** — calm, precise, quietly confident; "mission control for one person's life."

## Hard constraints (must hold in implementation)
1. **Two accent channels, never merged.**
   - `Theme.Palette.primary` (blue `#3E8EF7`) → ordinary interactive elements: buttons, links, selection highlights, active sidebar item, calendar/reminders accents, badges.
   - `Theme.Palette.claude` (amber `#F2A65A`) → **AI surfaces ONLY**: Claude chat bubbles, the daily briefing card's icon/accents, "Ask Claude" button, any AI-generated affordance. Never use `claude` for non-AI UI, and never use `primary` on an AI surface.
2. **No green.** Positive / done / success states use `Palette.success`, which is intentionally the **same blue** as `primary`. (Design review removed green entirely.)
3. **Native macOS feel** — subtle 1px separators (`Palette.separator`, translucent), no heavy borders or drop shadows. Lean on system vibrancy where the app already does.
4. **Dark mode is first-class.** Every surface/text/separator token has a distinct dark value (not an inversion). The app runs mostly in dark mode.
5. **Semantic colors pass contrast on `surface`** in both appearances.
6. **Email reading pane is always white "paper"** (`Palette.mailPaper` `#FFFFFF` bg, `Palette.mailPaperText` `#1C1C1E` text) regardless of appearance — industry standard. Make the seam between the app chrome and the white pane intentional (a clean `separator` edge), not an accident.

## Screens / Views
The reference renders the **Dashboard** with every module represented. Token roles apply identically across the rest of the app.

### Dashboard (main window)
- **Layout:** Two-column macOS window. Left **sidebar** (~242pt, `color-mix` of surface↔bg — approximate with `surface` over `bg`, or `surfaceRaised`), right **main** scroll area on `bg`.
  - Sidebar: traffic lights, nav list (Dashboard active, Calendar, Reminders w/ count, Notes, Mail w/ unread count), a divider, then **Claude** nav item in `claude`, an optional pinned Claude preview card, and a user footer.
  - Active nav item: text + icon in `primary`, background `primary.softFill(0.18)`. The Claude nav item uses `claude` for its text/icon instead.
  - Main header: greeting in `Font.display(28, .bold)` `textPrimary`, date in `textSecondary`; right-aligned "＋ New" (`surfaceRaised` fill, `separator` border, `textPrimary`) and "✦ Ask Claude" (`claude` fill, `textOnAccent`).
- **Module cards** (all: `surface` bg, 1px `separator` border, `Radius.card` = 16pt corner, ~18–22pt padding):
  - **Today's Briefing (AI):** icon `✦` and "Generated…" pill in `claude`; weather strip (6 cells, hot cell tinted `danger.softFill`); advisory line in `danger`; narrative in `textPrimary` with the person's name emphasized in `claude`. This is an AI surface → amber accents only.
  - **Today (Calendar):** icon/badge in `primary`; rows with tabular-nums time in `textSecondary`, title in `textPrimary`, `separator` row dividers.
  - **Due Soon (Reminders):** icon/badge in `primary`; unchecked box = 2px `textSecondary` border; **checked box = `success` fill (blue) with white ✓**, label struck-through in `textSecondary`; overdue meta in `danger`.
  - **Notes:** icon in `primary`; note title in `Font.display(15)`; checklist same checkbox rules as above; quoted line uses a 2px `primary` left border.
  - **Mail:** icon/unread pill in `primary`; sender in `textPrimary`, subject in `textSecondary`, unread dot in `primary`, AI affordance `✦` in `claude`; **the reading pane below is white paper** (`mailPaper` / `mailPaperText`) with an intentional `separator` seam.

## Interactions & Behavior
- **Appearance:** honor the system light/dark setting via the adaptive `Color(light:dark:)` tokens; no manual theme switching needed in production (the toggle in the HTML is a review aid only).
- **Selection / hover:** selected mail row and active nav use `primary.softFill()` (≈14–18% opacity). Hover can raise to a slightly higher opacity of the same.
- **AI affordances:** anything Claude-driven animates/【accents】in `claude`; keep this consistent so the AI/non-AI distinction never blurs.

## Design Tokens
All values are in `Theme.swift`, ready to paste. Summary:

**Accents (appearance-independent)**
- primary `#3E8EF7` · claude `#F2A65A`

**Semantic (appearance-independent)**
- success `#3E8EF7` (blue, = primary) · warning `#F5B841` · danger `#E5624D`
- textOnAccent `#FFFFFF`

**Surfaces / text / separator (light → dark)**
- bg `#E7EAEF` → `#1B1D21`
- surface `#FFFFFF` → `#24262B`
- surfaceRaised `#F1F3F7` → `#31343A`
- textPrimary `#1A1C20` → `#F1F3F6`
- textSecondary `#7F838C` → `#969AA3`
- separator `rgba(0,0,0,0.08)` → `rgba(255,255,255,0.09)`

**Fixed (both appearances)**
- mailPaper `#FFFFFF` · mailPaperText `#1C1C1E`

**Shape**
- radius-card 16pt · radius-control 10pt

**Typography — all system SF Pro**
- UI/body → `SF Pro Text` (`.system(design: .default)`)
- Display/headings → `SF Pro Display` (`.system(design: .default)`)
- Mono (briefing action-items block) → `SF Mono` (`.system(design: .monospaced)`)

> A note on `--font-display`: the original placeholder used *SF Pro Rounded*. This direction recommends **SF Pro Display** to match the "precise, quietly confident" personality. If you prefer the softer feel, swap `Theme.Font.display` to `design: .rounded` — it's a one-line change and does not affect any color token.

## Assets
None. No images, no custom fonts — everything is system SF Pro and SF Symbols. Use SF Symbols for the nav/section icons (calendar, checklist, note, envelope, sparkle for Claude, gear).

## App icon
**Deferred** — not part of this handoff. Color/type system first, per the review.

## Files
- `Theme.swift` — the deliverable. Paste-ready SwiftUI token file (adaptive colors, radii, fonts, tint helpers).
- `Hyperview Serene.preview.html` — open in a browser to view the full dashboard reference (dark/light toggle top-right).
- `Hyperview Serene.dc.html` — source of the reference component (same design).
- `README.md` — this file.
