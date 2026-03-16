import AppKit
import SwiftUI

private enum ConnectionStatusFilter: String, CaseIterable, Identifiable {
    case all
    case connected
    case disconnected
    case errors
    case unstable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .errors:
            return "Errors"
        case .unstable:
            return "Unstable"
        }
    }
}

private enum ConnectionSortMode: String, CaseIterable, Identifiable {
    case name
    case host
    case status
    case latency
    case stability

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct ContentView: View {
    @StateObject private var mountService = MountService()
    @StateObject private var loggingService = LoggingService.shared
    @StateObject private var discoveryService = SMBDiscoveryService()
    @AppStorage("connectSharesOnLaunch") private var connectSharesOnLaunch = false
    @AppStorage("disconnectSharesOnQuit") private var disconnectSharesOnQuit = false
    @State private var connections: [SMBConnection] = []
    @State private var editingConnection: SMBConnection?
    @State private var selectedConnection: SMBConnection?
    @State private var isAddingNew = false
    @State private var isShowingDiagnostics = false
    @State private var isShowingDiscovery = false
    @State private var suggestedHost: DiscoveredSMBHost?
    @State private var hasAppliedLaunchBehavior = false
    @State private var searchText = ""
    @State private var statusFilter: ConnectionStatusFilter = .all
    @State private var sortMode: ConnectionSortMode = .name

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar

                Group {
                    if filteredConnections.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(filteredConnections) { connection in
                                ConnectionRow(
                                    connection: connection,
                                    status: mountService.statuses[connection.id] ?? .disconnected,
                                    runtimeDetails: mountService.runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails(),
                                    onConnect: { mountService.mount(connection) },
                                    onDisconnect: { mountService.unmount(connection) },
                                    onRunBenchmark: { Task { await mountService.runBenchmark(for: connection) } },
                                    onRefreshDetails: { mountService.refreshRuntimeDetails(for: connection) },
                                    onOpenMountPoint: { openMountPoint(for: connection) },
                                    onCopyURL: { copyText(connection.smbURL) }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedConnection = connection
                                }
                            }
                            .onDelete(perform: deleteConnections)
                        }
                    }
                }
            }
            .navigationTitle("SMB Mount Manager")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        connectAll()
                    } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .help("Connect All")

                    Button {
                        disconnectAll()
                    } label: {
                        Image(systemName: "bolt.slash.fill")
                    }
                    .help("Disconnect All")

                    Button {
                        isShowingDiscovery = true
                    } label: {
                        Image(systemName: "network")
                    }
                    .help("Discover SMB Servers")

                    Button {
                        isShowingDiagnostics = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .help("Open Diagnostics Console")

                    Button {
                        suggestedHost = nil
                        isAddingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Connection")
                }
            }
            .sheet(isPresented: $isAddingNew) {
                ConnectionEditView(existing: nil, suggestedHost: suggestedHost, mountService: mountService) { connection, password in
                    KeychainService.savePassword(password, for: connection)
                    connections.append(connection)
                    saveAndRefresh()
                }
            }
            .sheet(isPresented: $isShowingDiscovery) {
                DiscoveryView(
                    discoveryService: discoveryService,
                    configuredHosts: Set(connections.map { $0.serverAddress.lowercased() })
                ) { host in
                    suggestedHost = host
                    DispatchQueue.main.async {
                        isAddingNew = true
                    }
                }
            }
            .sheet(isPresented: $isShowingDiagnostics) {
                DiagnosticsConsoleView(
                    loggingService: loggingService,
                    mountService: mountService,
                    connections: connections
                )
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditView(existing: connection, mountService: mountService) { updated, password in
                    let otherConnections = connections.filter { $0.id != connection.id }
                    KeychainService.savePassword(password, for: updated)
                    if let idx = connections.firstIndex(where: { $0.id == updated.id }) {
                        connections[idx] = updated
                    }
                    if connection.serverAddress.caseInsensitiveCompare(updated.serverAddress) != .orderedSame ||
                        connection.username.caseInsensitiveCompare(updated.username) != .orderedSame {
                        KeychainService.deletePassword(for: connection, remainingConnections: otherConnections)
                    }
                    saveAndRefresh()
                }
            }
            .sheet(item: $selectedConnection) { connection in
                ConnectionDetailsSheet(
                    connection: connection,
                    status: mountService.statuses[connection.id] ?? .disconnected,
                    runtimeDetails: mountService.runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails(),
                    onConnect: { mountService.mount(connection) },
                    onDisconnect: { mountService.unmount(connection) },
                    onBenchmark: { Task { await mountService.runBenchmark(for: connection) } },
                    onRefresh: { mountService.refreshRuntimeDetails(for: connection) },
                    onEdit: {
                        selectedConnection = nil
                        editingConnection = connection
                    },
                    onOpenMountPoint: { openMountPoint(for: connection) },
                    onCopyURL: { copyText(connection.smbURL) }
                )
            }
            .onAppear {
                LoggingService.shared.record(.info, category: .app, message: "Application interface appeared")
                connections = PersistenceService.load()
                mountService.startMonitoring(connections: connections)
                applyLaunchBehaviorIfNeeded()
            }
            .onDisappear {
                LoggingService.shared.record(.info, category: .app, message: "Application interface disappeared")
                mountService.stopMonitoring()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                handleApplicationWillTerminate()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Link("Matteo Sala", destination: URL(string: "https://github.com/CySalazar")!)
                Text("•")
                    .foregroundStyle(.tertiary)
                Link(destination: URL(string: "https://github.com/CySalazar")!) {
                    Image("GitHubMark")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.primary)
                }
                .help("Open GitHub profile")

                Spacer()

                Text(summaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(buildRevisionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("Search connections", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Picker("Status", selection: $statusFilter) {
                ForEach(ConnectionStatusFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(width: 150)

            Picker("Sort", selection: $sortMode) {
                ForEach(ConnectionSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.15))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: connections.isEmpty ? "externaldrive.connected.to.line.below" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(connections.isEmpty ? "No Connections" : "No Matches")
                .font(.title2)
            Text(connections.isEmpty ? "Add an SMB connection to get started." : "Adjust the search text or filters to show saved connections.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredConnections: [SMBConnection] {
        let searched = connections.filter { connection in
            let haystack = [
                connection.name,
                connection.serverAddress,
                connection.shareName,
                connection.username
            ].joined(separator: " ").lowercased()
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || haystack.contains(searchText.lowercased())
        }

        let filtered = searched.filter { connection in
            let status = mountService.statuses[connection.id] ?? .disconnected
            let details = mountService.runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails()

            switch statusFilter {
            case .all:
                return true
            case .connected:
                return status == .connected
            case .disconnected:
                return status == .disconnected
            case .errors:
                if case .error = status { return true }
                return false
            case .unstable:
                return details.stabilityGrade == .low || details.stabilityGrade == .insufficientHistory
            }
        }

        return filtered.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
            case .host:
                return lhs.serverAddress.localizedCaseInsensitiveCompare(rhs.serverAddress) == .orderedAscending
            case .status:
                return statusSortValue(for: lhs) < statusSortValue(for: rhs)
            case .latency:
                return (mountService.runtimeDetails[lhs.id]?.lastProbeLatency ?? .greatestFiniteMagnitude) <
                    (mountService.runtimeDetails[rhs.id]?.lastProbeLatency ?? .greatestFiniteMagnitude)
            case .stability:
                return stabilitySortValue(for: lhs) > stabilitySortValue(for: rhs)
            }
        }
    }

    private var summaryLabel: String {
        let connectedCount = connections.filter { mountService.statuses[$0.id] == .connected }.count
        return "\(connectedCount)/\(connections.count) connected"
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            let connection = filteredConnections[index]
            let remainingConnections = connections.filter { $0.id != connection.id }
            KeychainService.deletePassword(for: connection, remainingConnections: remainingConnections)
            LoggingService.shared.record(.info, category: .ui, message: "Deleted connection \(connection.serverAddress)/\(connection.shareName)")
            connections.removeAll { $0.id == connection.id }
        }
        saveAndRefresh()
    }

    private func connectAll() {
        for connection in filteredConnections {
            let status = mountService.statuses[connection.id] ?? .disconnected
            if status != .connected && status != .connecting {
                mountService.mount(connection)
            }
        }
    }

    private func disconnectAll() {
        for connection in filteredConnections where mountService.statuses[connection.id] == .connected {
            mountService.unmount(connection)
        }
    }

    private func saveAndRefresh() {
        PersistenceService.save(connections)
        mountService.updateConnections(connections)
        LoggingService.shared.record(.debug, category: .ui, message: "Connection list refreshed with \(connections.count) entries")
    }

    private func applyLaunchBehaviorIfNeeded() {
        guard hasAppliedLaunchBehavior == false else {
            return
        }

        hasAppliedLaunchBehavior = true

        guard connectSharesOnLaunch else {
            return
        }

        for connection in connections where connection.autoConnect {
            let status = mountService.statuses[connection.id] ?? .disconnected
            if status != .connected && status != .connecting {
                mountService.mount(connection)
            }
        }
    }

    private func handleApplicationWillTerminate() {
        guard disconnectSharesOnQuit else {
            return
        }

        for connection in connections where mountService.statuses[connection.id] == .connected {
            mountService.unmount(connection)
        }
    }

    private func displayName(for connection: SMBConnection) -> String {
        connection.name.isEmpty ? connection.shareName : connection.name
    }

    private func statusSortValue(for connection: SMBConnection) -> Int {
        switch mountService.statuses[connection.id] ?? .disconnected {
        case .connected:
            return 0
        case .connecting:
            return 1
        case .error:
            return 2
        case .disconnected:
            return 3
        }
    }

    private func stabilitySortValue(for connection: SMBConnection) -> Int {
        let grade = mountService.runtimeDetails[connection.id]?.stabilityGrade ?? .insufficientHistory
        switch grade {
        case .high:
            return 3
        case .medium:
            return 2
        case .low:
            return 1
        case .insufficientHistory:
            return 0
        }
    }

    private func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openMountPoint(for connection: SMBConnection) {
        NSWorkspace.shared.open(URL(fileURLWithPath: connection.mountPoint))
    }

    private var buildRevisionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let revision = (Bundle.main.object(forInfoDictionaryKey: "AppRevision") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "1"
        return "Version \(version) • Revision \(revision)"
    }
}

private struct ConnectionDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let connection: SMBConnection
    let status: ConnectionStatus
    let runtimeDetails: SMBConnectionRuntimeDetails
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onBenchmark: () -> Void
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onOpenMountPoint: () -> Void
    let onCopyURL: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name.isEmpty ? connection.shareName : connection.name)
                        .font(.title3.weight(.semibold))
                    Text(connection.smbURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("Edit") {
                    onEdit()
                }

                Button(status == .connected ? "Disconnect" : "Connect") {
                    status == .connected ? onDisconnect() : onConnect()
                }
            }

            Form {
                Section("Live") {
                    detailRow("Status", status.label)
                    detailRow("Protocol", runtimeDetails.protocolVersion ?? "Unknown")
                    detailRow("Last Probe", format(duration: runtimeDetails.lastProbeLatency))
                    detailRow("Average Probe", format(duration: runtimeDetails.averageProbeLatency))
                    detailRow("Path", runtimeDetails.mountedVolumePath ?? connection.mountPoint)
                    detailRow("Volume", runtimeDetails.volumeName ?? "Unknown")
                    detailRow("Free Space", format(bytes: runtimeDetails.volumeAvailableCapacityBytes))
                    detailRow("Total Space", format(bytes: runtimeDetails.volumeTotalCapacityBytes))
                }

                Section("Historical") {
                    detailRow("Success Rate", String(format: "%.0f%%", runtimeDetails.successRate * 100))
                    detailRow("Mounts", "\(runtimeDetails.successfulMounts)")
                    detailRow("Failures", "\(runtimeDetails.failedMounts)")
                    detailRow("Disconnects", "\(runtimeDetails.disconnectCount)")
                    detailRow("Uptime", format(duration: runtimeDetails.totalConnectedDuration))
                    detailRow("Downtime", format(duration: runtimeDetails.totalDisconnectedDuration))
                }

                Section("Estimated") {
                    detailRow("Stability", runtimeDetails.stabilityGrade.title)
                    detailRow("Confidence", runtimeDetails.confidenceLevel.title)
                    detailRow("Error Trend", topError)
                }

                Section("Manual Benchmark") {
                    detailRow("Last Result", runtimeDetails.benchmarkStatusMessage ?? "Not run")
                    if let benchmark = runtimeDetails.benchmarkResult {
                        detailRow("Write", String(format: "%.2f MB/s", benchmark.writeThroughputMBps))
                        detailRow("Read", String(format: "%.2f MB/s", benchmark.readThroughputMBps))
                    }

                    Text("Inspecting a mounted share reads live file-system details and macOS may ask for permission to access the network volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Run Benchmark", action: onBenchmark)
                            .disabled(status != .connected || runtimeDetails.isBenchmarkRunning)
                        Button("Inspect Share", action: onRefresh)
                            .disabled(status != .connected)
                        Button("Open Mount Point", action: onOpenMountPoint)
                        Button("Copy SMB URL", action: onCopyURL)
                    }
                }

                if runtimeDetails.timeline.isEmpty == false {
                    Section("Timeline") {
                        ForEach(runtimeDetails.timeline.sorted(by: { $0.timestamp > $1.timestamp })) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                Text(event.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 560)
    }

    private var topError: String {
        guard let top = runtimeDetails.errorCounts.max(by: { $0.value < $1.value }) else {
            return "None"
        }

        return "\(ConnectionErrorCategory(rawValue: top.key)?.title ?? top.key): \(top.value)"
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func format(duration: TimeInterval?) -> String {
        guard let duration else {
            return "Not available"
        }
        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }

    private func format(bytes: Int64?) -> String {
        guard let bytes else {
            return "Not available"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
