# Handoff: App Icon — "Notes-first / Tinted document" (3e)

## Overview
A macOS + iOS app icon for a productivity app that combines note-taking with a
calendar. The mark is an outlined document (notes) with a solid-blue calendar
tile bearing a white check overlapping its lower-right corner — the "3e / Tinted
document" variation from the exploration.

## About the Design Files
The files in this bundle are **design references**. The `.svg` files are the
source of truth (crisp vector); the `.png` files are pre-rendered rasters at the
sizes Apple's asset catalogs need. Your task is to install these as the app icon
in the target Xcode project's asset catalog (`Assets.xcassets/AppIcon.appiconset`),
following the platform's standard icon pipeline — not to reproduce the SVG in code.

If you'd rather generate rasters yourself, render from the SVGs at 2×/3× to stay
sharp. Never scale the small PNGs up.

## Fidelity
**High-fidelity.** Final colors, geometry, and proportions. Match exactly.

## Art description
- **Document** (behind): rounded-rect sheet, soft-blue fill with a heavier blue
  outline and four blue ruled lines (last line shorter). Reads as "notes."
- **Calendar tile** (front, lower-right, overlapping): solid blue rounded square,
  darker blue header band with two hanger rings, white check mark across the face.
  Carries a soft drop shadow to lift it off the document.
- **Background**: subtle top-to-bottom light gradient (serene, near-white).

## Design tokens (exact hex)
- Background gradient: `#F4F7FC` (top) → `#E1E9F5` (bottom)
- Document fill: `#EAF1FC`
- Document outline: `#4C86E0`
- Document ruled lines: `#A9C6F0`
- Calendar body: `#3E8EF7`
- Calendar header: `#2A66CE`
- Calendar hanger rings: `#1E4A94`
- Check mark: `#FFFFFF`
- Tile drop shadow: `#12305F` @ ~20% opacity, y-offset 8, blur 14 (at 1024px)

## Geometry
Authored on a 200×200 grid, then placed on the 1024×1024 canvas.
- **iOS** (`AppIcon-iOS.svg`): full-bleed — background fills the entire 1024×1024
  square; the system applies the squircle mask. Do **not** round the corners
  yourself. Artwork centered at scale 4× (`translate(112,112) scale(4)`).
- **macOS** (`AppIcon-macOS.svg`): the visible icon is an 824×824 rounded square
  (corner radius 185) centered in 1024×1024 with transparent margin, per Apple's
  macOS icon grid. Artwork centered at scale 3.32×.

## Files
```
app_icon/
├── AppIcon-iOS.svg        ← vector master, full-bleed (iOS)
├── AppIcon-macOS.svg      ← vector master, rounded + margin (macOS)
├── ios/
│   ├── AppIcon-1024.png   ← App Store / universal
│   ├── AppIcon-180.png    ← iPhone @3x (60pt)
│   ├── AppIcon-120.png    ← iPhone @2x (60pt)
│   └── AppIcon-512.png
└── macos/
    ├── AppIcon-1024.png   ← 512pt @2x
    ├── AppIcon-512.png    ← 512pt @1x / 256pt @2x
    ├── AppIcon-256.png
    └── AppIcon-128.png
```

## Installing in Xcode

### Option A — single-size (Xcode 14+, recommended)
Modern Xcode accepts one 1024×1024 image and downscales for all slots.
1. Open `Assets.xcassets` → select (or add) an **AppIcon** set.
2. For iOS, drag `ios/AppIcon-1024.png` into the single "1024pt" well.
3. For macOS, use `macos/AppIcon-1024.png` (already rounded with margin).

### Option B — full slot set / CLI generation
Generate every required size from the SVG masters. Example using `rsvg-convert`
(or `sips` from a large PNG):

```bash
# iOS sizes (full-bleed, square)
for s in 40 58 60 80 87 120 180 1024; do
  rsvg-convert -w $s -h $s AppIcon-iOS.svg -o ios/icon_$s.png
done

# macOS .icns (rounded master)
mkdir AppIcon.iconset
for s in 16 32 64 128 256 512; do
  rsvg-convert -w $s          -h $s          AppIcon-macOS.svg -o AppIcon.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s*2))    -h $((s*2))    AppIcon-macOS.svg -o AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset
```

Then wire the generated files into `AppIcon.appiconset/Contents.json` (Xcode
writes this for you when you drag images into the slots).

## Notes
- iOS icons must be **opaque and full-bleed** — no transparency, no pre-rounded
  corners. That's why the iOS master paints the background edge to edge.
- macOS icons **do** include their own rounding and transparent margin — use the
  macOS master for those slots, not the iOS one.
- Both masters share the same artwork and palette; only background shape/inset
  differs.
