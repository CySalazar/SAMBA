import Foundation

struct DiscoveredSMBShare: Identifiable, Hashable, Codable {
    let name: String
    let type: String
    let comment: String
    let serverAddress: String

    var id: String {
        "\(serverAddress.lowercased())/\(name.lowercased())"
    }

    var isHidden: Bool {
        name.hasSuffix("$")
    }

    var smbURL: String {
        "smb://\(serverAddress)/\(name)"
    }
}

enum ConnectionStabilityGrade: String, Codable, CaseIterable {
    case insufficientHistory
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .insufficientHistory:
            return "Insufficient History"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

enum ConnectionConfidenceLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }
}

enum StabilityObservationWindow: String, Codable, CaseIterable, Identifiable {
    case session
    case last24Hours
    case last7Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session:
            return "Session"
        case .last24Hours:
            return "24 Hours"
        case .last7Days:
            return "7 Days"
        }
    }
}

enum ConnectionErrorCategory: String, Codable, CaseIterable, Identifiable {
    case authentication
    case connectivity
    case timeout
    case shareNotFound
    case mountPointBusy
    case benchmark
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .authentication:
            return "Authentication"
        case .connectivity:
            return "Connectivity"
        case .timeout:
            return "Timeout"
        case .shareNotFound:
            return "Share Not Found"
        case .mountPointBusy:
            return "Mount Point Busy"
        case .benchmark:
            return "Benchmark"
        case .unknown:
            return "Unknown"
        }
    }
}

enum ConnectionTimelineEventKind: String, Codable {
    case status
    case probe
    case benchmark
    case session
    case note
}

struct ConnectionTimelineEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: ConnectionTimelineEventKind
    let title: String
    let details: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ConnectionTimelineEventKind,
        title: String,
        details: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.details = details
    }
}

struct SMBBenchmarkResult: Codable, Hashable {
    let timestamp: Date
    let payloadSizeBytes: Int
    let writeDuration: TimeInterval
    let readDuration: TimeInterval

    var writeThroughputMBps: Double {
        throughput(for: writeDuration)
    }

    var readThroughputMBps: Double {
        throughput(for: readDuration)
    }

    private func throughput(for duration: TimeInterval) -> Double {
        guard duration > 0 else {
            return 0
        }

        let megabytes = Double(payloadSizeBytes) / 1_048_576
        return megabytes / duration
    }
}

struct SMBConnectionRuntimeDetails: Codable, Hashable {
    var lastUpdatedAt: Date?
    var lastMountDuration: TimeInterval?
    var lastProbeLatency: TimeInterval?
    var averageProbeLatency: TimeInterval?
    var probeLatencyJitter: TimeInterval?
    var recentProbeLatencies: [TimeInterval] = []
    var successfulMounts: Int = 0
    var failedMounts: Int = 0
    var disconnectCount: Int = 0
    var automaticRetryCount: Int = 0
    var totalConnectedDuration: TimeInterval = 0
    var totalDisconnectedDuration: TimeInterval = 0
    var mountedVolumePath: String?
    var volumeName: String?
    var volumeTotalCapacityBytes: Int64?
    var volumeAvailableCapacityBytes: Int64?
    var protocolVersion: String?
    var signingState: String?
    var encryptionState: String?
    var multichannelState: String?
    var sessionAttributes: [String: String] = [:]
    var errorCounts: [String: Int] = [:]
    var lastErrorCategory: ConnectionErrorCategory?
    var timeline: [ConnectionTimelineEvent] = []
    var benchmarkResult: SMBBenchmarkResult?
    var benchmarkStatusMessage: String?
    var isBenchmarkRunning = false
    var stabilityGrade: ConnectionStabilityGrade = .insufficientHistory
    var confidenceLevel: ConnectionConfidenceLevel = .low

    var successRate: Double {
        let attempts = successfulMounts + failedMounts
        guard attempts > 0 else {
            return 0
        }

        return Double(successfulMounts) / Double(attempts)
    }
}

struct ConnectionHealthSnapshot: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let serverAddress: String
    let shareName: String
    let statusLabel: String
    let stabilityLabel: String
    let confidenceLabel: String
    let successRate: Double
    let lastProbeLatency: TimeInterval?
    let topErrorCategory: String
}
