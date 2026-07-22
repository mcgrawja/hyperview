//
//  AssetSchemeHandler.swift
//  Unifyr
//
//  Serves `unifyr-asset://<uuid>` inside the editor WKWebView from the Asset
//  entity (§4.2 — CloudKit-external binary storage). Image blocks store this
//  URL as their `src`, so the note's block JSON stays tiny while the bytes
//  live (and sync) in the Asset record.
//

import Foundation
import SwiftData
import WebKit

@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "unifyr-asset"

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let host = url.host,
              let id = UUID(uuidString: host),
              let asset = fetchAsset(id: id)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: asset.mimeType.isEmpty ? "application/octet-stream" : asset.mimeType,
            expectedContentLength: asset.data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(asset.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Responses are delivered synchronously above; nothing to cancel.
    }

    private func fetchAsset(id: UUID) -> Asset? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }
}
