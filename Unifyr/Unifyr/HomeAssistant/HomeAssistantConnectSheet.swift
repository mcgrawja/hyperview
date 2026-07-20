//
//  HomeAssistantConnectSheet.swift
//  Unifyr
//
//  The "Connect Home Assistant" form: base URL + a long-lived access token.
//  "Connect" hits `GET /api/` with the token before saving, so a bad address or
//  token is caught here rather than as an empty card later.
//

import SwiftUI

struct HomeAssistantConnectSheet: View {
    let config: HomeAssistantConfig

    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var token = ""
    @State private var testing = false
    @State private var errorText: String?

    private var canSubmit: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && !testing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Home Assistant URL", text: $urlString, prompt: Text("https://home.example.ts.net:8123"))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                } footer: {
                    Text("The base address of your Home Assistant, including https:// and the port. A self-signed certificate is fine.")
                }
                Section {
                    SecureField("Long-lived access token", text: $token)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } header: {
                    Text("Access Token")
                } footer: {
                    Text("In Home Assistant: your profile → Security → Long-lived access tokens → Create Token. Paste it here.")
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "Connecting…" : "Connect")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect Home Assistant")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private func prefill() {
        guard let existing = config.connection else { return }
        urlString = existing.urlString
        token = config.token()
    }

    private func connect() async {
        errorText = nil
        guard let client = config.trialClient(urlString: urlString, token: token) else {
            errorText = HAError.badURL.errorDescription
            return
        }
        testing = true
        defer { testing = false }
        do {
            try await client.probe()
            // Only rewrite the token if it actually changed (avoids Keychain churn
            // when the user re-saves without touching it).
            let newToken: String? = (token == config.token()) ? nil : token
            config.save(urlString: urlString, token: newToken)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
