import SwiftUI

struct ConnectionRow: View {
    let connection: SMBConnection
    let status: ConnectionStatus
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    /// Tracks the last non-connecting status so that the button label and
    /// tint remain stable while the status oscillates through `.connecting`.
    @State private var lastStableStatus: ConnectionStatus = .disconnected

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            StatusIndicator(status: status)
                .help(statusTooltip)

            // Connection info
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? connection.shareName : connection.name)
                    .font(.headline)
                Text(connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(errorMessage)
                }
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
                if lastStableStatus == .connected {
                    onDisconnect()
                } else {
                    onConnect()
                }
            }) {
                Text(buttonLabel)
                    .frame(width: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(lastStableStatus == .connected ? .red : .accentColor)
            .disabled(status == .connecting)
            .help(buttonTooltip)
        }
        .padding(.vertical, 4)
        .onAppear {
            if status != .connecting {
                lastStableStatus = status
            }
        }
        .onChange(of: status) { newStatus in
            if newStatus != .connecting {
                lastStableStatus = newStatus
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        case .error: return .orange
        }
    }

    private var connectionSubtitle: String {
        return "\(connection.serverAddress)/\(connection.shareName)"
    }

    private var secondaryTextColor: Color {
        return .secondary
    }

    private var errorMessage: String? {
        if case .error(let message) = status {
            return message
        }

        return nil
    }

    private var buttonLabel: String {
        switch lastStableStatus {
        case .connected: return "Disconnect"
        case .disconnected: return "Connect"
        case .error: return "Retry"
        case .connecting: return "Connect"
        }
    }

    private var statusTooltip: String {
        switch status {
        case .connected:
            return "This SMB share is currently connected"
        case .connecting:
            return "Connecting to the remote SMB share in the background"
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

private struct StatusIndicator: View {
    let status: ConnectionStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            Circle()
                .fill(indicatorColor(at: context.date))
                .frame(width: 10, height: 10)
        }
    }

    private func indicatorColor(at date: Date) -> Color {
        guard status == .connecting else {
            return statusColor
        }

        let phase = Int(date.timeIntervalSinceReferenceDate / 0.4)
        return phase.isMultiple(of: 2) ? .green : .yellow
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        case .error: return .orange
        }
    }
}
