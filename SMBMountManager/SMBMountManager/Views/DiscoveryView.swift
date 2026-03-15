import SwiftUI

struct DiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var discoveryService: SMBDiscoveryService
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
                .help("Scan the local network again for SMB servers")
            }

            Text("Browse SMB hosts announced on the local network and use one as the starting point for a new connection.")
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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.displayName)
                                .font(.headline)
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
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            discoveryService.startBrowsing()
        }
        .onDisappear {
            discoveryService.stopBrowsing()
        }
    }
}
