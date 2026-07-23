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
import UniformTypeIdentifiers

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

// MARK: - Editor documents

/// What the bridge edits: any block document that can round-trip through the
/// BlockSerializer. Notes load/save whole-note documents; database row pages
/// (Unifyr 1.5) load/save the blocks scoped to one row. The bridge itself only
/// ever sees this handle. `save` is responsible for persistence end to end
/// (reconcile AND context.save).
/// A page the editor can reference (mention menu entries, new sub-pages).
nonisolated struct EditorPageRef {
    let id: UUID
    let title: String
    let emoji: String?
}

@MainActor
struct EditorDocument {
    let id: UUID
    let load: () -> PMNode
    let save: (PMNode) -> Void
    /// Store pasted/dropped image bytes as an Asset owned by this document's
    /// note; returns the new asset id (image blocks reference it as
    /// `unifyr-asset://<uuid>`). nil = images unsupported in this context.
    let saveAsset: ((_ data: Data, _ filename: String, _ mimeType: String) -> UUID?)?
    /// The pages the "@" mention menu can link. nil = mentions disabled.
    let pageList: (() -> [EditorPageRef])?
    /// "/Sub-page": create a child page of this document's page and return it
    /// for inline embedding. nil = sub-pages unsupported (database row pages).
    let createSubpage: (() -> EditorPageRef?)?
    /// "/New database": create a seeded sub-database of this page and return
    /// it for inline embedding (Notion's one-step inline database).
    let createInlineDatabase: (() -> EditorPageRef?)?
    /// dbembed blocks: (databaseID, viewID) → snapshot JSON (editable payload),
    /// nil when the database is gone.
    let dbEmbedSnapshot: ((UUID, UUID?) -> String?)?
    /// An embed cell edit: (databaseID, rowID, propertyID, raw) → applied?
    let dbEmbedEdit: ((UUID, UUID, UUID, Any) -> Bool)?
    /// An embed "New" row: (databaseID, viewID) → the new row's id.
    let dbEmbedAddRow: ((UUID, UUID?) -> UUID?)?
    /// Full-width editing (PageProps.wideLayout); default is a centered column.
    var wide: Bool = false

    init(
        id: UUID,
        load: @escaping () -> PMNode,
        save: @escaping (PMNode) -> Void,
        saveAsset: ((Data, String, String) -> UUID?)? = nil,
        pageList: (() -> [EditorPageRef])? = nil,
        createSubpage: (() -> EditorPageRef?)? = nil,
        createInlineDatabase: (() -> EditorPageRef?)? = nil,
        dbEmbedSnapshot: ((UUID, UUID?) -> String?)? = nil,
        dbEmbedEdit: ((UUID, UUID, UUID, Any) -> Bool)? = nil,
        dbEmbedAddRow: ((UUID, UUID?) -> UUID?)? = nil,
        wide: Bool = false
    ) {
        self.id = id
        self.load = load
        self.save = save
        self.saveAsset = saveAsset
        self.pageList = pageList
        self.createSubpage = createSubpage
        self.createInlineDatabase = createInlineDatabase
        self.dbEmbedSnapshot = dbEmbedSnapshot
        self.dbEmbedEdit = dbEmbedEdit
        self.dbEmbedAddRow = dbEmbedAddRow
        self.wide = wide
    }

    /// A whole note (the Phase-2 path).
    init(note: Note, store: NotesStore) {
        self.id = note.id
        self.load = { store.loadDocument(note) }
        self.save = { document in
            store.save(document, to: note)
            try? store.context.save()
        }
        self.saveAsset = { data, filename, mimeType in
            let asset = Asset(noteID: note.id, filename: filename, mimeType: mimeType, data: data)
            store.context.insert(asset)
            try? store.context.save()
            return asset.id
        }
        self.pageList = {
            store.mentionablePages(excluding: note.id)
                .map { EditorPageRef(id: $0.id, title: $0.title, emoji: $0.emoji) }
        }
        self.createSubpage = {
            guard note.kind == .page, !note.isTrashed else { return nil }
            let child = store.createPage(parent: note)
            try? store.context.save()
            return EditorPageRef(id: child.id, title: child.title, emoji: child.emoji)
        }
        self.createInlineDatabase = {
            guard note.kind == .page, !note.isTrashed else { return nil }
            let child = store.createPage(parent: note)
            DatabaseStore(context: store.context).seedNewDatabase(child)
            try? store.context.save()
            return EditorPageRef(id: child.id, title: child.title, emoji: child.emoji)
        }
        self.dbEmbedSnapshot = { databaseID, viewID in
            DatabaseStore(context: store.context)
                .embedSnapshotJSON(databaseID: databaseID, viewID: viewID)
        }
        self.dbEmbedEdit = { databaseID, rowID, propertyID, raw in
            DatabaseStore(context: store.context)
                .applyEmbedEdit(databaseID: databaseID, rowID: rowID, propertyID: propertyID, raw: raw)
        }
        self.dbEmbedAddRow = { databaseID, viewID in
            DatabaseStore(context: store.context)
                .embedAddRow(databaseID: databaseID, viewID: viewID)
        }
        self.wide = note.pageProps.wideLayout ?? false
    }
}

