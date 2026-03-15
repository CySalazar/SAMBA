import AppKit
import Foundation

@MainActor
final class MountService: ObservableObject {
    @Published var statuses: [UUID: ConnectionStatus] = [:]
    @Published private(set) var runtimeDetails: [UUID: SMBConnectionRuntimeDetails] = [:]
    @Published var maximumAutomaticRetryCount: Int {
        didSet {
            UserDefaults.standard.set(maximumAutomaticRetryCount, forKey: Self.maximumAutomaticRetryCountDefaultsKey)
        }
    }
    @Published var probeIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(probeIntervalSeconds, forKey: Self.probeIntervalDefaultsKey)
        }
    }
    @Published var sessionRefreshIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(sessionRefreshIntervalSeconds, forKey: Self.sessionRefreshIntervalDefaultsKey)
        }
    }
    @Published var stabilityObservationWindow: StabilityObservationWindow {
        didSet {
            UserDefaults.standard.set(stabilityObservationWindow.rawValue, forKey: Self.stabilityObservationWindowDefaultsKey)
        }
    }
    @Published var benchmarkPayloadSizeMB: Int {
        didSet {
            UserDefaults.standard.set(benchmarkPayloadSizeMB, forKey: Self.benchmarkPayloadSizeDefaultsKey)
        }
    }

    private var statusTimer: Timer?
    private var autoConnectTimer: Timer?
    private var connections: [SMBConnection] = []
    private var pendingMountRequests: [MountRequest] = []
    private var activeMountRequest: MountRequest?
    private var automaticRetryCounts: [UUID: Int] = [:]
    private var consecutiveMissedChecks: [UUID: Int] = [:]
    private var telemetry: [UUID: ConnectionTelemetry] = [:]
    private let fileManager = FileManager.default
    private static let maximumAutomaticRetryCountDefaultsKey = "maximumAutomaticRetryCount"
    private static let probeIntervalDefaultsKey = "probeIntervalSeconds"
    private static let sessionRefreshIntervalDefaultsKey = "sessionRefreshIntervalSeconds"
    private static let stabilityObservationWindowDefaultsKey = "stabilityObservationWindow"
    private static let benchmarkPayloadSizeDefaultsKey = "benchmarkPayloadSizeMB"

    init() {
        let storedRetryCount = UserDefaults.standard.integer(forKey: Self.maximumAutomaticRetryCountDefaultsKey)
        maximumAutomaticRetryCount = storedRetryCount > 0 ? storedRetryCount : 5
        let storedProbeInterval = UserDefaults.standard.double(forKey: Self.probeIntervalDefaultsKey)
        probeIntervalSeconds = storedProbeInterval > 0 ? storedProbeInterval : 20
        let storedRefreshInterval = UserDefaults.standard.double(forKey: Self.sessionRefreshIntervalDefaultsKey)
        sessionRefreshIntervalSeconds = storedRefreshInterval > 0 ? storedRefreshInterval : 60
        let storedWindow = UserDefaults.standard.string(forKey: Self.stabilityObservationWindowDefaultsKey)
        stabilityObservationWindow = StabilityObservationWindow(rawValue: storedWindow ?? "") ?? .session
        let storedBenchmarkSize = UserDefaults.standard.integer(forKey: Self.benchmarkPayloadSizeDefaultsKey)
        benchmarkPayloadSizeMB = storedBenchmarkSize > 0 ? storedBenchmarkSize : 4
        runtimeDetails = PersistenceService.loadRuntimeDetails()
    }

    func startMonitoring(connections: [SMBConnection]) {
        self.connections = connections
        hydrateTelemetryFromPersistedRuntimeDetails(for: connections)
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
        hydrateTelemetryFromPersistedRuntimeDetails(for: connections)
        pendingMountRequests.removeAll { request in
            !connections.contains(where: { $0.id == request.connectionID })
        }
        automaticRetryCounts = automaticRetryCounts.filter { connectionID, _ in
            connections.contains(where: { $0.id == connectionID })
        }
        consecutiveMissedChecks = consecutiveMissedChecks.filter { connectionID, _ in
            connections.contains(where: { $0.id == connectionID })
        }
        telemetry = telemetry.filter { connectionID, _ in
            connections.contains(where: { $0.id == connectionID })
        }
        runtimeDetails = runtimeDetails.filter { connectionID, _ in
            connections.contains(where: { $0.id == connectionID })
        }
        if let activeMountRequest,
           !connections.contains(where: { $0.id == activeMountRequest.connectionID }) {
            self.activeMountRequest = nil
        }
        LoggingService.shared.record(.debug, category: .mount, message: "Updated monitored connections to \(connections.count)")
        PersistenceService.saveRuntimeDetails(runtimeDetails)
        refreshAllStatuses()
        processNextMountIfNeeded()
    }

    // MARK: - Mount

    func mount(_ connection: SMBConnection, initiatedByUser: Bool = true) {
        if isMounted(connection) {
            setStatus(.connected, for: connection.id)
            LoggingService.shared.record(.debug, category: .mount, message: "Mount skipped for \(connection.serverAddress)/\(connection.shareName): already connected")
            automaticRetryCounts[connection.id] = 0
            updateTelemetry(for: connection.id) { telemetry in
                telemetry.automaticRetryCount = 0
            }
            return
        }

        if initiatedByUser {
            automaticRetryCounts[connection.id] = 0
            updateTelemetry(for: connection.id) { telemetry in
                telemetry.automaticRetryCount = 0
            }
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
        telemetry(for: connection.id).lastMountStartedAt = Date()
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
            updateTelemetry(for: connection.id) { telemetry in
                telemetry.automaticRetryCount = 0
            }
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
                updateTelemetry(for: connection.id) { telemetry in
                    telemetry.automaticRetryCount = 0
                }
                refreshSessionDetailsIfNeeded(for: connection)
                runPassiveProbeIfNeeded(for: connection)
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
                refreshSessionDetailsIfNeeded(for: connection, force: true)
                runPassiveProbeIfNeeded(for: connection, force: true)
                return
            }

            LoggingService.shared.record(.debug, category: .mount, message: "Mount wait tick for \(connection.serverAddress)/\(connection.shareName) | attempt=\(attempt) processRunning=\(process.isRunning)")

            if process.isRunning == false {
                if process.terminationStatus == 0 {
                    setStatus(.connected, for: connection.id)
                    automaticRetryCounts[connection.id] = 0
                    consecutiveMissedChecks[connection.id] = 0
                    updateTelemetry(for: connection.id) { telemetry in
                        telemetry.automaticRetryCount = 0
                    }
                    LoggingService.shared.record(.info, category: .mount, message: "Mount command completed successfully for \(connection.serverAddress)/\(connection.shareName) | exitCode=0")
                    finishMountAttempt(for: connection.id)
                    refreshSessionDetailsIfNeeded(for: connection, force: true)
                    runPassiveProbeIfNeeded(for: connection, force: true)
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
                self.refreshSessionDetailsIfNeeded(for: connection, force: true)
                self.runPassiveProbeIfNeeded(for: connection, force: true)
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

    func runBenchmark(for connection: SMBConnection) async {
        guard let mountedVolumeURL = mountedVolumeURL(for: connection) else {
            updateTelemetry(for: connection.id) { telemetry in
                telemetry.benchmarkStatusMessage = "Benchmark unavailable because the share is not mounted."
                telemetry.recordError(category: .benchmark, message: "Benchmark requested while share was not mounted.")
            }
            return
        }

        guard runtimeDetails[connection.id]?.isBenchmarkRunning != true else {
            return
        }

        updateTelemetry(for: connection.id) { telemetry in
            telemetry.isBenchmarkRunning = true
            telemetry.benchmarkStatusMessage = "Running a small manual benchmark."
            telemetry.recordTimeline(kind: .benchmark, title: "Manual benchmark started", details: connection.smbURL)
        }

        let payloadSizeBytes = max(1, benchmarkPayloadSizeMB) * 1_048_576
        let benchmarkFileURL = mountedVolumeURL.appendingPathComponent(".smbmountmanager-benchmark.tmp")
        let payload = Data(repeating: 0x5A, count: payloadSizeBytes)

        do {
            let writeDuration = try Self.measure {
                try payload.write(to: benchmarkFileURL, options: .atomic)
            }
            let readDuration = try Self.measure {
                _ = try Data(contentsOf: benchmarkFileURL)
            }
            try? fileManager.removeItem(at: benchmarkFileURL)

            let result = SMBBenchmarkResult(
                timestamp: Date(),
                payloadSizeBytes: payloadSizeBytes,
                writeDuration: writeDuration,
                readDuration: readDuration
            )

            updateTelemetry(for: connection.id) { telemetry in
                telemetry.isBenchmarkRunning = false
                telemetry.benchmarkResult = result
                telemetry.benchmarkStatusMessage = "Manual benchmark completed successfully."
                telemetry.recordTimeline(
                    kind: .benchmark,
                    title: "Manual benchmark completed",
                    details: "Write \(String(format: "%.2f", result.writeThroughputMBps)) MB/s • Read \(String(format: "%.2f", result.readThroughputMBps)) MB/s"
                )
            }
        } catch {
            try? fileManager.removeItem(at: benchmarkFileURL)
            updateTelemetry(for: connection.id) { telemetry in
                telemetry.isBenchmarkRunning = false
                telemetry.benchmarkStatusMessage = "Benchmark failed: \(error.localizedDescription)"
                telemetry.recordError(category: .benchmark, message: error.localizedDescription)
            }
            LoggingService.shared.record(.warning, category: .mount, message: "Benchmark failed for \(connection.serverAddress)/\(connection.shareName): \(error.localizedDescription)")
        }
    }

    private func runPassiveProbeIfNeeded(for connection: SMBConnection, force: Bool = false) {
        guard let mountedVolumeURL = mountedVolumeURL(for: connection) else {
            return
        }

        let telemetry = telemetry(for: connection.id)
        if force == false {
            if telemetry.isProbing {
                return
            }

            if let lastProbeAt = telemetry.lastProbeAt,
               Date().timeIntervalSince(lastProbeAt) < probeIntervalSeconds {
                return
            }

            if case .error = statuses[connection.id] {
                return
            }
        }

        telemetry.isProbing = true
        telemetry.lastProbeAt = Date()
        self.telemetry[connection.id] = telemetry

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            do {
                let latency = try Self.measure {
                    _ = try FileManager.default.contentsOfDirectory(
                        at: mountedVolumeURL,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsPackageDescendants, .skipsHiddenFiles]
                    )
                }

                await MainActor.run {
                    self.updateTelemetry(for: connection.id) { telemetry in
                        telemetry.recordProbeLatency(latency)
                        telemetry.isProbing = false
                        telemetry.recordTimeline(kind: .probe, title: "Passive probe", details: "Latency \(Self.formatDuration(latency))")
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateTelemetry(for: connection.id) { telemetry in
                        telemetry.isProbing = false
                    }
                }
                LoggingService.shared.record(.debug, category: .mount, message: "Passive probe failed for \(connection.serverAddress)/\(connection.shareName): \(error.localizedDescription)")
            }
        }
    }

    private func refreshSessionDetailsIfNeeded(for connection: SMBConnection, force: Bool = false) {
        guard let mountedVolumeURL = mountedVolumeURL(for: connection) else {
            return
        }

        let telemetry = telemetry(for: connection.id)
        if force == false {
            if telemetry.isRefreshingSessionDetails {
                return
            }

            if let lastSessionRefreshAt = telemetry.lastSessionRefreshAt,
               Date().timeIntervalSince(lastSessionRefreshAt) < sessionRefreshIntervalSeconds {
                return
            }
        }

        telemetry.isRefreshingSessionDetails = true
        telemetry.lastSessionRefreshAt = Date()
        self.telemetry[connection.id] = telemetry

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let sessionAttributes = Self.loadSessionAttributes(forMountPath: mountedVolumeURL.path)
            let multichannelAttributes = Self.loadMultichannelAttributes(forMountPath: mountedVolumeURL.path)

            await MainActor.run {
                self.updateTelemetry(for: connection.id) { telemetry in
                    telemetry.isRefreshingSessionDetails = false
                    telemetry.applySessionAttributes(sessionAttributes)
                    telemetry.applyMultichannelAttributes(multichannelAttributes)
                    telemetry.applyVolumeDetails(self.volumeDetails(for: mountedVolumeURL))
                    telemetry.recordTimeline(kind: .session, title: "Session details refreshed", details: connection.smbURL)
                }
            }
        }
    }

    func refreshRuntimeDetails(for connection: SMBConnection) {
        refreshSessionDetailsIfNeeded(for: connection, force: true)
        runPassiveProbeIfNeeded(for: connection, force: true)
    }

    func healthSnapshots(for connections: [SMBConnection]) -> [ConnectionHealthSnapshot] {
        connections.map { connection in
            let details = runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails()
            let status = statuses[connection.id] ?? .disconnected

            return ConnectionHealthSnapshot(
                id: connection.id,
                displayName: connection.name.isEmpty ? connection.shareName : connection.name,
                serverAddress: connection.serverAddress,
                shareName: connection.shareName,
                statusLabel: status.label,
                stabilityLabel: details.stabilityGrade.title,
                confidenceLabel: details.confidenceLevel.title,
                successRate: details.successRate,
                lastProbeLatency: details.lastProbeLatency,
                topErrorCategory: topErrorCategory(from: details)
            )
        }
    }

    func exportHealthJSON(for connections: [SMBConnection]) -> String {
        let payload = connections.map { connection in
            HealthExportRecord(
                connection: connection,
                status: statuses[connection.id] ?? .disconnected,
                details: runtimeDetails[connection.id] ?? SMBConnectionRuntimeDetails()
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return text
    }

    nonisolated private static func loadSessionAttributes(forMountPath mountPath: String) -> [String: String] {
        loadSMBUtilAttributes(arguments: ["statshares", "-m", mountPath, "-f", "Json"])
    }

    nonisolated private static func loadMultichannelAttributes(forMountPath mountPath: String) -> [String: String] {
        loadSMBUtilAttributes(arguments: ["multichannel", "-m", mountPath, "-f", "Json"])
    }

    nonisolated private static func loadSMBUtilAttributes(arguments: [String]) -> [String: String] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = arguments
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return [:]
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let jsonObject = try JSONSerialization.jsonObject(with: data)

            return flattenJSONObject(jsonObject)
        } catch {
            return [:]
        }
    }

    nonisolated private static func flattenJSONObject(_ object: Any, prefix: String = "") -> [String: String] {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [:]) { partialResult, entry in
                let nestedPrefix = prefix.isEmpty ? entry.key : "\(prefix)_\(entry.key)"
                partialResult.merge(flattenJSONObject(entry.value, prefix: nestedPrefix)) { _, new in new }
            }
        }

        if let array = object as? [Any] {
            if let first = array.first {
                return flattenJSONObject(first, prefix: prefix)
            }
            return [:]
        }

        guard prefix.isEmpty == false else {
            return [:]
        }

        return [prefix: String(describing: object)]
    }

    nonisolated private static func measure(_ block: () throws -> Void) throws -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try block()
        return CFAbsoluteTimeGetCurrent() - start
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
                updateTelemetry(for: connection.id) { telemetry in
                    telemetry.automaticRetryCount = 0
                }
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
            updateTelemetry(for: connectionID) { telemetry in
                telemetry.automaticRetryCount = 1
            }
            return
        }

        let newCount = automaticRetryCounts[connectionID, default: 0] + 1
        automaticRetryCounts[connectionID] = newCount
        updateTelemetry(for: connectionID) { telemetry in
            telemetry.automaticRetryCount = newCount
        }

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
            updateTelemetryStatus(for: connectionID, oldStatus: oldStatus, newStatus: newStatus)
            var updatedStatuses = statuses
            updatedStatuses[connectionID] = newStatus
            statuses = updatedStatuses
        }
    }

    private func telemetry(for connectionID: UUID) -> ConnectionTelemetry {
        if let existing = telemetry[connectionID] {
            return existing
        }

        let telemetry = ConnectionTelemetry()
        self.telemetry[connectionID] = telemetry
        return telemetry
    }

    private func hydrateTelemetryFromPersistedRuntimeDetails(for connections: [SMBConnection]) {
        for connection in connections {
            guard telemetry[connection.id] == nil, let details = runtimeDetails[connection.id] else {
                continue
            }

            telemetry[connection.id] = ConnectionTelemetry(details: details)
        }
    }

    private func updateTelemetry(for connectionID: UUID, mutate: (ConnectionTelemetry) -> Void) {
        let telemetry = telemetry(for: connectionID)
        mutate(telemetry)
        runtimeDetails[connectionID] = telemetry.snapshot()
        PersistenceService.saveRuntimeDetails(runtimeDetails)
    }

    private func updateTelemetryStatus(for connectionID: UUID, oldStatus: ConnectionStatus?, newStatus: ConnectionStatus) {
        updateTelemetry(for: connectionID) { telemetry in
            telemetry.recordStatusTransition(from: oldStatus, to: newStatus)
            telemetry.automaticRetryCount = automaticRetryCounts[connectionID, default: telemetry.automaticRetryCount]
            telemetry.recordTimeline(kind: .status, title: "Status changed", details: newStatus.label)
            if case .error(let message) = newStatus {
                telemetry.recordError(category: Self.classifyError(from: message), message: message)
            }
        }
    }

    private static func classifyError(from message: String) -> ConnectionErrorCategory {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMessage.contains("authentication") || normalizedMessage.contains("password") || normalizedMessage.contains("login") {
            return .authentication
        }
        if normalizedMessage.contains("timed out") {
            return .timeout
        }
        if normalizedMessage.contains("share not found") || normalizedMessage.contains("not found") {
            return .shareNotFound
        }
        if normalizedMessage.contains("mount point") || normalizedMessage.contains("resource busy") {
            return .mountPointBusy
        }
        if normalizedMessage.contains("server unreachable") || normalizedMessage.contains("host") || normalizedMessage.contains("network") || normalizedMessage.contains("route") {
            return .connectivity
        }
        return .unknown
    }

    private func volumeDetails(for mountedVolumeURL: URL) -> (path: String, name: String?, total: Int64?, available: Int64?) {
        let keys: Set<URLResourceKey> = [
            .nameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let values = try? mountedVolumeURL.resourceValues(forKeys: keys)
        let total = values?.volumeTotalCapacity.map(Int64.init)
        let available = values?.volumeAvailableCapacity.map(Int64.init)
            ?? values?.volumeAvailableCapacityForImportantUsage

        return (mountedVolumeURL.path, values?.name, total, available)
    }

    private func topErrorCategory(from details: SMBConnectionRuntimeDetails) -> String {
        guard let top = details.errorCounts.max(by: { $0.value < $1.value }) else {
            return "None"
        }

        return ConnectionErrorCategory(rawValue: top.key)?.title ?? top.key.capitalized
    }

    nonisolated private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }

        return String(format: "%.2f s", duration)
    }
}

