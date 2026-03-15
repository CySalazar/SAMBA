import AppKit
import Foundation

@MainActor
final class MountService: ObservableObject {
    @Published var statuses: [UUID: ConnectionStatus] = [:]
    @Published var maximumAutomaticRetryCount: Int {
        didSet {
            UserDefaults.standard.set(maximumAutomaticRetryCount, forKey: Self.maximumAutomaticRetryCountDefaultsKey)
        }
    }

    private var statusTimer: Timer?
    private var autoConnectTimer: Timer?
    private var connections: [SMBConnection] = []
    private var pendingMountRequests: [MountRequest] = []
    private var activeMountRequest: MountRequest?
    private var automaticRetryCounts: [UUID: Int] = [:]
    private let fileManager = FileManager.default
    private static let maximumAutomaticRetryCountDefaultsKey = "maximumAutomaticRetryCount"

    init() {
        let storedRetryCount = UserDefaults.standard.integer(forKey: Self.maximumAutomaticRetryCountDefaultsKey)
        maximumAutomaticRetryCount = storedRetryCount > 0 ? storedRetryCount : 5
    }

    func startMonitoring(connections: [SMBConnection]) {
        self.connections = connections
        LoggingService.shared.record(.info, category: .mount, message: "Starting monitoring for \(connections.count) connections")
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
        LoggingService.shared.record(.debug, category: .mount, message: "Stopping connection monitoring")
        statusTimer?.invalidate()
        statusTimer = nil
        autoConnectTimer?.invalidate()
        autoConnectTimer = nil
    }

    func updateConnections(_ connections: [SMBConnection]) {
        self.connections = connections
        pendingMountRequests.removeAll { request in
            !connections.contains(where: { $0.id == request.connectionID })
        }
        automaticRetryCounts = automaticRetryCounts.filter { connectionID, _ in
            connections.contains(where: { $0.id == connectionID })
        }
        if let activeMountRequest,
           !connections.contains(where: { $0.id == activeMountRequest.connectionID }) {
            self.activeMountRequest = nil
        }
        LoggingService.shared.record(.debug, category: .mount, message: "Updated monitored connections to \(connections.count)")
        refreshAllStatuses()
        processNextMountIfNeeded()
    }

    // MARK: - Mount

    func mount(_ connection: SMBConnection, initiatedByUser: Bool = true) {
        if isMounted(connection) {
            statuses[connection.id] = .connected
            LoggingService.shared.record(.debug, category: .mount, message: "Mount skipped for \(connection.serverAddress)/\(connection.shareName): already connected")
            automaticRetryCounts[connection.id] = 0
            return
        }

        if initiatedByUser {
            automaticRetryCounts[connection.id] = 0
        } else if automaticRetryCounts[connection.id, default: 0] >= maximumAutomaticRetryCount {
            statuses[connection.id] = .error("Automatic retry limit reached")
            LoggingService.shared.record(
                .warning,
                category: .mount,
                message: "Automatic reconnect suppressed for \(connection.serverAddress)/\(connection.shareName): retry limit \(maximumAutomaticRetryCount) reached"
            )
            return
        }

        if activeMountRequest?.connectionID == connection.id {
            if initiatedByUser, activeMountRequest?.initiatedByUser == false {
                activeMountRequest = MountRequest(connectionID: connection.id, initiatedByUser: true)
                LoggingService.shared.record(.debug, category: .mount, message: "Active mount upgraded to explicit user request for \(connection.serverAddress)/\(connection.shareName)")
            } else {
                LoggingService.shared.record(.debug, category: .mount, message: "Mount request ignored for \(connection.serverAddress)/\(connection.shareName): already in progress")
            }
            return
        }

        if let index = pendingMountRequests.firstIndex(where: { $0.connectionID == connection.id }) {
            if initiatedByUser, pendingMountRequests[index].initiatedByUser == false {
                pendingMountRequests[index] = MountRequest(connectionID: connection.id, initiatedByUser: true)
                LoggingService.shared.record(.debug, category: .mount, message: "Queued mount upgraded to explicit user request for \(connection.serverAddress)/\(connection.shareName)")
            } else {
                LoggingService.shared.record(.debug, category: .mount, message: "Mount request ignored for \(connection.serverAddress)/\(connection.shareName): already queued")
            }
            return
        }

        statuses[connection.id] = .connecting
        pendingMountRequests.append(MountRequest(connectionID: connection.id, initiatedByUser: initiatedByUser))
        let origin = initiatedByUser ? "user" : "automatic"
        LoggingService.shared.record(.info, category: .mount, message: "Queued \(origin) mount for \(connection.serverAddress)/\(connection.shareName)")
        processNextMountIfNeeded()
    }

