import AppKit
import ServiceManagement
import SwiftUI

@main
struct SMBMountManagerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("SMB Mount Manager", id: "main") {
            ContentView(appState: appState)
        }
        .defaultSize(width: 600, height: 400)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var connections: [SMBConnection]
    @Published var hasAppliedLaunchBehavior = false
    @Published var showMenuBarExtra: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarExtra, forKey: Self.showMenuBarExtraDefaultsKey)
        }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginStatusMessage: String?

    let mountService = MountService()
    let loggingService = LoggingService.shared
    let discoveryService = SMBDiscoveryService()

    private static let showMenuBarExtraDefaultsKey = "showMenuBarExtra"

    init() {
        connections = PersistenceService.load()
        showMenuBarExtra = UserDefaults.standard.object(forKey: Self.showMenuBarExtraDefaultsKey) as? Bool ?? true
        mountService.startMonitoring(connections: connections)
        refreshLaunchAtLoginState()
    }

    func addConnection(_ connection: SMBConnection, password: String) {
        KeychainService.savePassword(password, for: connection)
        connections.append(connection)
        persistConnections()
    }

    func updateConnection(original: SMBConnection, updated: SMBConnection, password: String) {
        let otherConnections = connections.filter { $0.id != original.id }
        KeychainService.savePassword(password, for: updated)
        if let index = connections.firstIndex(where: { $0.id == updated.id }) {
            connections[index] = updated
        }
        if original.serverAddress.caseInsensitiveCompare(updated.serverAddress) != .orderedSame ||
            original.username.caseInsensitiveCompare(updated.username) != .orderedSame {
            KeychainService.deletePassword(for: original, remainingConnections: otherConnections)
        }
        persistConnections()
    }

    func deleteConnections(withIDs ids: Set<UUID>) {
        for connection in connections where ids.contains(connection.id) {
            let remainingConnections = connections.filter { $0.id != connection.id }
            KeychainService.deletePassword(for: connection, remainingConnections: remainingConnections)
            LoggingService.shared.record(.info, category: .ui, message: "Deleted connection \(connection.serverAddress)/\(connection.shareName)")
        }
        connections.removeAll { ids.contains($0.id) }
        persistConnections()
    }

    func connectAll(_ candidates: [SMBConnection]? = nil) {
        let targets = candidates ?? connections
        for connection in targets {
            let status = mountService.statuses[connection.id] ?? .disconnected
            if status != .connected && status != .connecting {
                mountService.mount(connection)
            }
        }
    }

    func disconnectAll(_ candidates: [SMBConnection]? = nil) {
        let targets = candidates ?? connections
        for connection in targets where mountService.statuses[connection.id] == .connected {
            mountService.unmount(connection)
        }
    }

    func applyLaunchBehaviorIfNeeded(connectSharesOnLaunch: Bool) {
        guard hasAppliedLaunchBehavior == false else {
            return
        }
        hasAppliedLaunchBehavior = true

        guard connectSharesOnLaunch else {
            return
        }

        connectAll(connections.filter(\.autoConnect))
    }

    func handleApplicationWillTerminate(disconnectSharesOnQuit: Bool) {
        guard disconnectSharesOnQuit else {
            return
        }

        disconnectAll(connections.filter { mountService.statuses[$0.id] == .connected })
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginStatusMessage = enabled ? "Launch at login enabled." : "Launch at login disabled."
            LoggingService.shared.record(.info, category: .app, message: launchAtLoginStatusMessage ?? "Updated launch at login")
        } catch {
            launchAtLoginStatusMessage = "Launch at login update failed: \(error.localizedDescription)"
            LoggingService.shared.record(.warning, category: .app, message: launchAtLoginStatusMessage ?? "Failed to update launch at login")
        }

        refreshLaunchAtLoginState()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func exportConnections(to url: URL) throws {
        let data = try PersistenceCodec.encodeConnections(connections)
        try data.write(to: url, options: .atomic)
        LoggingService.shared.record(.info, category: .persistence, message: "Exported \(connections.count) connections to \(url.lastPathComponent)")
    }

    func importConnections(from url: URL) throws -> (imported: Int, skipped: Int) {
        let data = try Data(contentsOf: url)
        let importedConnections = try PersistenceCodec.decodeConnections(from: data)
        let result = mergeImportedConnections(importedConnections)
        persistConnections()
        LoggingService.shared.record(.info, category: .persistence, message: "Imported \(result.imported) connections from \(url.lastPathComponent); skipped \(result.skipped)")
        return result
    }

    private func mergeImportedConnections(_ importedConnections: [SMBConnection]) -> (imported: Int, skipped: Int) {
        var importedCount = 0
        var skippedCount = 0
        var seenIdentities = Set(connections.map(\.remoteIdentity))

        for connection in importedConnections {
            if seenIdentities.contains(connection.remoteIdentity) {
                skippedCount += 1
                continue
            }
            seenIdentities.insert(connection.remoteIdentity)
            connections.append(connection)
            importedCount += 1
        }

        return (importedCount, skippedCount)
    }

    private func persistConnections() {
        PersistenceService.save(connections)
        mountService.updateConnections(connections)
        LoggingService.shared.record(.debug, category: .ui, message: "Connection list refreshed with \(connections.count) entries")
    }

    private func refreshLaunchAtLoginState() {
        Task.detached(priority: .utility) {
            let statusDescription = String(describing: SMAppService.mainApp.status).lowercased()
            let isEnabled = statusDescription.contains("notregistered") == false
            let requiresApproval = statusDescription.contains("requiresapproval")

            await MainActor.run {
                self.launchAtLoginEnabled = isEnabled
                self.launchAtLoginRequiresApproval = requiresApproval
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle("Show Menu Bar Extra", isOn: $appState.showMenuBarExtra)
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { appState.toggleLaunchAtLogin($0) }
                )
            )

            if let launchAtLoginStatusMessage = appState.launchAtLoginStatusMessage {
                Text(launchAtLoginStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.launchAtLoginRequiresApproval {
                Button("Open Login Items Settings") {
                    appState.openLoginItemsSettings()
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private extension SMBConnection {
    var remoteIdentity: String {
        [
            serverAddress.lowercased(),
            shareName.lowercased(),
            username.lowercased()
        ].joined(separator: "::")
    }
}
