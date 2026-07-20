//
//  PhotoBroker.swift
//  Unifyr
//
//  §3 / §6 — Photos. Actor over PhotoKit with a PHCachingImageManager for
//  thumbnails. Limited library access is handled gracefully (it simply scopes
//  what fetches return). Verbs map to §7: fetch -> photos_recent_metadata;
//  thumbnails feed the dashboard strip and Photos grid lazily.
//

import Foundation
import Photos

#if os(macOS)
import AppKit
#else
import UIKit
#endif

actor PhotoBroker: DataBroker {
    typealias Item = PhotoSnapshot

    private let imageManager = PHCachingImageManager()

    // MARK: Authorization

    func requestAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited: return
        case .restricted: throw BrokerError.accessRestricted
        default: throw BrokerError.accessDenied
        }
    }

    nonisolated var authorization: BrokerAuthorization {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    // MARK: Read

    /// Image assets, newest first. Honors `dateRange` and `limit`.
    func fetch(_ query: BrokerQuery) async throws -> [PhotoSnapshot] {
        guard authorization == .authorized || authorization == .limited else {
            throw BrokerError.accessDenied
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let range = query.dateRange {
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                range.lowerBound as NSDate, range.upperBound as NSDate
            )
        }
        if let limit = query.limit { options.fetchLimit = limit }

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var snapshots: [PhotoSnapshot] = []
        var fetchedAssets: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            snapshots.append(PhotoSnapshot(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
            fetchedAssets[asset.localIdentifier] = asset
        }
        // Remember the PHAssets so thumbnail(for:) doesn't have to run a
        // per-cell fetchAssets round-trip back into the photo store. (Merged
        // outside the enumeration closure — actor state can't be touched from
        // inside it under strict concurrency.)
        for (id, asset) in fetchedAssets { assetCache[id] = asset }
        MailLog.log("[Photos] auth=\(authorization) fetched \(snapshots.count) (limit \(query.limit ?? -1), range \(query.dateRange == nil ? "any" : "set"))")
        return snapshots
    }

    /// Last-`days` photos for the dashboard strip.
    func fetchRecent(days: Int = 7, limit: Int = 30) async throws -> [PhotoSnapshot] {
        let now = Date()
        return try await fetch(BrokerQuery(
            dateRange: now.addingTimeInterval(-TimeInterval(days) * 86_400)...now,
            limit: limit
        ))
    }

    /// JPEG thumbnail bytes for an asset, longest side ≈ `maxPixels`.
    /// iCloud-resident originals are fetched over the network if needed.
    /// PHAssets already seen by a list fetch, so per-cell thumbnail requests
    /// skip the photo-store round-trip. Refilled on every list pass; entries
    /// are tiny (object references).
    private var assetCache: [String: PHAsset] = [:]

    func thumbnail(for id: String, maxPixels: CGFloat = 240) async -> Data? {
        let asset: PHAsset
        if let cached = assetCache[id] {
            asset = cached
        } else {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let fetched = fetch.firstObject else { return nil }
            assetCache[id] = fetched
            asset = fetched
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // handler fires exactly once
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let target = CGSize(width: maxPixels, height: maxPixels)
        let image: PlatformImage? = await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset, targetSize: target, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        return image.flatMap(Self.jpegData(from:))
    }

    // MARK: Change feed

    nonisolated func changes() -> AsyncStream<BrokerChange<PhotoSnapshot>> {
        AsyncStream { continuation in
            let observer = LibraryObserver {
                continuation.yield(.reloaded)
            }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    /// Bridges PHPhotoLibraryChangeObserver (class-based) into the stream.
    private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
        private let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
    }

    // MARK: - Platform image → JPEG

    #if os(macOS)
    private typealias PlatformImage = NSImage
    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
    #else
    private typealias PlatformImage = UIImage
    private static func jpegData(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.8)
    }
    #endif
}
