//
//  ConnectServerSheet.swift
//  Unifyr
//
//  The "Connect to Server" form: server URL, username, password (+ an optional
//  friendly name). "Connect" tests the credentials with a real PROPFIND before
//  saving, so a typo is caught here rather than as an empty folder later; a
//  quieter "Save without testing" covers a server that happens to be offline.
//

import SwiftUI

struct ConnectServerSheet: View {
    let servers: DriveServers
    /// The server being edited, or nil when adding a new one.
    var editing: DriveServer?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var errorText: String?

    private var canSubmit: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty && !testing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(title: "Server URL", text: $urlString, prompt: "https://nas.local/webdav")
                    LabeledField(title: "Name", text: $name, prompt: "Optional")
                } footer: {
                    Text("The full WebDAV address, including https:// and any path. A self-signed certificate is fine.")
                }
                Section("Sign In") {
                    LabeledField(title: "Username", text: $username, prompt: "Username")
                    SecureField("Password", text: $password)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
                    Button("Save without testing") { saveAndDismiss() }
                        .disabled(!canSubmit)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "Connect to Server" : "Edit Server")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
        .frame(minWidth: 380, minHeight: 360)
    }

    private func prefill() {
        guard let editing else { return }
        name = editing.name
        urlString = editing.urlString
        username = editing.username
        password = servers.password(for: editing)
    }

    /// Test the connection, then save on success.
    private func connect() async {
        errorText = nil
        guard let client = servers.trialClient(
            urlString: urlString.trimmingCharacters(in: .whitespaces),
            username: username,
            password: password
        ) else {
            errorText = WebDAVError.badServerURL.errorDescription
            return
        }
        testing = true
        defer { testing = false }
        do {
            try await client.probe()   // PROPFIND Depth:0 — auth + reachability
            saveAndDismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveAndDismiss() {
        let server = DriveServer(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            urlString: urlString.trimmingCharacters(in: .whitespaces),
            username: username
        )
        // On an edit, only rewrite the password when the field actually changed,
        // so leaving it as the prefilled value doesn't churn the Keychain.
        let newPassword: String? = {
            guard let editing else { return password }
            return password == servers.password(for: editing) ? nil : password
        }()
        servers.save(server, password: newPassword)
        dismiss()
    }
}

/// A titled text row that reads cleanly in a grouped Form on both platforms.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""

    var body: some View {
        TextField(title, text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }
}