private struct MountRequest {
    let connectionID: UUID
    let initiatedByUser: Bool
}

private struct HealthExportRecord: Codable {
    let connection: SMBConnection
    let status: String
    let details: SMBConnectionRuntimeDetails

    init(connection: SMBConnection, status: ConnectionStatus, details: SMBConnectionRuntimeDetails) {
        self.connection = connection
        self.status = status.label
        self.details = details
    }
}

private final class ConnectionTelemetry {
    private(set) var statusChangedAt = Date()
    private(set) var probeLatencies: [TimeInterval] = []

    var lastMountStartedAt: Date?
    var lastMountDuration: TimeInterval?
    var successfulMounts = 0
    var failedMounts = 0
    var disconnectCount = 0
    var automaticRetryCount = 0
    var totalConnectedDuration: TimeInterval = 0
    var totalDisconnectedDuration: TimeInterval = 0
    var protocolVersion: String?
    var signingState: String?
    var encryptionState: String?
    var multichannelState: String?
    var sessionAttributes: [String: String] = [:]
    var benchmarkResult: SMBBenchmarkResult?
    var benchmarkStatusMessage: String?
    var isBenchmarkRunning = false
    var isProbing = false
    var lastProbeAt: Date?
    var isRefreshingSessionDetails = false
    var lastSessionRefreshAt: Date?
    var mountedVolumePath: String?
    var volumeName: String?
    var volumeTotalCapacityBytes: Int64?
    var volumeAvailableCapacityBytes: Int64?
    var errorCounts: [String: Int] = [:]
    var lastErrorCategory: ConnectionErrorCategory?
    var timeline: [ConnectionTimelineEvent] = []

