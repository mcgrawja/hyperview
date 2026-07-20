//
//  NoteEditorWebView.swift
//  Unifyr
//
//  Hosts the bundled TipTap editor in a WKWebView and implements the Swift half
//  of the §5 bridge. The editor JS is a black box behind the bridge contract, so
//  the SAME bundle drives both platforms — only the hosting view (NSView vs
//  UIView) and the file-link plumbing differ.
//

import SwiftUI
import SwiftData
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bookmarks for "Link to file" so a linked file stays reachable across
/// launches. macOS uses security-scoped bookmarks (the sandbox forgets
/// NSOpenPanel grants at quit); iOS bookmarks document-picker URLs the same way
/// but without the macOS-only security-scope option.
@MainActor
enum FileLinkBookmarks {
    private static let key = "notes.fileLinkBookmarks"

    static func save(_ url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var bookmarks = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        bookmarks[url.absoluteString] = data
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    /// Resolve a stored bookmark back to a usable, access-started URL.
    static func resolve(_ href: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
              let data = bookmarks[href] else {
            return URL(string: href)
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return URL(string: href)
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    #if os(macOS)
    /// macOS opens the file in its default app.
    static func open(_ href: String) {
        guard let url = resolve(href) else { return }
        NSWorkspace.shared.open(url)
        // Long enough for the target app to open the document.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            url.stopAccessingSecurityScopedResource()
        }
    }
    #endif
}

// MARK: - The hosting view (platform-specific shell, shared bridge)

struct NoteEditorWebView {
    let note: Note
    let store: NotesStore

    func makeCoordinator() -> EditorBridge { EditorBridge(store: store) }

    /// Builds the configured web view — identical on both platforms.
    fileprivate func makeWebView(coordinator: EditorBridge) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(coordinator, name: "hyperview")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        // Let the SwiftUI background show through.
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        coordinator.attach(webView)

        if let url = Self.editorURL() {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    static func editorURL() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }
}

#if os(macOS)
extension NoteEditorWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(note)
    }
}
#else
extension NoteEditorWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(note)
    }
}
#endif

// MARK: - Bridge

/// The bridge coordinator: routes messages both ways for one editor instance.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let store: NotesStore
    private weak var webView: WKWebView?
    private var isReady = false
    private var note: Note?
    private var loadedNoteID: UUID?
    // Token only crosses to removeObserver; safe to share.
    nonisolated(unsafe) private var insertLinkToken: (any NSObjectProtocol)?

    init(store: NotesStore) {
        self.store = store
        super.init()
        // NotesView answers a requestNoteLink / requestFileLink by posting the
        // chosen link back here.
        insertLinkToken = NotificationCenter.default.addObserver(
            forName: .unifyrInsertNoteLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let href = notification.userInfo?["href"] as? String
            let text = notification.userInfo?["text"] as? String
            MainActor.assumeIsolated {
                guard let href else { return }
                self?.insertLink(href: href, text: text ?? href)
            }
        }
    }

    deinit {
        if let insertLinkToken {
            NotificationCenter.default.removeObserver(insertLinkToken)
        }
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    /// Called when the selected note (or view state) changes.
    func show(_ note: Note) {
        self.note = note
        guard isReady, note.id != loadedNoteID else { return }
        loadDocument(for: note)
    }

    // MARK: JS -> Swift

    /// WebKit delivers script messages on the main actor (and WKScriptMessage's
    /// properties are main-actor isolated), so this stays MainActor-isolated
    /// with the class.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            if let note { loadDocument(for: note) }

        case "documentChanged":
            guard let note,
                  let docObject = body["doc"],
                  let data = try? JSONSerialization.data(withJSONObject: docObject) else { return }
            let document = BlockSerializer.decodeDocument(data)
            store.save(document, to: note)
            try? store.context.save()

        case "blockAction":
            // Persisted via the following documentChanged; logged here for the
            // future in-app audit view (§7 safety defaults).
            break

        case "requestNoteLink":
            // The picker lives in NotesView (it has the note list).
            NotificationCenter.default.post(name: .unifyrRequestNoteLink, object: nil)

        case "requestFileLink":
            pickFileLink()

        case "openLink":
            if let href = body["href"] as? String { openLink(href) }

        default:
            break
        }
    }

    // MARK: Link handling

    /// "Link to file": macOS opens an NSOpenPanel right here; iOS has no modal
    /// panel, so NotesView presents the document picker (.fileImporter) and
    /// posts the result back through .unifyrInsertNoteLink.
    private func pickFileLink() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to link in this note"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileLinkBookmarks.save(url)
        insertLink(href: url.absoluteString, text: url.lastPathComponent)
        #else
        NotificationCenter.default.post(name: .unifyrRequestFileLink, object: nil)
        #endif
    }

    /// Route a clicked link by scheme: note links navigate in-app, file links
    /// open (Finder's default app on macOS; a Quick Look preview on iOS), and
    /// everything else goes to the system browser.
    private func openLink(_ href: String) {
        if href.hasPrefix("hyperview://note/") {
            let raw = String(href.dropFirst("hyperview://note/".count))
            if let id = UUID(uuidString: raw) {
                NotificationCenter.default.post(name: .unifyrOpenNote, object: nil, userInfo: ["id": id])
            }
            return
        }
        if href.hasPrefix("file://") {
            #if os(macOS)
            FileLinkBookmarks.open(href)
            #else
            // NotesView owns the Quick Look preview sheet.
            NotificationCenter.default.post(
                name: .unifyrOpenFileLink, object: nil, userInfo: ["href": href]
            )
            #endif
            return
        }
        if let url = URL(string: href) {
            PlatformKit.open(url)
        }
    }

    /// Insert a link at the cursor (note picker / file picker results).
    private func insertLink(href: String, text: String) {
        let hrefLiteral = Self.jsLiteral(href)
        let textLiteral = Self.jsLiteral(text)
        webView?.evaluateJavaScript(
            "window.unifyr.insertLink(\(hrefLiteral), \(textLiteral));",
            completionHandler: nil
        )
    }

    private static func jsLiteral(_ string: String) -> String {
        String(decoding: (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: Swift -> JS

    private func loadDocument(for note: Note) {
        let document = store.loadDocument(note)
        let json = String(decoding: BlockSerializer.encode(document), as: UTF8.self)
        // Encode the JSON string as a JS string literal (safe escaping).
        let literal = String(decoding: (try? JSONEncoder().encode(json)) ?? Data("\"{}\"".utf8), as: UTF8.self)
        webView?.evaluateJavaScript("window.unifyr.loadDocument(\(literal));", completionHandler: nil)
        loadedNoteID = note.id
    }
}
