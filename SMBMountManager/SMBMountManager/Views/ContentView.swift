import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var mountService = MountService()
    @StateObject private var loggingService = LoggingService.shared
    @StateObject private var discoveryService = SMBDiscoveryService()
    @AppStorage("connectSharesOnLaunch") private var connectSharesOnLaunch = false
    @AppStorage("disconnectSharesOnQuit") private var disconnectSharesOnQuit = false
    @State private var connections: [SMBConnection] = []
    @State private var editingConnection: SMBConnection?
    @State private var isAddingNew = false
    @State private var isShowingDiagnostics = false
    @State private var isShowingDiscovery = false
    @State private var suggestedHost: DiscoveredSMBHost?
    @State private var hasAppliedLaunchBehavior = false

    var body: some View {
        NavigationStack {
            Group {
                if connections.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Connections")
                            .font(.title2)
                        Text("Add an SMB connection to get started.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(connections) { connection in
                            ConnectionRow(
                                connection: connection,
                                status: mountService.statuses[connection.id] ?? .disconnected,
                                onConnect: { mountService.mount(connection) },
                                onDisconnect: { mountService.unmount(connection) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingConnection = connection
                            }
                        }
                        .onDelete(perform: deleteConnections)
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
                        Image(systemName: "text.alignleft")
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
                ConnectionEditView(existing: nil, suggestedHost: suggestedHost) { connection, password in
                    KeychainService.savePassword(password, for: connection.id)
                    connections.append(connection)
                    saveAndRefresh()
                }
            }
            .sheet(isPresented: $isShowingDiscovery) {
                DiscoveryView(discoveryService: discoveryService) { host in
                    suggestedHost = host
                    DispatchQueue.main.async {
                        isAddingNew = true
                    }
                }
            }
            .sheet(isPresented: $isShowingDiagnostics) {
                DiagnosticsConsoleView(loggingService: loggingService, mountService: mountService)
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditView(existing: connection) { updated, password in
                    KeychainService.savePassword(password, for: updated.id)
                    if let idx = connections.firstIndex(where: { $0.id == updated.id }) {
                        connections[idx] = updated
                    }
                    saveAndRefresh()
                }
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

                Text(buildRevisionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            KeychainService.deletePassword(for: connections[index].id)
            LoggingService.shared.record(.info, category: .ui, message: "Deleted connection \(connections[index].serverAddress)/\(connections[index].shareName)")
        }
        connections.remove(atOffsets: offsets)
        saveAndRefresh()
    }

    private func connectAll() {
        for connection in connections {
            let status = mountService.statuses[connection.id] ?? .disconnected
            if status != .connected && status != .connecting {
                LoggingService.shared.record(.info, category: .ui, message: "Connect all requested for \(connection.serverAddress)/\(connection.shareName)")
                mountService.mount(connection)
            }
        }
    }

    private func disconnectAll() {
        for connection in connections {
            if mountService.statuses[connection.id] == .connected {
                LoggingService.shared.record(.info, category: .ui, message: "Disconnect all requested for \(connection.serverAddress)/\(connection.shareName)")
                mountService.unmount(connection)
            }
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
                LoggingService.shared.record(.info, category: .app, message: "Connecting auto-connect share on app launch: \(connection.serverAddress)/\(connection.shareName)")
                mountService.mount(connection)
            }
        }
    }

    private func handleApplicationWillTerminate() {
        guard disconnectSharesOnQuit else {
            return
        }

        for connection in connections where mountService.statuses[connection.id] == .connected {
            LoggingService.shared.record(.info, category: .app, message: "Disconnecting share on app termination: \(connection.serverAddress)/\(connection.shareName)")
            mountService.unmount(connection)
        }
    }

    private var buildRevisionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let revision = (Bundle.main.object(forInfoDictionaryKey: "AppRevision") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "1"
        return "Version \(version) • Revision \(revision)"
    }
}