    init() {}

    convenience init(details: SMBConnectionRuntimeDetails) {
        self.init()
        lastMountDuration = details.lastMountDuration
        probeLatencies = details.recentProbeLatencies
        successfulMounts = details.successfulMounts
        failedMounts = details.failedMounts
        disconnectCount = details.disconnectCount
        automaticRetryCount = details.automaticRetryCount
        totalConnectedDuration = details.totalConnectedDuration
        totalDisconnectedDuration = details.totalDisconnectedDuration
        mountedVolumePath = details.mountedVolumePath
        volumeName = details.volumeName
        volumeTotalCapacityBytes = details.volumeTotalCapacityBytes
        volumeAvailableCapacityBytes = details.volumeAvailableCapacityBytes
        protocolVersion = details.protocolVersion
        signingState = details.signingState
        encryptionState = details.encryptionState
        multichannelState = details.multichannelState
        sessionAttributes = details.sessionAttributes
        errorCounts = details.errorCounts
        lastErrorCategory = details.lastErrorCategory
        timeline = details.timeline
        benchmarkResult = details.benchmarkResult
        benchmarkStatusMessage = details.benchmarkStatusMessage
        isBenchmarkRunning = details.isBenchmarkRunning
    }

    func recordStatusTransition(from oldStatus: ConnectionStatus?, to newStatus: ConnectionStatus) {
        let now = Date()
        let elapsed = now.timeIntervalSince(statusChangedAt)

        if oldStatus == .connected {
            totalConnectedDuration += elapsed
        } else {
            totalDisconnectedDuration += elapsed
        }

        if oldStatus == .connecting, newStatus == .connected {
            successfulMounts += 1
            if let lastMountStartedAt {
                lastMountDuration = now.timeIntervalSince(lastMountStartedAt)
            }
        }

        if oldStatus == .connecting, case .error = newStatus {
            failedMounts += 1
        }

        if oldStatus == .connected, newStatus != .connected {
            disconnectCount += 1
        }

        statusChangedAt = now
    }

