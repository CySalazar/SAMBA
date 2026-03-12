import AppKit
import Foundation

@MainActor
final class MountService: ObservableObject {
    @Published var statuses: [UUID: ConnectionStatus] = [:]

    private var statusTimer: Timer?
    private var autoConnectTimer: Timer?
    private var connections: [SMBConnection] = []

    func startMonitoring(connections: [SMBConnection]) {
        self.connections = connections
        refreshAllStatuses()

        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllStatuses()
            }
        }

        autoConnectTimer?.invalidate()
        autoConnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoReconnect()
            }
        }
    }

    func stopMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
        autoConnectTimer?.invalidate()
        autoConnectTimer = nil
    }

    func updateConnections(_ connections: [SMBConnection]) {
        self.connections = connections
        refreshAllStatuses()
    }

    // MARK: - Mount

    func mount(_ connection: SMBConnection) {
        guard let password = KeychainService.loadPassword(for: connection.id) else {
            statuses[connection.id] = .error("No password in Keychain")
            return
        }

        statuses[connection.id] = .connecting

        // Percent-encode user and password for URL safety
        let user = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? connection.username
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password

        let urlString = "smb://\(user):\(pass)@\(connection.serverAddress)/\(connection.shareName)"
        guard let url = URL(string: urlString) else {
            statuses[connection.id] = .error("Invalid SMB URL")
            return
        }

        NSWorkspace.shared.open(url)

        // Check mount after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkAndUpdateStatus(for: connection)
        }
    }

    // MARK: - Unmount

    func unmount(_ connection: SMBConnection) {
        statuses[connection.id] = .connecting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = [connection.mountPoint]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                statuses[connection.id] = .disconnected
            } else {
                // Try with diskutil if umount fails
                let diskutil = Process()
                diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                diskutil.arguments = ["unmount", connection.mountPoint]
                try diskutil.run()
                diskutil.waitUntilExit()

                if diskutil.terminationStatus == 0 {
                    statuses[connection.id] = .disconnected
                } else {
                    statuses[connection.id] = .error("Unmount failed")
                }
            }
        } catch {
            statuses[connection.id] = .error(error.localizedDescription)
        }
    }

    // MARK: - Status Check

    func isMounted(_ connection: SMBConnection) -> Bool {
        let path = connection.mountPoint
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return false }
        // Check that it's actually a mount point (different device than parent)
        let fsType = withUnsafePointer(to: &stat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return fsType == "smbfs"
    }

    private func checkAndUpdateStatus(for connection: SMBConnection) {
        if isMounted(connection) {
            statuses[connection.id] = .connected
        } else if statuses[connection.id] == .connecting {
            statuses[connection.id] = .error("Mount did not appear")
        }
    }

    private func refreshAllStatuses() {
        for connection in connections {
            let current = statuses[connection.id]
            // Don't overwrite "connecting" status
            if case .connecting = current { continue }

            statuses[connection.id] = isMounted(connection) ? .connected : .disconnected
        }
    }

    private func autoReconnect() {
        for connection in connections where connection.autoConnect {
            if statuses[connection.id] != .connected && statuses[connection.id] != .connecting {
                mount(connection)
            }
        }
    }
}
