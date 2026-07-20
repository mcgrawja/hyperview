//
//  HomeAssistantEntityPicker.swift
//  Unifyr
//
//  Picks which Home Assistant entities the dashboard card shows. Lists every
//  entity from the last `GET /api/states` (fetching fresh if the card had none
//  yet), grouped by domain and searchable, with a checkmark per row. Saving
//  writes the selection back through HomeAssistantConfig (which syncs it).
//

import SwiftUI

struct HomeAssistantEntityPicker: View {
    let config: HomeAssistantConfig
    /// Entities the card already loaded; used as-is when non-empty.
    let entities: [HAEntity]

    @Environment(\.dismiss) private var dismiss

    @State private var loaded: [HAEntity] = []
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading && loaded.isEmpty {
                    ProgressView("Loading entities…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText, loaded.isEmpty {
                    ContentUnavailableView("Couldn't load entities", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    list
                }
            }
            .navigationTitle("Choose Entities")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .searchable(text: $search, prompt: "Search entities")
        }
        .frame(minWidth: 420, minHeight: 520)
        .task { await loadIfNeeded() }
    }

    private var list: some View {
        List {
            if !selection.isEmpty {
                Section("Showing (\(selection.count))") {
                    ForEach(selectedEntities) { entity in
                        row(entity)
                    }
                }
            }
            ForEach(groupedDomains, id: \.self) { domain in
                Section(Self.domainTitle(domain)) {
                    ForEach(grouped[domain] ?? []) { entity in
                        row(entity)
                    }
                }
            }
        }
    }

    private func row(_ entity: HAEntity) -> some View {
        Button {
            toggle(entity.entityID)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: entity.cardSymbol)
                    .foregroundStyle(Theme.Palette.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.displayName)
                        .font(Theme.Font.cardBody)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(entity.entityID)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text(entity.cardState)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: selection.contains(entity.entityID) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(entity.entityID) ? Theme.Palette.primary : Theme.Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grouping / filtering

    private var filtered: [HAEntity] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return loaded }
        return loaded.filter {
            $0.displayName.lowercased().contains(query) || $0.entityID.lowercased().contains(query)
        }
    }

    private var selectedEntities: [HAEntity] {
        filtered.filter { selection.contains($0.entityID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var grouped: [String: [HAEntity]] {
        Dictionary(grouping: filtered) { $0.domain }
            .mapValues { $0.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }
    }

    private var groupedDomains: [String] {
        grouped.keys.sorted { Self.domainTitle($0).localizedCaseInsensitiveCompare(Self.domainTitle($1)) == .orderedAscending }
    }

    private static func domainTitle(_ domain: String) -> String {
        switch domain {
        case "binary_sensor": return "Binary Sensors"
        case "device_tracker": return "Device Trackers"
        case "media_player": return "Media Players"
        case "input_boolean": return "Toggles"
        case "alarm_control_panel": return "Alarm"
        default: return domain.replacingOccurrences(of: "_", with: " ").capitalized + "s"
        }
    }

    // MARK: Actions

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func save() {
        // Preserve the previous order for entities still selected, then append
        // any newly-added ones in display order — stable, predictable rows.
        let previous = config.connection?.pinnedEntities ?? []
        var ordered = previous.filter { selection.contains($0) }
        let added = loaded.map(\.entityID)
            .filter { selection.contains($0) && !ordered.contains($0) }
        ordered.append(contentsOf: added)
        config.setPinnedEntities(ordered)
        dismiss()
    }

    private func loadIfNeeded() async {
        selection = Set(config.connection?.pinnedEntities ?? [])
        if !entities.isEmpty {
            loaded = entities
            return
        }
        guard let client = config.client() else { return }
        loading = true
        defer { loading = false }
        do {
            loaded = try await client.states()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
