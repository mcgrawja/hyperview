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

    init(store: NotesStore) { self.store = store }

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

            default:
                break
            }
        }
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
