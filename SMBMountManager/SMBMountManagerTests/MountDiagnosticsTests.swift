import Foundation
import Testing
@testable import SMBMountManager

struct MountDiagnosticsTests {
    @Test
    func redactsPasswordInDoubleSlashSMBMountTarget() {
        let rawValue = "mount failed for //alice:secret123@nas.local/Share"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == "mount failed for //alice:<redacted>@nas.local/Share")
    }

    @Test
    func redactsPasswordInSMBURL() {
        let rawValue = "mount failed for smb://alice:secret123@nas.local/Share"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == "mount failed for smb://alice:<redacted>@nas.local/Share")
    }

    @Test
    func leavesNonSensitiveErrorsUnchanged() {
        let rawValue = "Authentication failed"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == rawValue)
    }

    @Test
    func mapsAuthenticationFailureToUserFacingMessage() {
        let message = MountDiagnostics.userFacingMountError(from: "session setup failed: AUTHENTICATION ERROR", exitCode: 77)

        #expect(message == "Authentication failed. Check username and password.")
    }

    @Test
    func fallsBackToExitCodeWhenErrorMessageIsMissing() {
        let message = MountDiagnostics.userFacingMountError(from: nil, exitCode: 13)

        #expect(message == "Mount failed (exit code 13).")
    }
}

struct SMBShareOutputParserTests {
    @Test
    func ignoresHeadersAndParsesVisibleAndHiddenShares() {
        let output = """
        Share                      Type       Comment
        -------------------------  ---------  ------------------------------
        Public                     Disk       Team files
        IPC$                       IPC        Remote IPC
        """

        let shares = SMBShareOutputParser.parseShares(from: output, serverAddress: "nas.local")

        #expect(shares.count == 2)
        #expect(shares.map(\.name) == ["IPC$", "Public"])
        #expect(shares.first(where: { $0.name == "IPC$" })?.isHidden == true)
        #expect(shares.first(where: { $0.name == "Public" })?.comment == "Team files")
    }

    @Test
    func deduplicatesSharesByServerAndName() {
        let output = """
        Share                      Type       Comment
        Docs                       Disk       Shared docs
        Docs                       Disk       Shared docs
        """

        let shares = SMBShareOutputParser.parseShares(from: output, serverAddress: "fileserver")

        #expect(shares.count == 1)
        #expect(shares.first?.id == "fileserver/docs")
    }

    @Test
    func preservesCommentsContainingExtraColumns() {
        let output = "Media  Disk  Movies  TV  Archive"

        let shares = SMBShareOutputParser.parseShares(from: output, serverAddress: "nas.local")

        #expect(shares.count == 1)
        #expect(shares.first?.name == "Media")
        #expect(shares.first?.type == "Disk")
        #expect(shares.first?.comment == "Movies TV Archive")
    }
}

struct MountErrorClassifierTests {
    @Test
    func classifiesAuthenticationMessages() {
        let category = MountErrorClassifier.classify("Authentication failed. Check username and password.")

        #expect(category == .authentication)
    }

    @Test
    func classifiesTimeoutMessages() {
        let category = MountErrorClassifier.classify("Connection timed out.")

        #expect(category == .timeout)
    }

    @Test
    func classifiesShareNotFoundMessages() {
        let category = MountErrorClassifier.classify("Share not found on server.")

        #expect(category == .shareNotFound)
    }

    @Test
    func classifiesMountPointBusyMessages() {
        let category = MountErrorClassifier.classify("Mount point already in use.")

        #expect(category == .mountPointBusy)
    }

    @Test
    func classifiesConnectivityMessages() {
        let category = MountErrorClassifier.classify("Server unreachable. Check address, VPN, or network.")

        #expect(category == .connectivity)
    }

    @Test
    func defaultsUnknownMessagesToUnknownCategory() {
        let category = MountErrorClassifier.classify("Unexpected failure")

        #expect(category == .unknown)
    }
}

struct PersistenceCodecTests {
    @Test
    func roundTripsConnections() throws {
        let connections = [
            SMBConnection(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "NAS",
                serverAddress: "nas.local",
                shareName: "Public",
                username: "alice",
                autoConnect: true
            )
        ]

        let data = try PersistenceCodec.encodeConnections(connections)
        let decoded = try PersistenceCodec.decodeConnections(from: data)

        #expect(decoded == connections)
    }

