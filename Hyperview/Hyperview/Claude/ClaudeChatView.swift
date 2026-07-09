//
//  ClaudeChatView.swift
//  Hyperview
//
//  Phase 5 chat UI: message list with live streaming, tool-call chips, input
//  bar, and settings (API key in Keychain, model picker). Orange (Theme
//  claude) marks AI surfaces per D11.
//

import SwiftUI

struct ClaudeChatView: View {
    /// App-level controller — the conversation persists across module switches.
    @Environment(\.claudeChat) private var envController
    @State private var fallback = ClaudeChatController()
    private var controller: ClaudeChatController { envController ?? fallback }
    @State private var draft = ""
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if controller.hasKey {
                conversation
                inputBar
            } else {
                setupCard
            }
        }
        .onAppear {
            controller.refreshKeyState()
        }
        .sheet(isPresented: $showingSettings) {
            ClaudeSettingsView(controller: controller)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if controller.entries.isEmpty {
                        emptyState
                    }
                    ForEach(controller.entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    if case .runningTools(let name) = controller.phase {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Running \(name)…")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(Theme.Spacing.lg)
            }
            .onChange(of: controller.entries.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Ask about your day, your mail, your notes — Claude has Hyperview's tools.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(["What needs my attention today?",
                     "Summarize my unread email.",
                     "Create a note with a packing list for a weekend trip."], id: \.self) { suggestion in
                Button {
                    controller.send(suggestion)
                } label: {
                    Text(suggestion)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.claude)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Palette.claude.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Theme.Spacing.xl)
    }

    @ViewBuilder
    private func entryView(_ entry: ChatEntry) -> some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(entry.text)
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textOnAccent)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Palette.claude, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                Text(entry.text.isEmpty ? "…" : entry.text)
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .textSelection(.enabled)
                Spacer(minLength: 60)
            }
        case .toolCall(let name):
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "wrench.adjustable")
                Text(name)
            }
            .font(Theme.Font.cardCaption)
            .foregroundStyle(Theme.Palette.claude)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Theme.Palette.claude.opacity(0.1), in: Capsule())
        case .notice:
            Text(entry.text)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if case .error(let message) = controller.phase {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message).font(Theme.Font.cardCaption)
                    Spacer()
                }
                .foregroundStyle(Theme.Palette.danger)
                .padding(.horizontal, Theme.Spacing.lg)
            }
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Message Claude…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.cardBody)
                    .lineLimit(1...5)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .onSubmit(sendDraft)

                if controller.phase == .streaming || isRunningTools {
                    Button(action: controller.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.Palette.danger)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(draft.isEmpty ? Theme.Palette.textSecondary : Theme.Palette.claude)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.isEmpty)
                    .help("Send")
                }

                Menu {
                    Button("New Conversation") { controller.clearConversation() }
                    Button("Settings…") { showingSettings = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if controller.inputTokens + controller.outputTokens > 0 {
                Text("This conversation: \(controller.inputTokens.formatted()) in · \(controller.outputTokens.formatted()) out tokens")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Palette.background)
    }

    private var isRunningTools: Bool {
        if case .runningTools = controller.phase { return true }
        return false
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        controller.send(text)
    }

    // MARK: Setup

    private var setupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                DashboardCard(title: "Chat with Claude in Hyperview", systemImage: "sparkles", accent: Theme.Palette.claude) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Add an Anthropic API key to chat with Claude right here — with full access to Hyperview's tools. Usage is billed per token to your API account (separate from your Claude subscription); typical chats cost fractions of a cent.")
                            .font(Theme.Font.cardBody)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        HStack(spacing: Theme.Spacing.md) {
                            Button("Add API Key…") { showingSettings = true }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.Palette.claude)
                            Button("Get a key at console.anthropic.com") {
                                #if os(macOS)
                                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                                #endif
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings

struct ClaudeSettingsView: View {
    @Bindable var controller: ClaudeChatController
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft = ""
    @State private var selectedModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Claude Settings").font(Theme.Font.cardTitle)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("ANTHROPIC API KEY")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                SecureField(controller.hasKey ? "•••••••• (saved)" : "sk-ant-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in your Keychain. Billed per use to your Anthropic API account.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if controller.hasKey {
                    Button("Remove Key", role: .destructive) {
                        ClaudeAuth.removeAPIKey()
                        controller.refreshKeyState()
                        controller.clearConversation()
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("MODEL")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Picker("", selection: $selectedModel) {
                    ForEach(ClaudeChatController.models, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            HStack {
                Spacer()
                Button("Done") {
                    let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        ClaudeAuth.setAPIKey(trimmed)
                    }
                    controller.model = selectedModel
                    controller.refreshKeyState()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.claude)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
        .background(Theme.Palette.background)
        .onAppear { selectedModel = controller.model }
    }
}
