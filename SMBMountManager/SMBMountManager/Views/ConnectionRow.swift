import SwiftUI

struct ConnectionRow: View {
    let connection: SMBConnection
    let status: ConnectionStatus
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            // Connection info
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? connection.shareName : connection.name)
                    .font(.headline)
                Text("\(connection.serverAddress)/\(connection.shareName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Auto-connect badge
            if connection.autoConnect {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Auto-connect enabled")
            }

            // Connect/Disconnect button
            Button(action: {
                if status == .connected {
                    onDisconnect()
                } else {
                    onConnect()
                }
            }) {
                Text(buttonLabel)
                    .frame(width: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(status == .connected ? .red : .accentColor)
            .disabled(status == .connecting)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        case .error: return .orange
        }
    }

    private var buttonLabel: String {
        switch status {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting…"
        case .disconnected: return "Connect"
        case .error: return "Retry"
        }
    }
}
