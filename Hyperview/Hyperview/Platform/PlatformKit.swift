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
}

// MARK: - Layout size

extension EnvironmentValues {
    /// True when the UI must show ONE pane at a time (iPhone portrait). iPad
    /// and Mac are always "regular" and keep their multi-pane layouts.
    var isCompactLayout: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
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
}

/// `HSplitView` (draggable panes) on macOS; a plain `HStack` on iOS, which has
/// no such control. Phase 2 replaces the iOS side with proper adaptive
/// navigation (columns on iPad, stacked on iPhone).
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