    private func startMount(_ connection: SMBConnection, initiatedByUser: Bool) {
        guard let password = KeychainService.loadPassword(for: connection.id) else {
            statuses[connection.id] = .error("No password in Keychain")
            LoggingService.shared.record(.error, category: .mount, message: "Mount aborted for \(connection.serverAddress)/\(connection.shareName): missing password")
            registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
            finishMountAttempt(for: connection.id)
            return
        }

        statuses[connection.id] = .connecting
        LoggingService.shared.record(.info, category: .mount, message: "Mount requested for \(connection.serverAddress)/\(connection.shareName)")

        // Percent-encode user and password for URL safety
        let user = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? connection.username
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password

        let urlString = "smb://\(user):\(pass)@\(connection.serverAddress)/\(connection.shareName)"
        guard let url = URL(string: urlString) else {
            statuses[connection.id] = .error("Invalid SMB URL")
            LoggingService.shared.record(.error, category: .mount, message: "Invalid SMB URL for \(connection.serverAddress)/\(connection.shareName)")
            registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
            finishMountAttempt(for: connection.id)
            return
        }

        NSWorkspace.shared.open(url)

        Task { [weak self] in
            await self?.waitForMount(of: connection)
        }
    }

    // MARK: - Unmount

    func unmount(_ connection: SMBConnection) {
        statuses[connection.id] = .connecting
        LoggingService.shared.record(.info, category: .mount, message: "Unmount requested for \(connection.serverAddress)/\(connection.shareName)")

        guard let mountedVolumeURL = mountedVolumeURL(for: connection) else {
            statuses[connection.id] = .disconnected
            LoggingService.shared.record(.warning, category: .mount, message: "Unmount skipped for \(connection.serverAddress)/\(connection.shareName): mount point not found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = [mountedVolumeURL.path]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                statuses[connection.id] = .disconnected
                LoggingService.shared.record(.info, category: .mount, message: "Unmounted \(connection.serverAddress)/\(connection.shareName)")
            } else {
                // Try with diskutil if umount fails
                let diskutil = Process()
                diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                diskutil.arguments = ["unmount", mountedVolumeURL.path]
                try diskutil.run()
                diskutil.waitUntilExit()

                if diskutil.terminationStatus == 0 {
                    statuses[connection.id] = .disconnected
                    LoggingService.shared.record(.info, category: .mount, message: "Unmounted \(connection.serverAddress)/\(connection.shareName) via diskutil fallback")
                } else {
                    statuses[connection.id] = .error("Unmount failed")
                    LoggingService.shared.record(.error, category: .mount, message: "Unmount failed for \(connection.serverAddress)/\(connection.shareName)")
                }
            }
        } catch {
            statuses[connection.id] = .error(error.localizedDescription)
            LoggingService.shared.record(.error, category: .mount, message: "Unmount error for \(connection.serverAddress)/\(connection.shareName): \(error.localizedDescription)")
        }
    }

    // MARK: - Status Check

    func isMounted(_ connection: SMBConnection) -> Bool {
        mountedVolumeURL(for: connection) != nil
    }

