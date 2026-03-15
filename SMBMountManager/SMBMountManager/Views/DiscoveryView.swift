import SwiftUI

struct DiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var discoveryService: SMBDiscoveryService
    let configuredHosts: Set<String>
    let onSelectHost: (DiscoveredSMBHost) -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Discover SMB Servers")
                    .font(.title3.weight(.semibold))

                Spacer()

                if discoveryService.isBrowsing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Refresh") {
                    discoveryService.startBrowsing()
                }
                .help("Refresh the SMB host list without clearing previously resolved hosts")
            }

            Text("Browse SMB hosts announced on the local network, inspect their resolved network details, and use one as the starting point for a new connection.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage = discoveryService.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if discoveryService.hosts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(discoveryService.isBrowsing ? "Searching for SMB servers…" : "No SMB servers found")
                        .font(.headline)
                    Text("Servers that publish `_smb._tcp` via Bonjour will appear here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discoveryService.hosts) { host in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(host.displayName)
                                        .font(.headline)
                                    if configuredHosts.contains(host.normalizedHostName.lowercased()) {
                                        Text("Configured")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(host.normalizedHostName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Use") {
                                onSelectHost(host)
                                dismiss()
                            }
                            .help("Use this server to prefill a new SMB connection")
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            gridRow("Network", host.secondaryDetails)
                            gridRow("Last Seen", host.lastResolvedAt.formatted(date: .omitted, time: .standard))
                            gridRow("Resolve Time", formatted(duration: host.resolveDuration))
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .help("Close the SMB discovery window")
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            discoveryService.startBrowsing()
        }
        .onDisappear {
            discoveryService.stopBrowsing()
        }
    }

    @ViewBuilder
    private func gridRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func formatted(duration: TimeInterval?) -> String {
        guard let duration else {
            return "Pending"
        }
        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }
}
