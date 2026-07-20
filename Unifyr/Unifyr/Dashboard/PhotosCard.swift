//
//  PhotosCard.swift
//  Unifyr
//
//  Phase 3 dashboard strip (§6): last-7-days photos, lazy thumbnails via
//  PhotoBroker. Access is gated behind Connect (§6 staggered TCC); limited
//  library access just scopes what appears.
//

import SwiftUI

struct PhotosCard: View {
    @Environment(\.brokers) private var brokers

    @State private var photos: [PhotoSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var errorText: String?

    var body: some View {
        DashboardCard(title: "Recent Photos", systemImage: "photo.on.rectangle", accent: Theme.Palette.primary) {
            content
        } accessory: {
            if access == .ready, !photos.isEmpty {
                CountBadge(count: photos.count, accent: Theme.Palette.primary)
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .needsPermission:
            ConnectPrompt(moduleName: "Photos", systemImage: "photo.on.rectangle", accent: Theme.Palette.primary) {
                await connect()
            }
        case .blocked:
            BlockedPrompt(moduleName: "Photos")
        case .ready:
            if brokers.photos.authorization == .limited {
                LimitedAccessHint(moduleName: "Photos", settingsAnchor: "Privacy_Photos")
            }
            if let errorText {
                EmptyStateLine(text: errorText)
            } else if photos.isEmpty {
                EmptyStateLine(text: "No photos from the last 7 days.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(photos) { photo in
                            PhotoThumbnail(photo: photo, side: 72)
                        }
                    }
                }
            }
        }
    }

    private func start() async {
        access = ModuleAccess(brokers.photos.authorization)
        guard access == .ready else { return }
        await load()
        await observe()
    }

    private func connect() async {
        do {
            try await brokers.photos.requestAccess()
            access = .ready
            await load()
            await observe()
        } catch {
            access = ModuleAccess(brokers.photos.authorization)
        }
    }

    private func load() async {
        do {
            photos = try await brokers.photos.fetchRecent(days: 7, limit: 24)
            errorText = nil
        } catch {
            errorText = "Couldn't load your photos."
        }
    }

    private func observe() async {
        for await _ in brokers.photos.changes() {
            await load()
        }
    }
}

/// Async, cached-by-PhotoKit thumbnail cell.
struct PhotoThumbnail: View {
    @Environment(\.brokers) private var brokers
    let photo: PhotoSnapshot
    var side: CGFloat = 72

    @State private var imageData: Data?

    var body: some View {
        Group {
            if let imageData, let image = platformImage(imageData) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.Palette.surfaceRaised)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(alignment: .topTrailing) {
            if photo.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(Theme.Spacing.xs)
            }
        }
        .task(id: photo.id) {
            imageData = await brokers.photos.thumbnail(for: photo.id, maxPixels: side * 3)
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
