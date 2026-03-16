import SwiftUI

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: SMBConnection?
    let suggestedHost: DiscoveredSMBHost?
    let existingConnections: [SMBConnection]
    @ObservedObject var mountService: MountService
    let onSave: (SMBConnection, String) -> Void

    @State private var name: String = ""
    @State private var serverAddress: String = ""
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var autoConnect: Bool = false
    @State private var discoveredShares: [DiscoveredSMBShare] = []
    @State private var selectedDiscoveredShareID = ""
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

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

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
                        Picker("Available shares", selection: $selectedDiscoveredShareID) {
                            Text("Select a share").tag("")
                            ForEach(discoveredShares, id: \.self) { share in
                                Text(share.name).tag(share.id)
                            }
                        }
                        .onChange(of: selectedDiscoveredShareID) { newValue in
                            guard
                                newValue.isEmpty == false,
                                let share = discoveredShares.first(where: { $0.id == newValue })
                            else {
                                return
                            }

                            shareName = share.name
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = share.name
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

                if let selectedShare {
                    Section("Selected Share Details") {
                        detailRow(title: "Share", value: selectedShare.name)
                        detailRow(title: "Type", value: selectedShare.type)
                        detailRow(title: "Comment", value: selectedShare.comment.isEmpty ? "Not available" : selectedShare.comment)
                        detailRow(title: "Hidden/Admin", value: selectedShare.isHidden ? "Yes" : "No")
                        detailRow(title: "URL", value: selectedShare.smbURL)
                    }
                }

                if let existing {
                    Section("Connection Observability") {
                        detailRow(title: "Mount Status", value: currentStatus.label)
                        detailRow(title: "Stability", value: runtimeDetails.stabilityGrade.title)
                        detailRow(title: "Confidence", value: runtimeDetails.confidenceLevel.title)
                        detailRow(title: "Mount Time", value: formatted(duration: runtimeDetails.lastMountDuration))
                        detailRow(title: "Last Probe", value: formatted(duration: runtimeDetails.lastProbeLatency))
                        detailRow(title: "Average Probe", value: formatted(duration: runtimeDetails.averageProbeLatency))
                        detailRow(title: "Latency Jitter", value: formatted(duration: runtimeDetails.probeLatencyJitter))
                        detailRow(title: "Successful Mounts", value: "\(runtimeDetails.successfulMounts)")
                        detailRow(title: "Failed Mounts", value: "\(runtimeDetails.failedMounts)")
                        detailRow(title: "Disconnects", value: "\(runtimeDetails.disconnectCount)")
                        detailRow(title: "Retries", value: "\(runtimeDetails.automaticRetryCount)")
                        detailRow(title: "Observed Uptime", value: formatted(duration: runtimeDetails.totalConnectedDuration))
                        detailRow(title: "Observed Downtime", value: formatted(duration: runtimeDetails.totalDisconnectedDuration))
                    }

                    Section("SMB Session Details") {
                        detailRow(title: "Protocol", value: runtimeDetails.protocolVersion ?? "Available when mounted")
                        detailRow(title: "Signing", value: runtimeDetails.signingState ?? "Unknown")
                        detailRow(title: "Encryption", value: runtimeDetails.encryptionState ?? "Unknown")
                        detailRow(title: "Multichannel", value: runtimeDetails.multichannelState ?? "Unknown")

                        Text("Live session details are refreshed only on manual inspection to avoid repeated macOS prompts for mounted network volumes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(runtimeDetails.sessionAttributes.keys.sorted(), id: \.self) { key in
                            if let value = runtimeDetails.sessionAttributes[key], value.isEmpty == false {
                                detailRow(title: prettifiedAttributeName(key), value: value)
                            }
                        }
                    }

                    Section("Manual Benchmark") {
                        HStack {
                            Button(runtimeDetails.isBenchmarkRunning ? "Benchmark Running…" : "Run Benchmark") {
                                Task {
                                    await mountService.runBenchmark(for: existing)
                                }
                            }
                            .disabled(runtimeDetails.isBenchmarkRunning || currentStatus != .connected)

                            if runtimeDetails.isBenchmarkRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let benchmark = runtimeDetails.benchmarkResult {
                            detailRow(title: "Last Run", value: benchmark.timestamp.formatted(date: .abbreviated, time: .shortened))
                            detailRow(title: "Payload", value: ByteCountFormatter.string(fromByteCount: Int64(benchmark.payloadSizeBytes), countStyle: .file))
                            detailRow(title: "Write Speed", value: formattedThroughput(benchmark.writeThroughputMBps))
                            detailRow(title: "Read Speed", value: formattedThroughput(benchmark.readThroughputMBps))
                        }

                        if let benchmarkStatusMessage = runtimeDetails.benchmarkStatusMessage {
                            Text(benchmarkStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Runs a small read/write test only on explicit request and only while the share is mounted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        validationMessage == nil
    }

    private var canDiscoverShares: Bool {
        !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String? {
        let trimmedServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedServer.isEmpty || trimmedShare.isEmpty || trimmedUsername.isEmpty || trimmedPassword.isEmpty {
            return "Server, share, username and password are required."
        }
        if trimmedServer.contains(" ") {
            return "Server address should not contain spaces."
        }
        if trimmedShare.contains("/") || trimmedShare.contains(":") {
            return "Share name should not contain `/` or `:`."
        }
        if trimmedUsername.contains(" ") {
            return "Username should not contain spaces."
        }
        let isDuplicate = existingConnections.contains { connection in
            connection.id != existing?.id &&
                connection.serverAddress.caseInsensitiveCompare(trimmedServer) == .orderedSame &&
                connection.shareName.caseInsensitiveCompare(trimmedShare) == .orderedSame &&
                connection.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame
        }
        if isDuplicate {
            return "A connection with the same server, share and username already exists."
        }
        return nil
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
                        selectedDiscoveredShareID = onlyShare.id
                        shareName = onlyShare.name
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
        existingConnections: [SMBConnection] = [],
        mountService: MountService,
        onSave: @escaping (SMBConnection, String) -> Void
    ) {
        self.existing = existing
        self.suggestedHost = suggestedHost
        self.existingConnections = existingConnections
        self.mountService = mountService
        self.onSave = onSave

        if let conn = existing {
            _name = State(initialValue: conn.name)
            _serverAddress = State(initialValue: conn.serverAddress)
            _shareName = State(initialValue: conn.shareName)
            _username = State(initialValue: conn.username)
            _autoConnect = State(initialValue: conn.autoConnect)
            _password = State(initialValue: KeychainService.loadPassword(for: conn) ?? "")
        } else if let suggestedHost {
            _name = State(initialValue: suggestedHost.displayName)
            _serverAddress = State(initialValue: suggestedHost.normalizedHostName)
        }
    }

    private var selectedShare: DiscoveredSMBShare? {
        discoveredShares.first(where: { $0.id == selectedDiscoveredShareID })
    }

    private var currentStatus: ConnectionStatus {
        guard let existing else {
            return .disconnected
        }

        return mountService.statuses[existing.id] ?? .disconnected
    }

    private var runtimeDetails: SMBConnectionRuntimeDetails {
        guard let existing else {
            return SMBConnectionRuntimeDetails()
        }

        return mountService.runtimeDetails[existing.id] ?? SMBConnectionRuntimeDetails()
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formatted(duration: TimeInterval?) -> String {
        guard let duration else {
            return "Not available"
        }

        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }

        return String(format: "%.2f s", duration)
    }

    private func formattedThroughput(_ throughput: Double) -> String {
        guard throughput > 0 else {
            return "Not available"
        }

        return String(format: "%.2f MB/s", throughput)
    }

    private func prettifiedAttributeName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
