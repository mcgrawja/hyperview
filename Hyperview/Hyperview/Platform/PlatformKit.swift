//
//  PlatformKit.swift
//  Unifyr
//
//  The thin AppKit/UIKit seam. Shared views import THIS, never AppKit — so a
//  view stays platform-agnostic and only genuinely Mac-only modules (Messages,
//  Drive, the MCP server) carry `#if os(macOS)` guards.
//

import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

enum PlatformKit {
    /// Open a URL in the system's default handler.
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Reveal a file in Finder. No equivalent on iOS — falls back to opening it.
    @MainActor
    static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        open(url)
        #endif
    }

    /// Copy plain text to the clipboard.
    @MainActor
    static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Bring the app to the front (macOS); a no-op on iOS.
    @MainActor
    static func activateApp() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    /// Ask the user for folders. macOS has a synchronous panel (NSOpenPanel);
    /// iOS has none — callers there present SwiftUI's `.fileImporter` instead,
    /// so this returns nil to mean "no panel on this platform" (an empty array
    /// means the user cancelled).
    @MainActor
    static func pickFolders(message: String, prompt: String) -> [URL]? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
        #else
        return nil
        #endif
    }

    /// The system's icon for a file. macOS only — iOS has no equivalent API, so
    /// callers there fall back to Quick Look (or an SF Symbol for the type).
    @MainActor
    static func fileIcon(for url: URL) -> PlatformImage? {
        #if os(macOS)
        return NSWorkspace.shared.icon(forFile: url.path)
        #else
        return nil
        #endif
    }
}

// MARK: - Layout size

extension EnvironmentValues {
    /// True when the UI must show ONE pane at a time (iPhone). iPad and Mac are
    /// "regular" and keep their multi-pane layouts.
    ///
    /// This MUST be a real key-backed entry: a *derived* computed property on
    /// EnvironmentValues (e.g. `horizontalSizeClass == .compact`) does NOT work
    /// with `@Environment` — views read the default instead of the live value,
    /// which silently gave the iPhone the 3-pane desktop layout.
    /// `resolveCompactLayout()` fills it in from the real size class.
    @Entry var isCompactLayout: Bool = false
}

/// Reads the true horizontal size class and publishes it as
/// `\.isCompactLayout`. Applied once at the app root.
private struct CompactLayoutResolver: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.isCompactLayout, sizeClass == .compact)
        #else
        content.environment(\.isCompactLayout, false)
        #endif
    }
}

extension View {
    /// Publish the real size class as `\.isCompactLayout`. Apply at the root.
    func resolveCompactLayout() -> some View {
        modifier(CompactLayoutResolver())
    }
}

// MARK: - Cross-platform view styles

extension View {
    /// `.checkbox` on macOS; iOS has no checkbox style, so it falls back to the
    /// platform default (a switch), which is the native idiom there anyway.
    @ViewBuilder
    func platformCheckbox() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// Inline navigation-bar title on iOS; a no-op on macOS (which has no
    /// navigation bar).
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// A compact date field: `.field` on macOS, `.compact` on iOS.
    @ViewBuilder
    func platformFieldDatePicker() -> some View {
        #if os(macOS)
        self.datePickerStyle(.field)
        #else
        self.datePickerStyle(.compact)
        #endif
    }

    /// Show the horizontal-resize cursor while the pointer is over this view
    /// (macOS). iOS has no cursor, so it's a no-op there.
    @ViewBuilder
    func platformResizeCursor() -> some View {
        #if os(macOS)
        self.onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        #else
        self
        #endif
    }
}

/// `HSplitView` (draggable panes) on macOS; a plain `HStack` on iOS, which has
/// no such control.
///
/// Only ever use this on REGULAR-width layouts (Mac, iPad). On a phone the
/// panes' minimum widths exceed the screen, so SwiftUI resolves a negative
/// width and traps with "Invalid frame dimension". Compact layouts must use
/// `\.isCompactLayout` and navigate one pane at a time instead.
struct PlatformHSplit<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        HSplitView(content: content)
        #else
        HStack(spacing: 0, content: content)
        #endif
    }
}

// MARK: - Image bridging

extension Image {
    /// Build a SwiftUI Image from the platform's native image type.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Wrap a CGImage — Quick Look hands its thumbnails back as CGImages on
    /// both platforms, so this is the one bridge a caller needs.
    static func fromCGImage(_ image: CGImage) -> PlatformImage {
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }

    /// Load an image from a file path (nil if it isn't a readable image).
    static func fromFile(_ path: String) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOfFile: path)
        #else
        return UIImage(contentsOfFile: path)
        #endif
    }

    /// PNG data for this image.
    var pngData: Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}