    func recordProbeLatency(_ latency: TimeInterval) {
        probeLatencies.append(latency)
        if probeLatencies.count > 12 {
            probeLatencies.removeFirst(probeLatencies.count - 12)
        }
    }

    func applyVolumeDetails(_ volumeDetails: (path: String, name: String?, total: Int64?, available: Int64?)) {
        mountedVolumePath = volumeDetails.path
        volumeName = volumeDetails.name
        volumeTotalCapacityBytes = volumeDetails.total
        volumeAvailableCapacityBytes = volumeDetails.available
    }

    func recordError(category: ConnectionErrorCategory, message: String) {
        errorCounts[category.rawValue, default: 0] += 1
        lastErrorCategory = category
        recordTimeline(kind: .note, title: "\(category.title) issue", details: message)
    }

    func recordTimeline(kind: ConnectionTimelineEventKind, title: String, details: String) {
        timeline.append(ConnectionTimelineEvent(kind: kind, title: title, details: details))
        if timeline.count > 30 {
            timeline.removeFirst(timeline.count - 30)
        }
    }

    func applySessionAttributes(_ attributes: [String: String]) {
        guard attributes.isEmpty == false else {
            return
        }

        sessionAttributes = attributes
        protocolVersion = bestMatch(in: attributes, candidates: ["smb_version", "version"])
        signingState = bestMatch(in: attributes, candidates: ["signing_required", "signing_on", "signing"])
        encryptionState = bestMatch(in: attributes, candidates: ["encryption", "encrypt"])
    }

