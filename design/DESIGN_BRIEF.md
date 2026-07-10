# Hyperview — Design Brief

*Hand this file (and `hyperview-mockup.html`) to the design session verbatim.*

## What Hyperview is

A native macOS app (SwiftUI) that unifies one person's Apple-ecosystem life —
Mail, Calendar, Reminders, Notes (Notion-lite), Photos, Contacts — behind a
single dashboard, with Claude AI integrated throughout (an in-app chat, an
auto-generated daily briefing, and an MCP server that lets Claude Desktop act
on the data). Single user: Jason. Personal tool, not a commercial product —
but it should feel like one.

## The ask

A complete visual identity to replace the current placeholder scheme:

1. **Color system** — every token in the mockup's `:root` block, for BOTH
   light and dark appearance. The app is used mostly in dark mode.
2. **Typography direction** — currently SF Pro (system). May stay system, or
   propose display/mono pairings available on macOS.
3. **An app icon concept** — macOS squircle, works at 16px and 512px.

## Hard constraints

- **Two accent channels, never merged:** a PRIMARY accent for ordinary
  interactive elements, and a distinct AI accent used EXCLUSIVELY for
  Claude/AI surfaces (chat, briefing, AI buttons). A user must always know
  at a glance whether they're touching AI. Current placeholders: blue
  #4A90D9 primary, orange #F58B3C AI.
- **Native macOS feel** — this sits beside Mail.app and Things, not a web
  app. Respect vibrancy/subtlety norms; no heavy borders or drop shadows.
- **Dark mode is first-class**, not an inversion afterthought.
- **Semantic colors** (success/warning/danger) must read correctly against
  both appearances and pass contrast on `surface`.
- **Email content is rendered on white "paper"** inside the mail reading
  pane regardless of appearance (industry standard) — the design should
  make that seam intentional.
- Everything ships through a single Swift token file, so the deliverable is
  literally: final values for each CSS variable in the mockup + font names.

## Personality targets

Calm, precise, quietly confident. "Mission control for one person's life."
Not playful, not corporate. The AI accent should feel warm/alive against a
cool, steady base — or propose an inverted take and argue for it.

## How to work with the mockup

Open `hyperview-mockup.html` in a browser. All tokens live in the `:root`
block at the top (dark values in the `@media (prefers-color-scheme: dark)`
block; the ☀/🌙 button forces either). Edit variables, reload, judge every
surface at once: dashboard w/ weather + briefing, mail three-pane, notes
editor, Claude chat. Propose 3–4 distinct directions as full variable sets
(background hex / accent hex / AI hex / typeface + one-line rationale each),
then refine the chosen one.
