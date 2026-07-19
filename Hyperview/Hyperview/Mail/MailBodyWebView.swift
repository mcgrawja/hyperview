//
//  MailBodyWebView.swift
//  Unifyr
//
//  Renders an email body (HTML or plaintext) in a WKWebView. JavaScript is
//  disabled — email HTML must never execute script. A responsive wrapper is
//  injected so messages read well on any screen. The same wrapper and the same
//  web view serve both platforms; only the hosting shell differs.
//
//  A Coordinator acts as the navigation delegate: link taps open in the user's
//  browser (not inside the message pane), and the HTML is (re)loaded ONLY when
//  it actually changes — SwiftUI calls updateNSView/updateUIView often, and
//  reloading on every call restarted in-flight image fetches and churned CPU.
//

import SwiftUI
import WebKit

struct MailBodyWebView {
    /// Raw message HTML, or nil to render `plainText`.
    let html: String?
    let plainText: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        // Default (opaque white) background — the message area is light "paper"
        // even in dark mode, matching the wrapper CSS, with no gap below short
        // messages.
        return webView
    }

    /// Load the document only if it differs from what's already showing.
    fileprivate func load(into webView: WKWebView, coordinator: Coordinator) {
        let doc = document
        guard coordinator.loadedDocument != doc else { return }
        coordinator.loadedDocument = doc
        webView.loadHTMLString(doc, baseURL: nil)
    }

    fileprivate var document: String {
        let inner: String
        if let html, !html.isEmpty {
            inner = html
        } else {
            let escaped = (plainText ?? "")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            inner = "<pre class=\"hv-plain\">\(escaped)</pre>"
        }
        return Self.wrapper(inner)
    }

    private static func wrapper(_ body: String) -> String {
        // Email HTML is overwhelmingly authored for a WHITE background (dark
        // text colors, white table cells). Rendering it on the app's dark
        // surface makes it unreadable, so — like Apple Mail — the message body
        // always renders as light "paper", independent of system appearance.
        // color-scheme is pinned to light so WebKit never auto-darkens it.
        """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; padding: 16px; background: #ffffff;
            font: 15px/1.55 -apple-system, system-ui, sans-serif;
            color: #1c1c1e; -webkit-text-size-adjust: 100%; word-break: break-word; }
          img { max-width: 100%; height: auto; }
          pre.hv-plain { white-space: pre-wrap; font: inherit; }
          a { color: #2f6fba; }
          table { max-width: 100% !important; }
          blockquote { border-left: 3px solid rgba(128,128,128,.3); margin-left: 0; padding-left: 12px; color: #6e6e73; }
        </style>
        </head><body>\(body)</body></html>
        """
    }

    /// Navigation delegate: intercept link taps and open them in the browser
    /// rather than loading them inside the message pane.
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The HTML currently loaded, so repeated update calls don't reload.
        var loadedDocument: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // The initial loadHTMLString arrives as `.other`; let it (and any
            // resource loads) through. A user activating a link opens externally.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" || scheme == "mailto" {
                PlatformKit.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

#if os(macOS)
extension MailBodyWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }
}
#else
extension MailBodyWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }
}
#endif