    func applyMultichannelAttributes(_ attributes: [String: String]) {
        guard attributes.isEmpty == false else {
            return
        }

        multichannelState = bestMatch(in: attributes, candidates: ["multichannel", "channel"])
        for (key, value) in attributes where sessionAttributes[key] == nil {
            sessionAttributes[key] = value
        }
    }

    func snapshot() -> SMBConnectionRuntimeDetails {
        let lastProbeLatency = probeLatencies.last
        let averageProbeLatency = probeLatencies.isEmpty ? nil : probeLatencies.reduce(0, +) / Double(probeLatencies.count)
        let probeLatencyJitter: TimeInterval?
        if probeLatencies.count < 2 {
            probeLatencyJitter = nil
        } else {
            let diffs = zip(probeLatencies.dropFirst(), probeLatencies).map { abs($0 - $1) }
            probeLatencyJitter = diffs.reduce(0, +) / Double(diffs.count)
        }
        let attemptCount = successfulMounts + failedMounts

        return SMBConnectionRuntimeDetails(
            lastUpdatedAt: Date(),
            lastMountDuration: lastMountDuration,
            lastProbeLatency: lastProbeLatency,
            averageProbeLatency: averageProbeLatency,
            probeLatencyJitter: probeLatencyJitter,
            recentProbeLatencies: probeLatencies,
            successfulMounts: successfulMounts,
            failedMounts: failedMounts,
            disconnectCount: disconnectCount,
            automaticRetryCount: automaticRetryCount,
            totalConnectedDuration: totalConnectedDuration,
            totalDisconnectedDuration: totalDisconnectedDuration,
            mountedVolumePath: mountedVolumePath,
            volumeName: volumeName,
            volumeTotalCapacityBytes: volumeTotalCapacityBytes,
            volumeAvailableCapacityBytes: volumeAvailableCapacityBytes,
            protocolVersion: protocolVersion,
            signingState: signingState,
            encryptionState: encryptionState,
            multichannelState: multichannelState,
            sessionAttributes: sessionAttributes,
            errorCounts: errorCounts,
            lastErrorCategory: lastErrorCategory,
            timeline: timeline,
            benchmarkResult: benchmarkResult,
            benchmarkStatusMessage: benchmarkStatusMessage,
            isBenchmarkRunning: isBenchmarkRunning,
            stabilityGrade: stabilityGrade(attemptCount: attemptCount, lastProbeLatency: lastProbeLatency, probeLatencyJitter: probeLatencyJitter),
            confidenceLevel: confidenceLevel(attemptCount: attemptCount)
        )
    }