    private func checkAndUpdateStatus(for connection: SMBConnection) {
        if isMounted(connection) {
            statuses[connection.id] = .connected
            LoggingService.shared.record(.info, category: .mount, message: "Connection marked connected for \(connection.serverAddress)/\(connection.shareName)")
            automaticRetryCounts[connection.id] = 0
        } else if statuses[connection.id] == .connecting {
            statuses[connection.id] = .error("Mount did not appear")
            LoggingService.shared.record(.error, category: .mount, message: "Mount timed out for \(connection.serverAddress)/\(connection.shareName)")
            registerFailure(for: connection.id, initiatedByUser: activeMountRequest?.initiatedByUser ?? false)
        }

        finishMountAttempt(for: connection.id)
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
                mount(connection, initiatedByUser: false)
            }
        }
    }

    private func waitForMount(of connection: SMBConnection) async {
        for _ in 0..<15 {
            if isMounted(connection) {
                statuses[connection.id] = .connected
                LoggingService.shared.record(.debug, category: .mount, message: "Detected mounted SMB volume for \(connection.serverAddress)/\(connection.shareName)")
                finishMountAttempt(for: connection.id)
                return
            }

            try? await Task.sleep(for: .seconds(1))
        }

        checkAndUpdateStatus(for: connection)
    }

    private func mountedVolumeURL(for connection: SMBConnection) -> URL? {
        if isSMBMount(atPath: connection.mountPoint) {
            return URL(fileURLWithPath: connection.mountPoint, isDirectory: true)
        }

        let resourceKeys: [URLResourceKey] = [.volumeURLForRemountingKey]

        guard let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) else {
            return nil
        }

        return volumeURLs.first { matches(connection, mountedVolumeURL: $0) }
    }

    private func matches(_ connection: SMBConnection, mountedVolumeURL: URL) -> Bool {
        guard isSMBMount(atPath: mountedVolumeURL.path) else {
            return false
        }

        guard let resourceValues = try? mountedVolumeURL.resourceValues(forKeys: [
            .volumeURLForRemountingKey
        ]) else {
            return false
        }

        if let remountURL = resourceValues.volumeURLForRemounting,
           connection.matchesRemote(server: remountURL.host(), share: remountURL.lastPathComponent) {
            return true
        }

        return false
    }

    private func isSMBMount(atPath path: String) -> Bool {
        var fileSystemStats = statfs()
        guard statfs(path, &fileSystemStats) == 0 else {
            return false
        }

        let fileSystemType = withUnsafePointer(to: &fileSystemStats.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }

        return fileSystemType == "smbfs"
    }

    private func processNextMountIfNeeded() {
        guard activeMountRequest == nil else {
            return
        }

        while let nextMountRequest = pendingMountRequests.first {
            pendingMountRequests.removeFirst()

            guard let connection = connections.first(where: { $0.id == nextMountRequest.connectionID }) else {
                continue
            }

            activeMountRequest = nextMountRequest
            startMount(connection, initiatedByUser: nextMountRequest.initiatedByUser)
            return
        }
    }

    private func finishMountAttempt(for connectionID: UUID) {
        if activeMountRequest?.connectionID == connectionID {
            activeMountRequest = nil
            processNextMountIfNeeded()
        } else {
            pendingMountRequests.removeAll { $0.connectionID == connectionID }
        }
    }

    private func registerFailure(for connectionID: UUID, initiatedByUser: Bool) {
        guard initiatedByUser == false else {
            automaticRetryCounts[connectionID] = 1
            return
        }

        let newCount = automaticRetryCounts[connectionID, default: 0] + 1
        automaticRetryCounts[connectionID] = newCount

        if let connection = connections.first(where: { $0.id == connectionID }) {
            if newCount >= maximumAutomaticRetryCount {
                LoggingService.shared.record(
                    .warning,
                    category: .mount,
                    message: "Automatic reconnect disabled for \(connection.serverAddress)/\(connection.shareName) after \(newCount) failed attempts"
                )
            } else {
                LoggingService.shared.record(
                    .warning,
                    category: .mount,
                    message: "Automatic reconnect attempt \(newCount) of \(maximumAutomaticRetryCount) failed for \(connection.serverAddress)/\(connection.shareName)"
                )
            }
        }
    }
}

private struct MountRequest {
    let connectionID: UUID
    let initiatedByUser: Bool
}

private extension SMBConnection {
    func matchesRemote(server: String?, share: String) -> Bool {
        guard let server, !server.isEmpty else {
            return false
        }

        return server.caseInsensitiveCompare(serverAddress) == .orderedSame &&
            share.caseInsensitiveCompare(shareName) == .orderedSame
    }
}
