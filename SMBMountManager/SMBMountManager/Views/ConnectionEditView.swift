import SwiftUI

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: SMBConnection?
    let onSave: (SMBConnection, String) -> Void

    @State private var name: String = ""
    @State private var serverAddress: String = ""
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var autoConnect: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name (e.g. NAS - Shared)", text: $name)
                TextField("Server address (IP or hostname)", text: $serverAddress)
                TextField("Share name", text: $shareName)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Toggle("Auto-connect", isOn: $autoConnect)
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

    private func save() {
        let connection = SMBConnection(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            serverAddress: serverAddress.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            autoConnect: autoConnect
        )
        onSave(connection, password)
        dismiss()
    }

    init(existing: SMBConnection?, onSave: @escaping (SMBConnection, String) -> Void) {
        self.existing = existing
        self.onSave = onSave

        if let conn = existing {
            _name = State(initialValue: conn.name)
            _serverAddress = State(initialValue: conn.serverAddress)
            _shareName = State(initialValue: conn.shareName)
            _username = State(initialValue: conn.username)
            _autoConnect = State(initialValue: conn.autoConnect)
            _password = State(initialValue: KeychainService.loadPassword(for: conn.id) ?? "")
        }
    }
}
