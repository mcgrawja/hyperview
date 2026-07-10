//
//  NoteEditorWebView.swift
//  Hyperview
//
//  Hosts the bundled editor in a WKWebView and implements the Swift half of the
//  §5 bridge. The editor JS is a black box behind the bridge contract, so the
//  interim contentEditable page and a future TipTap bundle are interchangeable.
//
//  macOS-first (D6 / Risk #4); the iOS editor gets its own hardening pass, so a
//  lightweight placeholder stands in on non-macOS for now.
//

import SwiftUI
import SwiftData

#if os(macOS)
import WebKit
import AppKit

/// Bridge ↔ NotesView signals. One editor exists at a time (the host is
/// re-created per selected note), so app-wide notifications are unambiguous.
extension Notification.Name {
    /// JS asked for the note picker (slash command "Link to note").
    static let hyperviewRequestNoteLink = Notification.Name("hyperview.requestNoteLink")
    /// NotesView picked a note; userInfo: ["href": String, "text": String].
    static let hyperviewInsertNoteLink = Notification.Name("hyperview.insertNoteLink")
    /// A hyperview://note/<uuid> link was clicked; userInfo: ["id": UUID].
    static let hyperviewOpenNote = Notification.Name("hyperview.openNote")
}

/// Security-scoped bookmarks for "Link to file" — the sandbox forgets
/// NSOpenPanel grants at quit; a stored bookmark restores access on click.
@MainActor
enum FileLinkBookmarks {
    private static let key = "notes.fileLinkBookmarks"

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var bookmarks = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        bookmarks[url.absoluteString] = data
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    static func open(_ href: String) {
        if let bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
           let data = bookmarks[href] {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open(url)
                // Long enough for the target app to open the document.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }
        }
        // No bookmark (link made elsewhere / defaults cleared) — best effort.
        if let url = URL(string: href) { NSWorkspace.shared.open(url) }
    }
}

struct NoteEditorWebView: NSViewRepresentable {
    let note: Note
    let store: NotesStore

    func makeCoordinator() -> EditorBridge { EditorBridge(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "hyperview")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // let SwiftUI background show
        context.coordinator.attach(webView)

        if let url = Self.editorURL() {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(note)
    }

    static func editorURL() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }
}

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
        // NotesView answers a requestNoteLink by posting the picked note here.
        insertLinkToken = NotificationCenter.default.addObserver(
            forName: .hyperviewInsertNoteLink,
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

    /// Called by `updateNSView` when the selected note (or view state) changes.
    func show(_ note: Note) {
        self.note = note
        guard isReady, note.id != loadedNoteID else { return }
        loadDocument(for: note)
    }

    // MARK: JS -> Swift

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        MainActor.assumeIsolated {
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
                NotificationCenter.default.post(name: .hyperviewRequestNoteLink, object: nil)

            case "requestFileLink":
                pickFileLink()

            case "openLink":
                if let href = body["href"] as? String { openLink(href) }

            default:
                break
            }
        }
    }

    // MARK: Link handling

    /// "Link to file" slash command: pick a file, remember a security-scoped
    /// bookmark, insert a file:// link.
    private func pickFileLink() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to link in this note"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileLinkBookmarks.save(url)
        insertLink(href: url.absoluteString, text: url.lastPathComponent)
    }

    /// Route a clicked link by scheme: note links navigate in-app, file links
    /// open in their default app (via the stored bookmark), everything else
    /// goes to the system.
    private func openLink(_ href: String) {
        if href.hasPrefix("hyperview://note/") {
            let raw = String(href.dropFirst("hyperview://note/".count))
            if let id = UUID(uuidString: raw) {
                NotificationCenter.default.post(name: .hyperviewOpenNote, object: nil, userInfo: ["id": id])
            }
            return
        }
        if href.hasPrefix("file://") {
            FileLinkBookmarks.open(href)
            return
        }
        if let url = URL(string: href) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Insert a link at the cursor (note picker / file picker results).
    private func insertLink(href: String, text: String) {
        let hrefLiteral = Self.jsLiteral(href)
        let textLiteral = Self.jsLiteral(text)
        webView?.evaluateJavaScript(
            "window.hyperview.insertLink(\(hrefLiteral), \(textLiteral));",
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
        webView?.evaluateJavaScript("window.hyperview.loadDocument(\(literal));", completionHandler: nil)
        loadedNoteID = note.id
    }
}

#else

/// Non-macOS placeholder until the iOS editor hardening pass (Risk #4).
struct NoteEditorWebView: View {
    let note: Note
    let store: NotesStore
    var body: some View {
        Text("The editor is available on macOS.")
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
