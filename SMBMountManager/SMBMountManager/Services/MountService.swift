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
    private var consecutiveMissedChecks: [UUID: Int] = [:]
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
        consecutiveMissedChecks = consecutiveMissedChecks.filter { connectionID, _ in
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
            setStatus(.connected, for: connection.id)
            LoggingService.shared.record(.debug, category: .mount, message: "Mount skipped for \(connection.serverAddress)/\(connection.shareName): already connected")
            automaticRetryCounts[connection.id] = 0
            return
        }

        if initiatedByUser {
            automaticRetryCounts[connection.id] = 0
        } else if automaticRetryCounts[connection.id, default: 0] >= maximumAutomaticRetryCount {
            setStatus(.error("Automatic retry limit reached"), for: connection.id)
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

        setStatus(.connecting, for: connection.id)
        pendingMountRequests.append(MountRequest(connectionID: connection.id, initiatedByUser: initiatedByUser))
        let origin = initiatedByUser ? "user" : "automatic"
        LoggingService.shared.record(.info, category: .mount, message: "Queued \(origin) mount for \(connection.serverAddress)/\(connection.shareName) | pending=\(pendingMountRequests.count) active=\(activeMountRequest?.connectionID.uuidString ?? "none")")
        processNextMountIfNeeded()
    }

    private func startMount(_ connection: SMBConnection, initiatedByUser: Bool) {
        guard let password = KeychainService.loadPassword(for: connection) else {
            setStatus(.error("Password missing in Keychain"), for: connection.id)
            LoggingService.shared.record(.error, category: .mount, message: "Mount aborted for \(connection.serverAddress)/\(connection.shareName): missing password")
            registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
            finishMountAttempt(for: connection.id)
            return
        }

        setStatus(.connecting, for: connection.id)
        LoggingService.shared.record(.info, category: .mount, message: "Starting silent mount for \(connection.serverAddress)/\(connection.shareName) | mountPoint=\(connection.mountPoint) initiatedByUser=\(initiatedByUser)")

        let mountPointURL = URL(fileURLWithPath: connection.mountPoint, isDirectory: true)
        do {
            try fileManager.createDirectory(at: mountPointURL, withIntermediateDirectories: true)
        } catch {
            setStatus(.error("Unable to prepare writable mount point"), for: connection.id)
            LoggingService.shared.record(.error, category: .mount, message: "Failed to create mount point \(mountPointURL.path): \(error.localizedDescription)")
            registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
            finishMountAttempt(for: connection.id)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = [
            "-t", "smbfs",
            "-o", "nobrowse,nopassprompt",
            smbService(connection: connection, password: password),
            mountPointURL.path
        ]

        LoggingService.shared.record(.debug, category: .mount, message: "Launching /sbin/mount for \(connection.serverAddress)/\(connection.shareName) | arguments=\(process.arguments?.joined(separator: " ") ?? "none")")

        let standardError = Pipe()
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            setStatus(.error("Unable to start mount"), for: connection.id)
            LoggingService.shared.record(.error, category: .mount, message: "Failed to launch silent mount for \(connection.serverAddress)/\(connection.shareName): \(error.localizedDescription)")
            registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
            finishMountAttempt(for: connection.id)
            return
        }

        Task { [weak self] in
            await self?.waitForMount(of: connection, process: process, errorPipe: standardError, initiatedByUser: initiatedByUser)
        }
    }

    // MARK: - Unmount

    func unmount(_ connection: SMBConnection) {
        setStatus(.connecting, for: connection.id)
        LoggingService.shared.record(.info, category: .mount, message: "Unmount requested for \(connection.serverAddress)/\(connection.shareName)")

        guard let mountedVolumeURL = mountedVolumeURL(for: connection) else {
            setStatus(.disconnected, for: connection.id)
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
                setStatus(.disconnected, for: connection.id)
                LoggingService.shared.record(.info, category: .mount, message: "Unmounted \(connection.serverAddress)/\(connection.shareName)")
            } else {
                // Try with diskutil if umount fails
                let diskutil = Process()
                diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                diskutil.arguments = ["unmount", mountedVolumeURL.path]
                try diskutil.run()
                diskutil.waitUntilExit()

                if diskutil.terminationStatus == 0 {
                    setStatus(.disconnected, for: connection.id)
                    LoggingService.shared.record(.info, category: .mount, message: "Unmounted \(connection.serverAddress)/\(connection.shareName) via diskutil fallback")
                } else {
                    setStatus(.error("Unmount failed"), for: connection.id)
                    LoggingService.shared.record(.error, category: .mount, message: "Unmount failed for \(connection.serverAddress)/\(connection.shareName)")
                }
            }
        } catch {
            setStatus(.error(error.localizedDescription), for: connection.id)
            LoggingService.shared.record(.error, category: .mount, message: "Unmount error for \(connection.serverAddress)/\(connection.shareName): \(error.localizedDescription)")
        }
    }

    // MARK: - Status Check

    func isMounted(_ connection: SMBConnection) -> Bool {
        mountedVolumeURL(for: connection) != nil
    }

    private func checkAndUpdateStatus(for connection: SMBConnection) {
        if isMounted(connection) {
            setStatus(.connected, for: connection.id)
            LoggingService.shared.record(.info, category: .mount, message: "Connection marked connected for \(connection.serverAddress)/\(connection.shareName)")
            automaticRetryCounts[connection.id] = 0
        } else if statuses[connection.id] == .connecting {
            setStatus(.error("Mount did not appear"), for: connection.id)
            LoggingService.shared.record(.error, category: .mount, message: "Mount timed out for \(connection.serverAddress)/\(connection.shareName)")
            registerFailure(for: connection.id, initiatedByUser: activeMountRequest?.initiatedByUser ?? false)
        }

        finishMountAttempt(for: connection.id)
    }

    /// Number of consecutive refresh cycles where `isMounted` must return false
    /// before a `.connected` status is downgraded to `.disconnected`.
    /// This avoids flickering caused by transient filesystem enumeration gaps.
    private static let missedCheckThreshold = 2

    private func refreshAllStatuses() {
        for connection in connections {
            let current = statuses[connection.id]
            let mounted = isMounted(connection)

            LoggingService.shared.record(.debug, category: .mount, message: "Refresh status for \(connection.serverAddress)/\(connection.shareName) | current=\(current?.label ?? "nil") mounted=\(mounted) active=\(activeMountRequest?.connectionID == connection.id) queued=\(pendingMountRequests.contains(where: { $0.connectionID == connection.id })) retries=\(automaticRetryCounts[connection.id, default: 0]) missedChecks=\(consecutiveMissedChecks[connection.id, default: 0])")

            if mounted {
                setStatus(.connected, for: connection.id)
                automaticRetryCounts[connection.id] = 0
                consecutiveMissedChecks[connection.id] = 0
                continue
            }

            // Preserve .connecting while a mount attempt is pending
            if case .connecting = current, isMountAttemptPending(for: connection.id) {
                consecutiveMissedChecks[connection.id] = 0
                continue
            }

            // Require multiple consecutive missed checks before downgrading
            // from .connected, to avoid flickering on transient detection gaps.
            if current == .connected {
                let missedCount = (consecutiveMissedChecks[connection.id] ?? 0) + 1
                consecutiveMissedChecks[connection.id] = missedCount
                if missedCount < Self.missedCheckThreshold {
                    continue
                }
            }

            consecutiveMissedChecks[connection.id] = 0
            setStatus(.disconnected, for: connection.id)
        }
    }

    private func autoReconnect() {
        for connection in connections where connection.autoConnect {
            let current = statuses[connection.id]
            // Skip if already connected, currently connecting, or a mount attempt is in flight
            if current == .connected || current == .connecting {
                continue
            }
            if isMountAttemptPending(for: connection.id) {
                continue
            }
            mount(connection, initiatedByUser: false)
        }
    }

    private func waitForMount(of connection: SMBConnection, process: Process, errorPipe: Pipe, initiatedByUser: Bool) async {
        for attempt in 1...15 {
            if isMounted(connection) {
                setStatus(.connected, for: connection.id)
                LoggingService.shared.record(.debug, category: .mount, message: "Detected mounted SMB volume for \(connection.serverAddress)/\(connection.shareName) during wait loop | attempt=\(attempt)")
                finishMountAttempt(for: connection.id)
                return
            }

            LoggingService.shared.record(.debug, category: .mount, message: "Mount wait tick for \(connection.serverAddress)/\(connection.shareName) | attempt=\(attempt) processRunning=\(process.isRunning)")

            if process.isRunning == false {
                if process.terminationStatus == 0 {
                    setStatus(.connected, for: connection.id)
                    automaticRetryCounts[connection.id] = 0
                    consecutiveMissedChecks[connection.id] = 0
                    LoggingService.shared.record(.info, category: .mount, message: "Mount command completed successfully for \(connection.serverAddress)/\(connection.shareName) | exitCode=0")
                    finishMountAttempt(for: connection.id)
                    schedulePostMountVerification(for: connection)
                    return
                }

                let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = userFacingMountError(from: errorOutput, exitCode: process.terminationStatus)
                setStatus(.error(message), for: connection.id)
                LoggingService.shared.record(.error, category: .mount, message: "Silent mount failed for \(connection.serverAddress)/\(connection.shareName) | exitCode=\(process.terminationStatus) stderr=\(errorOutput ?? "none") mappedMessage=\(message)")
                registerFailure(for: connection.id, initiatedByUser: initiatedByUser)
                finishMountAttempt(for: connection.id)
                return
            }

            try? await Task.sleep(for: .seconds(1))
        }

        checkAndUpdateStatus(for: connection)
    }

    private func schedulePostMountVerification(for connection: SMBConnection) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else {
                return
            }

            LoggingService.shared.record(.debug, category: .mount, message: "Running post-mount verification for \(connection.serverAddress)/\(connection.shareName)")

            if self.isMounted(connection) {
                self.setStatus(.connected, for: connection.id)
                LoggingService.shared.record(.info, category: .mount, message: "Post-mount verification confirmed \(connection.serverAddress)/\(connection.shareName)")
            } else {
                self.setStatus(.disconnected, for: connection.id)
                LoggingService.shared.record(.warning, category: .mount, message: "Post-mount verification could not confirm \(connection.serverAddress)/\(connection.shareName) | expectedMountPoint=\(connection.mountPoint)")
            }
        }
    }

    private func smbService(connection: SMBConnection, password: String) -> String {
        var components = URLComponents()
        components.scheme = "smb"
        components.user = connection.username
        components.password = password
        components.host = connection.serverAddress
        components.percentEncodedPath = "/" + encodedSMBPathComponent(connection.shareName)

        let smbURL = components.string ?? "smb://\(connection.serverAddress)/\(connection.shareName)"
        if smbURL.hasPrefix("smb:") {
            return String(smbURL.dropFirst(4))
        }

        return smbURL
    }

    private func encodedSMBPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func userFacingMountError(from rawError: String?, exitCode: Int32) -> String {
        let normalizedError = rawError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if normalizedError.contains("authentication error") || normalizedError.contains("login failed") {
            return "Authentication failed. Check username and password."
        }

        if normalizedError.contains("no route to host") ||
            normalizedError.contains("host is down") ||
            normalizedError.contains("could not connect") {
            return "Server unreachable. Check address, VPN, or network."
        }

        if normalizedError.contains("operation timed out") || normalizedError.contains("timed out") {
            return "Connection timed out."
        }

        if normalizedError.contains("no such file or directory") || normalizedError.contains("not found") {
            return "Share not found on server."
        }

        if normalizedError.contains("resource busy") {
            return "Mount point already in use."
        }

        if normalizedError.isEmpty == false {
            return rawError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mount failed."
        }

        return "Mount failed (exit code \(exitCode))."
    }

    private func mountedVolumeURL(for connection: SMBConnection) -> URL? {
        if isSMBMount(atPath: connection.mountPoint) {
            LoggingService.shared.record(.debug, category: .mount, message: "Mounted volume matched by mount point for \(connection.serverAddress)/\(connection.shareName) | path=\(connection.mountPoint)")
            return URL(fileURLWithPath: connection.mountPoint, isDirectory: true)
        }

        let resourceKeys: [URLResourceKey] = [.volumeURLForRemountingKey]

        guard let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: []
        ) else {
            return nil
        }

        let matchedVolume = volumeURLs.first { matches(connection, mountedVolumeURL: $0) }
        if let matchedVolume {
            LoggingService.shared.record(.debug, category: .mount, message: "Mounted volume matched by remount URL for \(connection.serverAddress)/\(connection.shareName) | path=\(matchedVolume.path)")
        }
        return matchedVolume
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
            LoggingService.shared.record(.debug, category: .mount, message: "Remount URL match for \(connection.serverAddress)/\(connection.shareName) | candidatePath=\(mountedVolumeURL.path) remountURL=\(remountURL.absoluteString)")
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
                LoggingService.shared.record(.warning, category: .mount, message: "Dropped queued mount for missing connection id \(nextMountRequest.connectionID.uuidString)")
                continue
            }

            if isMounted(connection) {
                setStatus(.connected, for: connection.id)
                automaticRetryCounts[connection.id] = 0
                LoggingService.shared.record(.info, category: .mount, message: "Queued mount resolved immediately because share is already mounted for \(connection.serverAddress)/\(connection.shareName)")
                continue
            }

            activeMountRequest = nextMountRequest
            LoggingService.shared.record(.debug, category: .mount, message: "Dequeued mount request for \(connection.serverAddress)/\(connection.shareName) | initiatedByUser=\(nextMountRequest.initiatedByUser) remainingPending=\(pendingMountRequests.count)")
            startMount(connection, initiatedByUser: nextMountRequest.initiatedByUser)
            return
        }
    }

    private func finishMountAttempt(for connectionID: UUID) {
        if activeMountRequest?.connectionID == connectionID {
            LoggingService.shared.record(.debug, category: .mount, message: "Finishing active mount attempt for connection id \(connectionID.uuidString)")
            activeMountRequest = nil
            processNextMountIfNeeded()
        } else {
            LoggingService.shared.record(.debug, category: .mount, message: "Removing stale queued mount attempts for connection id \(connectionID.uuidString)")
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

    private func isMountAttemptPending(for connectionID: UUID) -> Bool {
        activeMountRequest?.connectionID == connectionID ||
            pendingMountRequests.contains(where: { $0.connectionID == connectionID })
    }

    /// Sets the status for a connection only when the new value differs from
    /// the current one, preventing unnecessary @Published change notifications
    /// that would cause SwiftUI to re-render the row.
    private func setStatus(_ newStatus: ConnectionStatus, for connectionID: UUID, caller: String = #function) {
        let oldStatus = statuses[connectionID]
        if oldStatus != newStatus {
            let name = connections.first(where: { $0.id == connectionID })?.shareName ?? connectionID.uuidString
            LoggingService.shared.record(.debug, category: .mount, message: "[\(caller)] Status change for \(name): \(oldStatus?.label ?? "nil") → \(newStatus.label)")
            var updatedStatuses = statuses
            updatedStatuses[connectionID] = newStatus
            statuses = updatedStatuses
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
