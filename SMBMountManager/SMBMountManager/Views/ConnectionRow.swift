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
                .help(statusTooltip)

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
                    .help("Auto-connect is enabled for this SMB share")
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
            .help(buttonTooltip)
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

    private var statusTooltip: String {
        switch status {
        case .connected:
            return "This SMB share is currently connected"
        case .connecting:
            return "Connection in progress"
        case .disconnected:
            return "This SMB share is currently disconnected"
        case .error(let message):
            return "Connection error: \(message)"
        }
    }

    private var buttonTooltip: String {
        switch status {
        case .connected:
            return "Disconnect this SMB share"
        case .connecting:
            return "Connection is in progress"
        case .disconnected:
            return "Connect this SMB share"
        case .error:
            return "Retry connecting this SMB share"
        }
    }
}
