//
//  DashboardCard.swift
//  Hyperview
//
//  Reusable card chrome + the per-module access gate. All styling comes from
//  Theme (D11). The gate is why the dashboard can show every module at launch
//  without triggering every TCC prompt at launch (§6): a not-yet-authorized
//  module renders a "Connect" call-to-action and only prompts when the user
//  taps it.
//

import SwiftUI

/// Standard card container: icon + title header, themed surface, optional
/// trailing accessory, and a content body.
struct DashboardCard<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    var accent: Color = Theme.Palette.primary
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(accent)
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                accessory()
            }
            content()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Palette.separator, lineWidth: 1)
        )
        .shadow(
            color: Theme.Shadow.card.color,
            radius: Theme.Shadow.card.radius,
            y: Theme.Shadow.card.y
        )
    }
}

extension DashboardCard where Accessory == EmptyView {
    init(
        title: String,
        systemImage: String,
        accent: Color = Theme.Palette.primary,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, systemImage: systemImage, accent: accent, content: content, accessory: { EmptyView() })
    }
}

/// The three states a module's UI can be in, derived from `BrokerAuthorization`.
enum ModuleAccess {
    /// Show data (authorized or limited).
    case ready
    /// Show a Connect call-to-action; tapping prompts (first use, §6).
    case needsPermission
    /// Show a "denied — open Settings" message.
    case blocked

    init(_ authorization: BrokerAuthorization) {
        switch authorization {
        case .authorized, .limited: self = .ready
        case .notDetermined: self = .needsPermission
        case .denied, .restricted: self = .blocked
        }
    }
}

/// Call-to-action shown when a module hasn't been granted access yet.
struct ConnectPrompt: View {
    let moduleName: String
    let systemImage: String
    var accent: Color = Theme.Palette.primary
    let action: () async -> Void

    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Connect \(moduleName) to see it here.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                Task {
                    isRequesting = true
                    await action()
                    isRequesting = false
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                    }
                    Text("Connect \(moduleName)")
                }
                .font(Theme.Font.cardBody.weight(.medium))
                .foregroundStyle(Theme.Palette.textOnAccent)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)
        }
    }
}

/// Shown when access was denied at the system level.
struct BlockedPrompt: View {
    let moduleName: String

    var body: some View {
        Text("\(moduleName) access is turned off. Enable it in System Settings › Privacy & Security.")
            .font(Theme.Font.cardBody)
            .foregroundStyle(Theme.Palette.textSecondary)
    }
}

/// Empty-state line for an authorized-but-empty module.
struct EmptyStateLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.cardBody)
            .foregroundStyle(Theme.Palette.textSecondary)
    }
}

/// Shown when the system granted only partial access (e.g. Photos limited
/// library): explains why content looks sparse and deep-links to the fix.
struct LimitedAccessHint: View {
    let moduleName: String
    let settingsAnchor: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
            Text("\(moduleName) access is limited to selected items.")
                .font(Theme.Font.cardCaption)
            Button("Grant Full Access…") {
                #if os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            .buttonStyle(.link)
            .font(Theme.Font.cardCaption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.warning)
    }
}