    @Test
    func roundTripsRuntimeDetailsUsingISO8601Dates() throws {
        let connectionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let details = SMBConnectionRuntimeDetails(
            lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastMountDuration: 1.25,
            lastProbeLatency: 0.25,
            averageProbeLatency: 0.30,
            probeLatencyJitter: 0.05,
            recentProbeLatencies: [0.2, 0.3],
            successfulMounts: 2,
            failedMounts: 1,
            disconnectCount: 1,
            automaticRetryCount: 0,
            totalConnectedDuration: 3600,
            totalDisconnectedDuration: 120,
            mountedVolumePath: "/Volumes/nas",
            volumeName: "nas",
            volumeTotalCapacityBytes: 1000,
            volumeAvailableCapacityBytes: 500,
            protocolVersion: "SMB3",
            signingState: nil,
            encryptionState: nil,
            multichannelState: nil,
            sessionAttributes: ["dialect": "3.1.1"],
            errorCounts: ["timeout": 1],
            lastErrorCategory: .timeout,
            timeline: [],
            benchmarkResult: nil,
            benchmarkStatusMessage: nil,
            isBenchmarkRunning: false,
            stabilityGrade: .medium,
            confidenceLevel: .high
        )

        let data = try PersistenceCodec.encodeRuntimeDetails([connectionID: details])
        let decoded = try PersistenceCodec.decodeRuntimeDetails(from: data)

        #expect(decoded[connectionID] == details)
    }
}

struct MountRequestQueueTests {
    @Test
    func upgradesQueuedAutomaticRequestToUserInitiated() {
        let connectionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var queue = MountRequestQueue()

        let first = queue.enqueue(connectionID: connectionID, initiatedByUser: false)
        let second = queue.enqueue(connectionID: connectionID, initiatedByUser: true)

        #expect(first == .enqueued)
        #expect(second == .upgradedPending)
        #expect(queue.pendingRequests == [MountRequest(connectionID: connectionID, initiatedByUser: true)])
    }

    @Test
    func upgradesActiveAutomaticRequestToUserInitiated() {
        let connectionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var queue = MountRequestQueue()
        _ = queue.enqueue(connectionID: connectionID, initiatedByUser: false)
        let next = queue.dequeueNext()

        let outcome = queue.enqueue(connectionID: connectionID, initiatedByUser: true)

        #expect(next == MountRequest(connectionID: connectionID, initiatedByUser: false))
        #expect(outcome == .upgradedActive)
        #expect(queue.activeRequest == MountRequest(connectionID: connectionID, initiatedByUser: true))
    }

    @Test
    func dequeuePromotesNextPendingRequestToActive() {
        let firstID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let secondID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        var queue = MountRequestQueue()
        _ = queue.enqueue(connectionID: firstID, initiatedByUser: true)
        _ = queue.enqueue(connectionID: secondID, initiatedByUser: false)

        let next = queue.dequeueNext()

        #expect(next == MountRequest(connectionID: firstID, initiatedByUser: true))
        #expect(queue.activeRequest == MountRequest(connectionID: firstID, initiatedByUser: true))
        #expect(queue.pendingRequests == [MountRequest(connectionID: secondID, initiatedByUser: false)])
    }

    @Test
    func finishRemovesActiveOrPendingRequestsForConnection() {
        let activeID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let pendingID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        var queue = MountRequestQueue()
        _ = queue.enqueue(connectionID: activeID, initiatedByUser: true)
        _ = queue.enqueue(connectionID: pendingID, initiatedByUser: false)
        _ = queue.dequeueNext()

        let activeOutcome = queue.finish(connectionID: activeID)
        let pendingOutcome = queue.finish(connectionID: pendingID)

        #expect(activeOutcome == .finishedActive)
        #expect(pendingOutcome == .removedPending)
        #expect(queue.activeRequest == nil)
        #expect(queue.pendingRequests.isEmpty)
    }