    private func stabilityGrade(
        attemptCount: Int,
        lastProbeLatency: TimeInterval?,
        probeLatencyJitter: TimeInterval?
    ) -> ConnectionStabilityGrade {
        guard attemptCount + disconnectCount >= 2 else {
            return .insufficientHistory
        }

        var score = 100.0
        let failureRate = attemptCount == 0 ? 0 : Double(failedMounts) / Double(attemptCount)
        score -= failureRate * 45
        score -= Double(disconnectCount) * 10

        if let lastProbeLatency {
            score -= min(lastProbeLatency * 15, 20)
        }

        if let probeLatencyJitter {
            score -= min(probeLatencyJitter * 30, 20)
        }

        switch score {
        case 80...:
            return .high
        case 55..<80:
            return .medium
        default:
            return .low
        }
    }

    private func confidenceLevel(attemptCount: Int) -> ConnectionConfidenceLevel {
        switch attemptCount + probeLatencies.count {
        case 8...:
            return .high
        case 4...:
            return .medium
        default:
            return .low
        }
    }

    private func bestMatch(in attributes: [String: String], candidates: [String]) -> String? {
        for candidate in candidates {
            if let match = attributes.first(where: { normalize($0.key).contains(candidate) }) {
                return match.value
            }
        }

        return nil
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
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
