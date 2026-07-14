//
//  PhotosView.swift
//  Hyperview
//
//  Phase 3 Photos module: a recent-photos grid over PhotoBroker with lazy
//  thumbnails and a click-to-preview sheet. Deliberately simple — the point of
//  Phase 3 is the broker + dashboard strip; deep library browsing can grow
//  later.
//

import SwiftUI

struct PhotosView: View {
    @Environment(\.brokers) private var brokers

    @State private var photos: [PhotoSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var errorText: String?
    @State private var preview: PhotoSnapshot?
    @State private var fetchLimit = 600

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Theme.Spacing.sm)]

    var body: some View {
        Group {
            switch access {
            case .needsPermission:
                VStack {
                    ConnectPrompt(moduleName: "Photos", systemImage: "photo.on.rectangle", accent: Theme.Palette.primary) {
                        await connect()
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .blocked:
                VStack { BlockedPrompt(moduleName: "Photos") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                grid
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Photos")
        .task { await start() }
        .sheet(item: $preview) { photo in
            PhotoPreview(photo: photo)
        }
    }

    private var grid: some View {
        ScrollView {
            if brokers.photos.authorization == .limited {
                LimitedAccessHint(moduleName: "Photos", settingsAnchor: "Privacy_Photos")
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.md)
            }
            if let errorText {
                EmptyStateLine(text: errorText).padding(Theme.Spacing.xl)
            } else if photos.isEmpty {
                EmptyStateLine(text: "No photos in your library.").padding(Theme.Spacing.xl)
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                    ForEach(photos) { photo in
                        Button {
                            preview = photo
                        } label: {
                            SquareThumbnail(photo: photo)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Spacing.lg)

                if photos.count >= fetchLimit {
                    Button("Load Older Photos") {
                        Task { await loadMore() }
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
        }
        // Pull to refresh (iOS); a no-op gesture on macOS.
        .refreshable { await load() }
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
            // Whole library, newest first (capped — older photos load on demand).
            photos = try await brokers.photos.fetch(BrokerQuery(limit: fetchLimit))
            errorText = nil
        } catch {
            errorText = "Couldn't load your photos."
        }
    }

    private func loadMore() async {
        fetchLimit += 600
        await load()
    }

    private func observe() async {
        for await _ in brokers.photos.changes() {
            await load()
        }
    }
}

/// Grid cell that fills its column square-ish.
private struct SquareThumbnail: View {
    let photo: PhotoSnapshot

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                PhotoThumbnail(photo: photo, side: 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

/// Larger single-photo preview sheet.
private struct PhotoPreview: View {
    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoSnapshot

    @State private var imageData: Data?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let imageData, let image = platformImage(imageData) {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let date = photo.creationDate {
                    Text(date.formatted(date: .long, time: .shortened))
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if photo.isFavorite {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.Palette.danger)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.Palette.background)
        .task {
            imageData = await brokers.photos.thumbnail(for: photo.id, maxPixels: 1600)
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
