//
//  HomeAssistantCard.swift
//  Unifyr
//
//  Dashboard card for Home Assistant: connect once (base URL + long-lived token),
//  then pick which entities to show — temperatures, energy, doors, locks, lights,
//  presence, anything HA publishes. State is read over HA's REST API; the picks
//  sync across devices via HomeAssistantConfig.
//
//  (This began life as a BMW card routed through HA's car integration; when that
//  proved unreachable the generic HA plumbing was kept and turned into this.)
//

import SwiftUI

struct HomeAssistantCard: View {
    @State private var config = HomeAssistantConfig()
    @State private var entities: [HAEntity] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showConnect = false
    @State private var showPicker = false

    private var pinnedIDs: [String] { config.connection?.pinnedEntities ?? [] }

    var body: some View {
        DashboardCard(title: "Home Assistant", systemImage: "house.fill", accent: Theme.Palette.primary) {
            content
        } accessory: {
            accessory
        }
        .task(id: config.connection) { await load() }
        .sheet(isPresented: $showConnect) {
            HomeAssistantConnectSheet(config: config)
        }
        .sheet(isPresented: $showPicker) {
            HomeAssistantEntityPicker(config: config, entities: entities)
        }
    }

    // MARK: Accessory

    @ViewBuilder
    private var accessory: some View {
        if config.isConnected {
            Menu {
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button { showPicker = true } label: {
                    Label("Choose Entities…", systemImage: "checklist")
                }
                Button { showConnect = true } label: {
                    Label("Connection…", systemImage: "gearshape")
                }
                Button(role: .destructive) { config.disconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !config.isConnected {
            connectPrompt
        } else if let errorText {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                EmptyStateLine(text: errorText)
                Button("Connection…") { showConnect = true }
                    .font(Theme.Font.cardCaption)
            }
        } else if pinnedIDs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                EmptyStateLine(text: "Connected. Choose which entities to show here.")
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "checklist")
                        Text("Choose Entities")
                    }
                    .font(Theme.Font.cardBody.weight(.medium))
                    .foregroundStyle(Theme.Palette.textOnAccent)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Palette.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
            }
        } else {
            entityList
        }
    }

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("See your smart-home readings — temperatures, energy, doors, locks — at a glance.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                showConnect = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "house.badge.wifi")
                    Text("Connect Home Assistant")
                }
                .font(Theme.Font.cardBody.weight(.medium))
                .foregroundStyle(Theme.Palette.textOnAccent)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Palette.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
        }
    }

    private var entityList: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(pinnedIDs, id: \.self) { id in
                let entity = entities.first { $0.entityID == id }
                row(id: id, entity: entity)
            }
        }
    }

    private func row(id: String, entity: HAEntity?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: entity?.cardSymbol ?? "circle.dotted")
                .font(.callout)
                .foregroundStyle(Theme.Palette.primary)
                .frame(width: 22)
            Text(entity?.displayName ?? Self.prettyID(id))
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.sm)
            Text(entity?.cardState ?? (loading ? "…" : "—"))
                .font(Theme.Font.cardBody.weight(.medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
    }

    /// Turn "sensor.living_room_temperature" into "Living Room Temperature" for a
    /// row whose entity hasn't loaded (or has gone missing on the server).
    private static func prettyID(_ id: String) -> String {
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        return tail.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: Data

    private func load() async {
        guard let client = config.client() else {
            entities = []
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            entities = try await client.states()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Entity presentation

extension HAEntity {
    /// A human-readable state for a card row, aware of common domains and device
    /// classes (a door binary sensor reads "Open/Closed", a lock "Locked", etc.).
    var cardState: String {
        let raw = state
        let lower = raw.lowercased()
        switch domain {
        case "lock":
            return lower == "locked" ? "Locked" : (lower == "unlocked" ? "Unlocked" : raw.capitalized)
        case "binary_sensor":
            let (on, off) = Self.binaryLabels(for: deviceClass)
            if lower == "on" { return on }
            if lower == "off" { return off }
            return raw.capitalized
        case "light", "switch", "fan", "input_boolean":
            if lower == "on" { return "On" }
            if lower == "off" { return "Off" }
            return raw.capitalized
        case "device_tracker", "person":
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        case "sensor":
            return valueWithUnit
        default:
            // Fall back to value+unit for numeric readings, else a tidy word.
            if unit != nil { return valueWithUnit }
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func binaryLabels(for deviceClass: String?) -> (on: String, off: String) {
        switch deviceClass {
        case "door", "window", "garage_door", "opening": return ("Open", "Closed")
        case "lock": return ("Unlocked", "Locked")
        case "motion", "occupancy", "presence": return ("Detected", "Clear")
        case "moisture": return ("Wet", "Dry")
        case "smoke", "gas", "problem", "safety": return ("Alert", "OK")
        case "connectivity": return ("Connected", "Disconnected")
        case "battery": return ("Low", "OK")
        default: return ("On", "Off")
        }
    }

    /// SF Symbol for a card row, chosen from device class first, then domain.
    var cardSymbol: String {
        switch deviceClass {
        case "temperature": return "thermometer.medium"
        case "humidity": return "humidity.fill"
        case "battery": return "battery.100"
        case "power", "energy": return "bolt.fill"
        case "illuminance": return "sun.max.fill"
        case "pressure": return "gauge.medium"
        case "door", "garage_door": return "door.left.hand.closed"
        case "window", "opening": return "window.vertical.closed"
        case "motion", "occupancy", "presence": return "figure.walk.motion"
        case "moisture": return "drop.fill"
        case "smoke": return "smoke.fill"
        case "connectivity": return "wifi"
        default: break
        }
        switch domain {
        case "light": return "lightbulb.fill"
        case "switch", "input_boolean": return "switch.2"
        case "lock": return "lock.fill"
        case "climate": return "thermometer.snowflake"
        case "cover": return "blinds.vertical.closed"
        case "fan": return "fan.fill"
        case "media_player": return "play.rectangle.fill"
        case "device_tracker", "person": return "location.fill"
        case "sun": return "sun.max.fill"
        case "camera": return "video.fill"
        case "alarm_control_panel": return "shield.fill"
        case "binary_sensor": return "dot.circle"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}
