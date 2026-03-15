import SwiftUI

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: SMBConnection?
    let suggestedHost: DiscoveredSMBHost?
    let onSave: (SMBConnection, String) -> Void

    @State private var name: String = ""
    @State private var serverAddress: String = ""
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var autoConnect: Bool = false
    @State private var discoveredShares: [String] = []
    @State private var selectedDiscoveredShare = ""
    @State private var shareDiscoveryError: String?
    @State private var isDiscoveringShares = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name (e.g. NAS - Shared)", text: $name)
                TextField("Server address (IP or hostname)", text: $serverAddress)
                TextField("Share name", text: $shareName)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Toggle("Auto-connect", isOn: $autoConnect)

                Section("Share Discovery") {
                    HStack {
                        Button(isDiscoveringShares ? "Discovering…" : "Discover Shares") {
                            discoverShares()
                        }
                        .disabled(isDiscoveringShares || !canDiscoverShares)

                        if isDiscoveringShares {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if !discoveredShares.isEmpty {
                        Picker("Available shares", selection: $selectedDiscoveredShare) {
                            Text("Select a share").tag("")
                            ForEach(discoveredShares, id: \.self) { share in
                                Text(share).tag(share)
                            }
                        }
                        .onChange(of: selectedDiscoveredShare) { newValue in
                            guard !newValue.isEmpty else { return }
                            shareName = newValue
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = newValue
                            }
                        }
                    }

                    if let shareDiscoveryError {
                        Text(shareDiscoveryError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Use the current server and credentials to query the list of available shares.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 400)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
    }

    private var isValid: Bool {
        !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canDiscoverShares: Bool {
        !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let connection = SMBConnection(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            serverAddress: serverAddress.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            autoConnect: autoConnect
        )
        LoggingService.shared.record(.info, category: .ui, message: "Saving connection for \(connection.serverAddress)/\(connection.shareName)")
        onSave(connection, password)
        dismiss()
    }

    private func discoverShares() {
        shareDiscoveryError = nil
        isDiscoveringShares = true

        Task {
            do {
                let shares = try await SMBShareDiscoveryService.discoverShares(
                    serverAddress: serverAddress,
                    username: username,
                    password: password
                )

                await MainActor.run {
                    discoveredShares = shares
                    if shares.count == 1, let onlyShare = shares.first {
                        selectedDiscoveredShare = onlyShare
                        shareName = onlyShare
                    }
                    isDiscoveringShares = false
                }
            } catch {
                await MainActor.run {
                    discoveredShares = []
                    shareDiscoveryError = error.localizedDescription
                    isDiscoveringShares = false
                }
            }
        }
    }

    init(
        existing: SMBConnection?,
        suggestedHost: DiscoveredSMBHost? = nil,
        onSave: @escaping (SMBConnection, String) -> Void
    ) {
        self.existing = existing
        self.suggestedHost = suggestedHost
        self.onSave = onSave

        if let conn = existing {
            _name = State(initialValue: conn.name)
            _serverAddress = State(initialValue: conn.serverAddress)
            _shareName = State(initialValue: conn.shareName)
            _username = State(initialValue: conn.username)
            _autoConnect = State(initialValue: conn.autoConnect)
            _password = State(initialValue: KeychainService.loadPassword(for: conn.id) ?? "")
        } else if let suggestedHost {
            _name = State(initialValue: suggestedHost.displayName)
            _serverAddress = State(initialValue: suggestedHost.normalizedHostName)
        }
    }
}