// MARK: - The hosting view (platform-specific shell, shared bridge)

struct NoteEditorWebView {
    let document: EditorDocument
    @Environment(\.modelContext) private var modelContext

    init(note: Note, store: NotesStore) {
        self.document = EditorDocument(note: note, store: store)
    }

    init(document: EditorDocument) {
        self.document = document
    }

    func makeCoordinator() -> EditorBridge { EditorBridge() }

    /// Builds the configured web view — identical on both platforms.
    fileprivate func makeWebView(coordinator: EditorBridge) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(coordinator, name: "hyperview")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // Image blocks load their bytes straight from the Asset store.
        config.setURLSchemeHandler(
            AssetSchemeHandler(context: modelContext),
            forURLScheme: AssetSchemeHandler.scheme
        )

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
        context.coordinator.show(document)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: EditorBridge) {
        coordinator.teardown()
    }
}
#else
extension NoteEditorWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(document)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: EditorBridge) {
        coordinator.teardown()
    }
}
#endif

// MARK: - Bridge

/// The bridge coordinator: routes messages both ways for one editor instance.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var webView: WKWebView?
    private var isReady = false
    private var document: EditorDocument?
    private var loadedDocumentID: UUID?
    // Token only crosses to removeObserver; safe to share.
    nonisolated(unsafe) private var insertLinkToken: (any NSObjectProtocol)?

    // Tokens only cross to removeObserver; safe to share.
    nonisolated(unsafe) private var insertImageToken: (any NSObjectProtocol)?
    nonisolated(unsafe) private var insertDBEmbedToken: (any NSObjectProtocol)?

    override init() {
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
        // NotesView answers a requestImage (iOS) with the picked file's URL.
        insertImageToken = NotificationCenter.default.addObserver(
            forName: .unifyrInsertImageFile,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = notification.userInfo?["url"] as? URL
            MainActor.assumeIsolated {
                guard let url else { return }
                self?.storeAndInsertImage(from: url)
            }
        }
        // NotesView answers a requestDBEmbedPicker with the picked view.
        insertDBEmbedToken = NotificationCenter.default.addObserver(
            forName: .unifyrInsertDBEmbed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let id = notification.userInfo?["id"] as? UUID
            let viewID = notification.userInfo?["viewID"] as? UUID
            let title = notification.userInfo?["title"] as? String
            let emoji = notification.userInfo?["emoji"] as? String
            MainActor.assumeIsolated {
                guard let id, let title else { return }
                self?.insertDBEmbed(id: id, viewID: viewID, title: title, emoji: emoji)
            }
        }
    }

    deinit {
        if let insertLinkToken {
            NotificationCenter.default.removeObserver(insertLinkToken)
        }
        if let insertImageToken {
            NotificationCenter.default.removeObserver(insertImageToken)
        }
        if let insertDBEmbedToken {
            NotificationCenter.default.removeObserver(insertDBEmbedToken)
        }
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    /// Called when the edited document (or view state) changes.
    func show(_ document: EditorDocument) {
        // Switching documents: any pending (debounced) edits belong to the OLD
        // one — persist them before its content is swapped out.
        if document.id != loadedDocumentID { flushPendingSave() }
        self.document = document
        // Layout can change without a document switch (the ••• menu toggle).
        if isReady { applyWide(document.wide) }
        guard isReady, document.id != loadedDocumentID else { return }
        loadDocument(for: document)
    }

    private var appliedWide: Bool?

    private func applyWide(_ wide: Bool) {
        guard appliedWide != wide else { return }
        appliedWide = wide
        webView?.evaluateJavaScript(
            "window.hyperview.setWide(\(wide ? "true" : "false"));",
            completionHandler: nil
        )
    }

    /// Final teardown from the representable's dismantle: persist anything
    /// still buffered and detach the script handler (the content controller
    /// retains its handlers strongly).
    func teardown() {
        flushPendingSave()
        saveDebounce?.cancel()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: Debounced persistence

    // The JS editor emits the ENTIRE document on every keystroke. Persisting
    // each one did a full decode + reconcile + main-thread SwiftData save per
    // keystroke (and, under CloudKit, an upload storm). Instead the latest
    // document is buffered and persisted after a quiet gap — with flushes on
    // document switch and teardown so nothing is ever lost.
    private var pendingDocument: (id: UUID, document: EditorDocument, data: Data)?
    private var saveDebounce: Task<Void, Never>?

    private func bufferDocumentChange(_ document: EditorDocument, data: Data) {
        pendingDocument = (document.id, document, data)
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    private func flushPendingSave() {
        guard let pending = pendingDocument else { return }
        pendingDocument = nil
        saveDebounce?.cancel()
        pending.document.save(BlockSerializer.decodeDocument(pending.data))
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
            if let document { loadDocument(for: document) }

        case "editorError":
            // The JS editor failed to construct — make it loud in the app log
            // (a silent dead editor cost a debugging round once already).
            MailLog.log("[Editor] JS editor failed to initialize: \(body["message"] as? String ?? "unknown")")

        case "documentChanged":
            guard let document,
                  let docObject = body["doc"],
                  let data = try? JSONSerialization.data(withJSONObject: docObject) else { return }
            bufferDocumentChange(document, data: data)

        case "blockAction":
            // Persisted via the following documentChanged; logged here for the
            // future in-app audit view (§7 safety defaults).
            break

        case "requestNoteLink":
            // The picker lives in NotesView (it has the note list).
            NotificationCenter.default.post(name: .unifyrRequestNoteLink, object: nil)

        case "requestFileLink":
            pickFileLink()

        case "saveImage":
            // Pasted/dropped image arrives as a data URL; store it as an Asset
            // and hand back a unifyr-asset:// src (§4.2 — bytes never live in
            // block JSON, which CloudKit caps at record size).
            guard let dataURL = body["dataURL"] as? String else { return }
            let filename = (body["filename"] as? String) ?? "image.png"
            storeAndInsertImage(dataURL: dataURL, filename: filename)

        case "requestImage":
            pickImage()

        case "requestDBEmbedPicker":
            // The picker lives in NotesView (it has the sheet infrastructure).
            NotificationCenter.default.post(name: .unifyrRequestDBEmbedPicker, object: nil)

        case "requestDBEmbed":
            // A mounted dbembed block wants its preview data.
            guard let document,
                  let idString = body["databaseID"] as? String,
                  let databaseID = UUID(uuidString: idString),
                  let ref = body["ref"] as? String else { return }
            let viewID = (body["viewID"] as? String).flatMap(UUID.init(uuidString:))
            let snapshot = document.dbEmbedSnapshot?(databaseID, viewID)
            let refLiteral = Self.jsLiteral(ref)
            let snapshotLiteral = snapshot.map(Self.jsLiteral) ?? "null"
            webView?.evaluateJavaScript(
                "window.hyperview.deliverDBEmbed(\(refLiteral), \(snapshotLiteral));",
                completionHandler: nil
            )

        case "dbSetCell":
            // An embed input committed a cell edit.
            guard let document,
                  let databaseID = (body["databaseID"] as? String).flatMap(UUID.init(uuidString:)),
                  let rowID = (body["rowID"] as? String).flatMap(UUID.init(uuidString:)),
                  let propertyID = (body["propertyID"] as? String).flatMap(UUID.init(uuidString:)),
                  let raw = body["value"]
            else { return }
            if document.dbEmbedEdit?(databaseID, rowID, propertyID, raw) == true {
                refreshDBEmbeds(databaseID: databaseID)
            }

        case "dbAddRowEmbed":
            guard let document,
                  let databaseID = (body["databaseID"] as? String).flatMap(UUID.init(uuidString:))
            else { return }
            let viewID = (body["viewID"] as? String).flatMap(UUID.init(uuidString:))
            if document.dbEmbedAddRow?(databaseID, viewID) != nil {
                refreshDBEmbeds(databaseID: databaseID)
            }

        case "openDBRow":
            // The embed's ↗: navigate to the database AND latch the row so
            // DatabaseView opens its page once mounted.
            guard let databaseID = (body["databaseID"] as? String).flatMap(UUID.init(uuidString:)),
                  let rowID = (body["rowID"] as? String).flatMap(UUID.init(uuidString:))
            else { return }
            DeepLink.send(.unifyrOpenDBRow, userInfo: ["db": databaseID, "row": rowID])
            NotificationCenter.default.post(name: .unifyrOpenNote, object: nil, userInfo: ["id": databaseID])

        case "createSubpage":
            // "/Sub-page": Swift creates the child page, the editor embeds it.
            guard let document, let child = document.createSubpage?() else { return }
            let idLiteral = Self.jsLiteral(child.id.uuidString)
            let titleLiteral = Self.jsLiteral(child.title)
            let emojiLiteral = child.emoji.map(Self.jsLiteral) ?? "null"
            webView?.evaluateJavaScript(
                "window.hyperview.insertSubpage(\(idLiteral), \(titleLiteral), \(emojiLiteral));",
                completionHandler: nil
            )

        case "createInlineDatabase":
            // "/New database": Swift creates + seeds a sub-database, the
            // editor drops an editable embed of it right at the cursor.
            guard let document, let child = document.createInlineDatabase?() else { return }
            insertDBEmbed(id: child.id, viewID: nil, title: child.title.isEmpty ? "Untitled" : child.title, emoji: child.emoji)

        case "openLink":
            if let href = body["href"] as? String { openLink(href) }

        default:
            break
        }
    }

    // MARK: Image handling

    /// "Image" slash command: macOS opens an NSOpenPanel right here; iOS has
    /// no modal panel, so NotesView presents the photo/document picker and
    /// posts the result back through .unifyrInsertImageFile.
    private func pickImage() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to insert"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storeAndInsertImage(from: url)
        #else
        NotificationCenter.default.post(name: .unifyrRequestImageFile, object: nil)
        #endif
    }

    /// data URL ("data:image/png;base64,…") → Asset → image block.
    private func storeAndInsertImage(dataURL: String, filename: String) {
        guard let comma = dataURL.firstIndex(of: ","),
              dataURL.hasPrefix("data:"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        let mimeType = String(header.split(separator: ";").first ?? "image/png")
        insertImageAsset(data: data, filename: filename, mimeType: mimeType)
    }

    /// Picked file URL → Asset → image block.
    private func storeAndInsertImage(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        insertImageAsset(data: data, filename: url.lastPathComponent, mimeType: mimeType)
    }

    /// After a write through an embed, every embed of that database on the
    /// page re-requests its snapshot so they all stay consistent.
    private func refreshDBEmbeds(databaseID: UUID) {
        let literal = Self.jsLiteral(databaseID.uuidString)
        webView?.evaluateJavaScript(
            "window.hyperview.refreshDBEmbeds(\(literal));",
            completionHandler: nil
        )
    }

    private func insertDBEmbed(id: UUID, viewID: UUID?, title: String, emoji: String?) {
        let idLiteral = Self.jsLiteral(id.uuidString)
        let viewLiteral = viewID.map { Self.jsLiteral($0.uuidString) } ?? "null"
        let titleLiteral = Self.jsLiteral(title)
        let emojiLiteral = emoji.map(Self.jsLiteral) ?? "null"
        webView?.evaluateJavaScript(
            "window.hyperview.insertDBEmbed(\(idLiteral), \(viewLiteral), \(titleLiteral), \(emojiLiteral));",
            completionHandler: nil
        )
    }

    private func insertImageAsset(data: Data, filename: String, mimeType: String) {
        guard let document, let assetID = document.saveAsset?(data, filename, mimeType) else { return }
        let src = "\(AssetSchemeHandler.scheme)://\(assetID.uuidString)"
        let srcLiteral = Self.jsLiteral(src)
        let altLiteral = Self.jsLiteral(filename)
        webView?.evaluateJavaScript(
            "window.hyperview.insertImage(\(srcLiteral), \(altLiteral));",
            completionHandler: nil
        )
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
            // "hyperview" is the bundled editor JS's namespace — a wire name,
            // not a display name; it did not rename with the app.
            "window.hyperview.insertLink(\(hrefLiteral), \(textLiteral));",
            completionHandler: nil
        )
    }

    private static func jsLiteral(_ string: String) -> String {
        String(decoding: (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: Swift -> JS

    private func loadDocument(for document: EditorDocument) {
        let node = document.load()
        let json = String(decoding: BlockSerializer.encode(node), as: UTF8.self)
        // Encode the JSON string as a JS string literal (safe escaping).
        let literal = String(decoding: (try? JSONEncoder().encode(json)) ?? Data("\"{}\"".utf8), as: UTF8.self)
        // window.hyperview: bundled-JS wire name (see insertLink).
        webView?.evaluateJavaScript("window.hyperview.loadDocument(\(literal));", completionHandler: nil)
        loadedDocumentID = document.id
        pushPages(for: document)
        applyWide(document.wide)
    }

    /// Refresh the "@" mention menu's page index (per document load, so it
    /// tracks creates/renames without a live feed).
    private func pushPages(for document: EditorDocument) {
        guard let pages = document.pageList?() else { return }
        let array: [[String: String]] = pages.map {
            ["id": $0.id.uuidString, "title": $0.title, "emoji": $0.emoji ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return }
        let literal = Self.jsLiteral(String(decoding: data, as: UTF8.self))
        webView?.evaluateJavaScript("window.hyperview.setPages(\(literal));", completionHandler: nil)
    }
}
