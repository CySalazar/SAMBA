import SwiftUI

struct ConnectionRow: View {
    let connection: SMBConnection
    let status: ConnectionStatus
    let runtimeDetails: SMBConnectionRuntimeDetails
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onRunBenchmark: () -> Void
    let onRefreshDetails: () -> Void
    let onOpenMountPoint: () -> Void
    let onCopyURL: () -> Void
    @State private var lastStableStatus: ConnectionStatus = .disconnected

    var body: some View {
        HStack(spacing: 12) {
            StatusIndicator(status: status)
                .help(statusTooltip)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(connection.name.isEmpty ? connection.shareName : connection.name)
                        .font(.headline)
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text("Stability \(runtimeDetails.stabilityGrade.title)")
                    Text("Probe \(formatted(duration: runtimeDetails.lastProbeLatency))")
                    Text("Success \(Int((runtimeDetails.successRate * 100).rounded()))%")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(errorMessage)
                }
            }

            Spacer()

            if connection.autoConnect {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Auto-connect is enabled for this SMB share")
            }

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
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy SMB URL", action: onCopyURL)
            Button("Open Mount Point", action: onOpenMountPoint)
                .disabled(status != .connected)
            Button("Inspect Share (May Prompt)", action: onRefreshDetails)
                .disabled(status != .connected)
            Button("Run Benchmark", action: onRunBenchmark)
                .disabled(status != .connected || runtimeDetails.isBenchmarkRunning)
        }
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

    private var badges: [String] {
        var badges: [String] = []
        if connection.shareName.hasSuffix("$") {
            badges.append("Hidden")
        }
        if let protocolVersion = runtimeDetails.protocolVersion, protocolVersion.isEmpty == false {
            badges.append(protocolVersion)
        }
        if runtimeDetails.stabilityGrade == .low {
            badges.append("Unstable")
        }
        if let latency = runtimeDetails.lastProbeLatency, latency >= 1.0 {
            badges.append("High Latency")
        }
        return badges
    }

    private var connectionSubtitle: String {
        "\(connection.serverAddress)/\(connection.shareName)"
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

    private func formatted(duration: TimeInterval?) -> String {
        guard let duration else {
            return "n/a"
        }
        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
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