    @Test
    func pruneDropsRequestsForMissingConnections() {
        let keptID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let removedID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        var queue = MountRequestQueue()
        _ = queue.enqueue(connectionID: removedID, initiatedByUser: false)
        _ = queue.enqueue(connectionID: keptID, initiatedByUser: true)
        _ = queue.dequeueNext()

        queue.prune(validConnectionIDs: [removedID])

        #expect(queue.activeRequest == nil)
        #expect(queue.pendingRequests == [MountRequest(connectionID: removedID, initiatedByUser: false)])
    }
}

struct AutomaticRetryTrackerTests {
    @Test
    func resetsRetryCountForManualAttempts() {
        let connectionID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        var tracker = AutomaticRetryTracker()

        _ = tracker.registerFailure(for: connectionID, initiatedByUser: false)
        tracker.reset(for: connectionID)

        #expect(tracker.count(for: connectionID) == 0)
    }

    @Test
    func manualFailureStartsCounterAtOne() {
        let connectionID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        var tracker = AutomaticRetryTracker()

        let result = tracker.registerFailure(for: connectionID, initiatedByUser: true)

        #expect(result.updatedCount == 1)
        #expect(result.reachedLimit == false)
        #expect(tracker.count(for: connectionID) == 1)
    }

    @Test
    func automaticFailuresIncrementAndReportLimit() {
        let connectionID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        var tracker = AutomaticRetryTracker()

        _ = tracker.registerFailure(for: connectionID, initiatedByUser: false)
        let result = tracker.registerFailure(for: connectionID, initiatedByUser: false, maximumAutomaticRetryCount: 2)

        #expect(result.updatedCount == 2)
        #expect(result.reachedLimit == true)
        #expect(tracker.canAutomaticallyRetry(connectionID, maximumAutomaticRetryCount: 2) == false)
    }

    @Test
    func pruneRemovesMissingConnections() {
        let keptID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let removedID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        var tracker = AutomaticRetryTracker()
        _ = tracker.registerFailure(for: keptID, initiatedByUser: false)
        _ = tracker.registerFailure(for: removedID, initiatedByUser: false)

        tracker.prune(validConnectionIDs: [keptID])

        #expect(tracker.count(for: keptID) == 1)
        #expect(tracker.count(for: removedID) == 0)
    }
}

struct BackgroundRefreshPolicyTests {
    @Test
    func probeRequiresConnectedNonErroredIdleState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(
            BackgroundRefreshPolicy.shouldRunProbe(
                now: now,
                lastRunAt: nil,
                isAlreadyRunning: false,
                interval: 20,
                status: .connected,
                force: false
            )
        )
        #expect(
            BackgroundRefreshPolicy.shouldRunProbe(
                now: now,
                lastRunAt: now,
                isAlreadyRunning: false,
                interval: 20,
                status: .connected,
                force: false
            ) == false
        )
        #expect(
            BackgroundRefreshPolicy.shouldRunProbe(
                now: now,
                lastRunAt: nil,
                isAlreadyRunning: true,
                interval: 20,
                status: .connected,
                force: false
            ) == false
        )
        #expect(
            BackgroundRefreshPolicy.shouldRunProbe(
                now: now,
                lastRunAt: nil,
                isAlreadyRunning: false,
                interval: 20,
                status: .error("network"),
                force: false
            ) == false
        )
    }

    @Test
    func forceBypassesProbeIntervalAndErrorSuppression() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(
            BackgroundRefreshPolicy.shouldRunProbe(
                now: now,
                lastRunAt: now,
                isAlreadyRunning: false,
                interval: 20,
                status: .error("network"),
                force: true
            )
        )
    }

    @Test
    func sessionRefreshUsesIndependentIntervalGuard() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(
            BackgroundRefreshPolicy.shouldRefreshSessionDetails(
                now: now,
                lastRunAt: nil,
                isAlreadyRunning: false,
                interval: 60,
                force: false
            )
        )
        #expect(
            BackgroundRefreshPolicy.shouldRefreshSessionDetails(
                now: now,
                lastRunAt: now,
                isAlreadyRunning: false,
                interval: 60,
                force: false
            ) == false
        )
        #expect(
            BackgroundRefreshPolicy.shouldRefreshSessionDetails(
                now: now,
                lastRunAt: now,
                isAlreadyRunning: true,
                interval: 60,
                force: true
            ) == false
        )
    }
}
