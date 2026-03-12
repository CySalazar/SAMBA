import SwiftUI

struct ContentView: View {
    @StateObject private var mountService = MountService()
    @State private var connections: [SMBConnection] = []
    @State private var editingConnection: SMBConnection?
    @State private var isAddingNew = false

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
                        isAddingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Connection")
                }
            }
            .sheet(isPresented: $isAddingNew) {
                ConnectionEditView(existing: nil) { connection, password in
                    KeychainService.savePassword(password, for: connection.id)
                    connections.append(connection)
                    saveAndRefresh()
                }
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
                connections = PersistenceService.load()
                mountService.startMonitoring(connections: connections)
            }
            .onDisappear {
                mountService.stopMonitoring()
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            KeychainService.deletePassword(for: connections[index].id)
        }
        connections.remove(atOffsets: offsets)
        saveAndRefresh()
    }

    private func connectAll() {
        for connection in connections {
            let status = mountService.statuses[connection.id] ?? .disconnected
            if status != .connected && status != .connecting {
                mountService.mount(connection)
            }
        }
    }

    private func disconnectAll() {
        for connection in connections {
            if mountService.statuses[connection.id] == .connected {
                mountService.unmount(connection)
            }
        }
    }

    private func saveAndRefresh() {
        PersistenceService.save(connections)
        mountService.updateConnections(connections)
    }
}
