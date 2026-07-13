//
//  MailBodyWebView.swift
//  Unifyr
//
//  Renders an email body (HTML or plaintext) in a WKWebView. JavaScript is
//  disabled — email HTML must never execute script. A responsive wrapper is
//  injected so messages read well on any screen. The same wrapper and the same
//  web view serve both platforms; only the hosting shell differs.
//

import SwiftUI
import WebKit

struct MailBodyWebView {
    /// Raw message HTML, or nil to render `plainText`.
    let html: String?
    let plainText: String?

    fileprivate func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        // Default (opaque white) background — the message area is light "paper"
        // even in dark mode, matching the wrapper CSS, with no gap below short
        // messages.
        return webView
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
}

#if os(macOS)
extension MailBodyWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(document, baseURL: nil)
    }
}
#else
extension MailBodyWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(document, baseURL: nil)
    }
}
#endif
